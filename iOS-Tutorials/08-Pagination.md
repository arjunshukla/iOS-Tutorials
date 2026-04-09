# Tutorial 08 — Pagination
## Build: InfiniteList — a feed with cursor-based pagination
**Time:** 45 min | **Swift 6 + SwiftUI** | **Topics:** Cursor vs offset pagination, prefetching, pull-to-refresh, skeleton loading, MVVM state machine, Swift Testing

---

## What you'll build
An infinite-scroll feed with:
- Cursor-based pagination (production standard)
- Prefetch next page while current page renders
- Pull-to-refresh that resets pagination
- Skeleton loading placeholders
- Deduplication across pages

---

## Cursor vs Offset

```
Offset:  GET /items?page=2&limit=20      → shifts when items inserted mid-scroll
Cursor:  GET /items?after=<id>&limit=20  → stable, server uses indexed seek
```

Twitter, Instagram, and Whatnot all use cursor pagination.

---

## Architecture

```
FeedView
├── FeedSkeletonList        ← shimmer placeholders during first load
├── FeedItemList            ← real items + prefetch trigger
│   └── FeedItemRow
└── FeedFooter              ← spinner / end-of-feed / retry

FeedViewModel               ← owns PaginationState, exposes send(_:)
└── FeedServiceProtocol     ← injectable page fetcher
```

---

## Step 1 — Models (~5 min)

```swift
// Models.swift
import Foundation

struct FeedItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let title: String
    let subtitle: String
    let cursor: String

    static func stub(cursor: String = UUID().uuidString) -> FeedItem {
        FeedItem(
            id: UUID(),
            title: "Item \(Int.random(in: 1000...9999))",
            subtitle: "Posted \(Int.random(in: 1...60)) min ago",
            cursor: cursor
        )
    }
}

struct Page<T: Sendable>: Sendable {
    let items: [T]
    let nextCursor: String?
    var hasNextPage: Bool { nextCursor != nil }
}

// ★ All pagination state in one Equatable struct
struct PaginationState: Equatable {
    var items: [FeedItem]        = []
    var nextCursor: String?      = nil
    var isLoadingFirstPage: Bool = false
    var isLoadingNextPage: Bool  = false
    var hasNextPage: Bool        = true
    var error: String?           = nil
    private var seenIDs: Set<UUID> = []

    mutating func reset() {
        self = PaginationState()
    }

    mutating func applyFirstPage(_ page: Page<FeedItem>) {
        reset()
        applyPage(page)
    }

    mutating func applyPage(_ page: Page<FeedItem>) {
        let new = page.items.filter { !seenIDs.contains($0.id) }
        seenIDs.formUnion(new.map(\.id))
        items.append(contentsOf: new)
        nextCursor = page.nextCursor
        hasNextPage = page.hasNextPage
    }

    // Equatable: ignore seenIDs (internal implementation detail)
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items &&
        lhs.nextCursor == rhs.nextCursor &&
        lhs.isLoadingFirstPage == rhs.isLoadingFirstPage &&
        lhs.isLoadingNextPage == rhs.isLoadingNextPage &&
        lhs.hasNextPage == rhs.hasNextPage &&
        lhs.error == rhs.error
    }
}
```

---

## Step 2 — Service protocol (~5 min)

```swift
// FeedService.swift
import Foundation

// ★ Protocol = swap actor for MockFeedService in tests
protocol FeedServiceProtocol: Sendable {
    func fetchPage(after cursor: String?) async throws -> Page<FeedItem>
}

actor FeedService: FeedServiceProtocol {
    static let pageSize = 20
    private var pageNumber = 0

    func fetchPage(after cursor: String? = nil) async throws -> Page<FeedItem> {
        try await Task.sleep(for: .milliseconds(Int.random(in: 600...1000)))
        let items = (0..<Self.pageSize).map { _ in FeedItem.stub(cursor: cursor ?? "root") }
        pageNumber += 1
        let nextCursor = pageNumber < 5 ? UUID().uuidString : nil
        return Page(items: items, nextCursor: nextCursor)
    }
}

// Controllable mock — deterministic, no latency
actor MockFeedService: FeedServiceProtocol {
    var pages: [Page<FeedItem>] = []
    var error: Error? = nil
    private(set) var callCount = 0

    func fetchPage(after cursor: String?) async throws -> Page<FeedItem> {
        callCount += 1
        if let error { throw error }
        let page = pages.isEmpty ? Page<FeedItem>(items: [], nextCursor: nil) : pages.removeFirst()
        return page
    }
}
```

---

## Step 3 — ViewModel with `send(_:)` dispatch (~15 min)

```swift
// FeedViewModel.swift
import Observation

enum FeedAction: Sendable {
    case loadFirstPage
    case loadNextPage
    case refresh
    case itemAppeared(FeedItem)
    case retry
}

@MainActor
protocol FeedViewModelProtocol: AnyObject {
    var state: PaginationState { get }
    func send(_ action: FeedAction)
}

@MainActor
@Observable
final class FeedViewModel: FeedViewModelProtocol {

    private(set) var state = PaginationState()

    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedPage: Page<FeedItem>?

    private let service: any FeedServiceProtocol
    private let prefetchThreshold: Int

    init(
        service: any FeedServiceProtocol = FeedService(),
        prefetchThreshold: Int = 5
    ) {
        self.service = service
        self.prefetchThreshold = prefetchThreshold
    }

    // ★ Single dispatch — all state transitions here
    func send(_ action: FeedAction) {
        switch action {
        case .loadFirstPage:          loadFirstPage()
        case .loadNextPage:           loadNextPage()
        case .refresh:                Task { await refresh() }
        case .itemAppeared(let item): checkPrefetch(for: item)
        case .retry:                  loadNextPage()
        }
    }

    // MARK: - Private handlers

    private func loadFirstPage() {
        guard !state.isLoadingFirstPage else { return }
        loadTask?.cancel()
        prefetchTask?.cancel()
        prefetchedPage = nil
        state.reset()
        state.isLoadingFirstPage = true

        loadTask = Task {
            do {
                let page = try await service.fetchPage(after: nil)
                guard !Task.isCancelled else { return }
                state.applyFirstPage(page)
                schedulePrefetch()
            } catch {
                state.error = error.localizedDescription
            }
            state.isLoadingFirstPage = false
        }
    }

    private func loadNextPage() {
        guard !state.isLoadingNextPage,
              state.hasNextPage,
              !state.isLoadingFirstPage
        else { return }

        state.isLoadingNextPage = true
        state.error = nil

        loadTask = Task {
            do {
                // ★ Use pre-fetched page if available — zero wait for the user
                let page: Page<FeedItem>
                if let prefetched = prefetchedPage {
                    page = prefetched
                    prefetchedPage = nil
                } else {
                    page = try await service.fetchPage(after: state.nextCursor)
                }
                guard !Task.isCancelled else { return }
                state.applyPage(page)
                schedulePrefetch()
            } catch {
                state.error = error.localizedDescription
            }
            state.isLoadingNextPage = false
        }
    }

    private func refresh() async {
        loadTask?.cancel()
        prefetchTask?.cancel()
        prefetchedPage = nil
        state.reset()
        state.isLoadingFirstPage = true

        do {
            let page = try await service.fetchPage(after: nil)
            state.applyFirstPage(page)
            schedulePrefetch()
        } catch {
            state.error = error.localizedDescription
        }

        state.isLoadingFirstPage = false
    }

    // ★ Trigger next page when user is within threshold items of end
    private func checkPrefetch(for item: FeedItem) {
        guard let index = state.items.firstIndex(where: { $0.id == item.id }),
              index >= state.items.count - prefetchThreshold
        else { return }
        loadNextPage()
    }

    private func schedulePrefetch() {
        guard state.hasNextPage, let cursor = state.nextCursor else { return }
        prefetchTask?.cancel()
        prefetchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            prefetchedPage = try? await service.fetchPage(after: cursor)
        }
    }
}
```

---

## Step 4 — Modular views (~10 min)

```swift
// FeedItemRow.swift
import SwiftUI

struct FeedItemRow: View {
    let item: FeedItem

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray5))
                .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// FeedSkeletonList.swift
struct FeedSkeletonList: View {
    var body: some View {
        ForEach(0..<10, id: \.self) { _ in SkeletonRow() }
    }
}

struct SkeletonRow: View {
    @State private var shimmer = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8).fill(shimmerGradient).frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(shimmerGradient).frame(height: 16)
                RoundedRectangle(cornerRadius: 4).fill(shimmerGradient).frame(width: 140, height: 12)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever()) { shimmer.toggle() }
        }
    }

    private var shimmerGradient: LinearGradient {
        LinearGradient(
            colors: shimmer
                ? [Color(.systemGray5), Color(.systemGray4), Color(.systemGray5)]
                : [Color(.systemGray4), Color(.systemGray5), Color(.systemGray4)],
            startPoint: .leading, endPoint: .trailing
        )
    }
}

// FeedFooter.swift
struct FeedFooter: View {
    let isLoadingNextPage: Bool
    let hasNextPage: Bool
    let error: String?
    let onRetry: () -> Void

    var body: some View {
        HStack {
            Spacer()
            content
            Spacer()
        }
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        if isLoadingNextPage {
            ProgressView()
        } else if let error {
            VStack(spacing: 8) {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Retry", action: onRetry).buttonStyle(.bordered)
            }
        } else if !hasNextPage {
            Text("You're all caught up")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// FeedItemList.swift
struct FeedItemList: View {
    let items: [FeedItem]
    let state: PaginationState
    let onItemAppear: (FeedItem) -> Void
    let onRetry: () -> Void

    var body: some View {
        ForEach(items) { item in
            FeedItemRow(item: item)
                .onAppear { onItemAppear(item) }
        }

        FeedFooter(
            isLoadingNextPage: state.isLoadingNextPage,
            hasNextPage: state.hasNextPage,
            error: state.error,
            onRetry: onRetry
        )
    }
}

// FeedView.swift — root view
struct FeedView: View {
    @State private var vm = FeedViewModel()

    var body: some View {
        NavigationStack {
            List {
                if vm.state.isLoadingFirstPage {
                    FeedSkeletonList()
                } else {
                    FeedItemList(
                        items: vm.state.items,
                        state: vm.state,
                        onItemAppear: { vm.send(.itemAppeared($0)) },
                        onRetry: { vm.send(.retry) }
                    )
                }
            }
            .listStyle(.plain)
            .navigationTitle("Feed")
            .refreshable { vm.send(.refresh) }
            .task { vm.send(.loadFirstPage) }
        }
    }
}
```

---

## Step 5 — Swift Testing suite (~10 min)

```swift
// FeedViewModelTests.swift
import Testing
@testable import InfiniteList

@Suite("FeedViewModel")
struct FeedViewModelTests {

    // MARK: - Helpers

    @MainActor
    private func makeVM(
        pages: [Page<FeedItem>] = [],
        error: Error? = nil,
        prefetchThreshold: Int = 5
    ) async -> (FeedViewModel, MockFeedService) {
        let service = MockFeedService()
        await service.stubPages(pages, error: error)
        let vm = FeedViewModel(service: service, prefetchThreshold: prefetchThreshold)
        return (vm, service)
    }

    // MARK: - Initial state

    @Test @MainActor
    func initialStateIsEmpty() async {
        let (vm, _) = await makeVM()
        #expect(vm.state.items.isEmpty)
        #expect(!vm.state.isLoadingFirstPage)
        #expect(vm.state.hasNextPage)
    }

    // MARK: - First page load

    @Test @MainActor
    func loadFirstPagePopulatesItems() async throws {
        let items = (0..<3).map { _ in FeedItem.stub() }
        let page = Page(items: items, nextCursor: nil)
        let (vm, _) = await makeVM(pages: [page])

        vm.send(.loadFirstPage)
        try await Task.sleep(for: .milliseconds(10))

        #expect(vm.state.items.count == 3)
        #expect(!vm.state.isLoadingFirstPage)
        #expect(!vm.state.hasNextPage)
    }

    @Test @MainActor
    func loadFirstPageSetsLoadingFlag() async {
        let (vm, _) = await makeVM()
        vm.send(.loadFirstPage)
        #expect(vm.state.isLoadingFirstPage)
    }

    @Test @MainActor
    func doubleLoadFirstPageIsIgnored() async throws {
        let page = Page(items: [FeedItem.stub()], nextCursor: nil)
        let (vm, service) = await makeVM(pages: [page])

        vm.send(.loadFirstPage)
        vm.send(.loadFirstPage)     // second call while loading — should be ignored
        try await Task.sleep(for: .milliseconds(10))

        let count = await service.callCount
        #expect(count == 1)
    }

    // MARK: - Next page

    @Test @MainActor
    func loadNextPageAppendsItems() async throws {
        let page1 = Page(items: [FeedItem.stub()], nextCursor: "cursor-2")
        let page2 = Page(items: [FeedItem.stub()], nextCursor: nil)
        let (vm, _) = await makeVM(pages: [page1, page2])

        vm.send(.loadFirstPage)
        try await Task.sleep(for: .milliseconds(10))

        vm.send(.loadNextPage)
        try await Task.sleep(for: .milliseconds(10))

        #expect(vm.state.items.count == 2)
    }

    @Test @MainActor
    func loadNextPageWhenNoNextPageIsNoop() async throws {
        let page = Page(items: [FeedItem.stub()], nextCursor: nil)
        let (vm, service) = await makeVM(pages: [page])

        vm.send(.loadFirstPage)
        try await Task.sleep(for: .milliseconds(10))
        #expect(!vm.state.hasNextPage)

        vm.send(.loadNextPage)
        try await Task.sleep(for: .milliseconds(10))

        let count = await service.callCount
        #expect(count == 1)  // no second call
    }

    // MARK: - Error handling

    @Test @MainActor
    func errorPopulatesStateError() async throws {
        struct FeedTestError: Error, LocalizedError {
            var errorDescription: String? { "Network failure" }
        }
        let (vm, _) = await makeVM(error: FeedTestError())

        vm.send(.loadFirstPage)
        try await Task.sleep(for: .milliseconds(10))

        #expect(vm.state.error == "Network failure")
    }

    // MARK: - Deduplication

    @Test @MainActor
    func duplicateItemsAreFiltered() async throws {
        let duplicate = FeedItem.stub()
        let page1 = Page(items: [duplicate], nextCursor: "next")
        let page2 = Page(items: [duplicate, FeedItem.stub()], nextCursor: nil)
        let (vm, _) = await makeVM(pages: [page1, page2])

        vm.send(.loadFirstPage)
        try await Task.sleep(for: .milliseconds(10))
        vm.send(.loadNextPage)
        try await Task.sleep(for: .milliseconds(10))

        // Duplicate filtered — only 2 unique items
        #expect(vm.state.items.count == 2)
    }

    // MARK: - PaginationState unit tests

    @Test
    func applyPageDeduplicates() {
        var state = PaginationState()
        let item = FeedItem.stub()
        let page1 = Page(items: [item], nextCursor: "c")
        let page2 = Page(items: [item], nextCursor: nil)  // same item again

        state.applyFirstPage(page1)
        state.applyPage(page2)

        #expect(state.items.count == 1)
    }

    @Test
    func resetClearsAllState() {
        var state = PaginationState()
        state.applyFirstPage(Page(items: [FeedItem.stub()], nextCursor: "x"))
        state.reset()

        #expect(state.items.isEmpty)
        #expect(state.nextCursor == nil)
        #expect(state.hasNextPage)
    }
}

// MockFeedService helper
extension MockFeedService {
    func stubPages(_ pages: [Page<FeedItem>], error: Error?) {
        self.pages = pages
        self.error = error
    }
}
```

---

## Key concepts to remember

**`applyPage` on value type:** `PaginationState` is a struct — mutation is isolated. Tests can call `state.applyPage()` directly without any ViewModel, network, or async machinery.

**Prefetch timing:** Trigger load when user is `prefetchThreshold` items from the end (not 1). At Whatnot's scale with live auctions, you prefetch 2+ pages ahead. The threshold is injectable so tests can set it to `1`.

**`MockFeedService.pages` queue:** Stub pages as a `[Page<FeedItem>]` array. Each `fetchPage` call removes and returns the first one — simulates sequential cursor pages deterministically.

---

## Follow-up questions

- *How does cursor pagination handle item deletion?* (Cursor anchors to an ID or timestamp — deleted items are simply absent from results, no index shifting)
- *How would you add bidirectional pagination?* (`BidirectionalState` with `newerCursor` + `olderCursor`, `prepend` + `append` mutating methods)
- *What's the difference between `onAppear` and `UITableViewDataSourcePrefetching`?* (`prefetchRows` fires ~20 rows ahead of visibility; `onAppear` fires at the moment of display — always use a threshold buffer with `onAppear`)
