# Tutorial 08 — Pagination
## Build: InfiniteList — a feed with cursor-based pagination
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** Cursor vs offset pagination, prefetching, pull-to-refresh, skeleton loading

---

## What you'll build
An infinite-scroll list with:
- Cursor-based pagination (production standard)
- Prefetch 2 pages ahead of the visible position
- Pull-to-refresh that resets pagination
- Skeleton loading placeholders
- Deduplication of items across pages

---

## Cursor vs Offset pagination

```
Offset pagination:                  Cursor pagination:
GET /items?page=2&limit=20          GET /items?after=<cursor>&limit=20

Problems:                           Advantages:
- Items inserted during scroll      - Stable across inserts
  shift page boundaries             - Works with real-time feeds
- Expensive COUNT(*) queries        - Server can use indexed seek
- Can skip or duplicate items       - Used by Twitter, Instagram, Whatnot
```

---

## Step 1 — Page and cursor models (~5 min)

```swift
// PaginationModels.swift
import Foundation

struct Page<T: Sendable>: Sendable {
    let items: [T]
    let nextCursor: String?    // nil = last page
    let previousCursor: String?
    let totalCount: Int?       // optional — not always available

    var hasNextPage: Bool { nextCursor != nil }
    var isEmpty: Bool { items.isEmpty }
}

struct FeedItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let title: String
    let subtitle: String
    let imageURL: URL?
    let timestamp: Date
    let cursor: String   // the cursor that produced this item

    static func generate(cursor: String? = nil) -> FeedItem {
        let id = UUID()
        return FeedItem(
            id: id,
            title: "Item \(Int.random(in: 1000...9999))",
            subtitle: "Posted \(Int.random(in: 1...60)) minutes ago",
            imageURL: URL(string: "https://picsum.photos/seed/\(id)/300/200"),
            timestamp: .now.addingTimeInterval(-Double.random(in: 0...3600)),
            cursor: cursor ?? UUID().uuidString
        )
    }
}

struct PaginationState: Sendable {
    var items: [FeedItem] = []
    var nextCursor: String? = nil
    var isLoadingFirstPage: Bool = false
    var isLoadingNextPage: Bool = false
    var hasNextPage: Bool = true
    var error: String? = nil
    var seenIDs: Set<UUID> = []   // deduplication

    mutating func apply(_ page: Page<FeedItem>) {
        // Deduplicate in case of overlapping pages
        let newItems = page.items.filter { !seenIDs.contains($0.id) }
        seenIDs.formUnion(newItems.map(\.id))
        items.append(contentsOf: newItems)
        nextCursor = page.nextCursor
        hasNextPage = page.hasNextPage
    }
}
```

---

## Step 2 — Feed service (~10 min)

```swift
// FeedService.swift
import Foundation

// Simulates a cursor-based API
actor FeedService {

    static let pageSize = 20

    func fetchPage(after cursor: String? = nil) async throws -> Page<FeedItem> {
        // Simulate network latency
        try await Task.sleep(for: .milliseconds(Int.random(in: 600...1000)))

        // Simulate occasional error
        if Bool.random() && Bool.random() {
            throw FeedError.networkError
        }

        // Generate a page of items
        let items = (0..<Self.pageSize).map { _ in
            FeedItem.generate(cursor: cursor)
        }

        // Return nil nextCursor after 5 pages to simulate end
        let pageNumber = cursor.map { Int($0.prefix(1)) ?? 0 } ?? 0
        let nextCursor = pageNumber < 5 ? String(pageNumber + 1) + UUID().uuidString : nil

        return Page(
            items: items,
            nextCursor: nextCursor,
            previousCursor: cursor,
            totalCount: nil
        )
    }
}

enum FeedError: Error {
    case networkError
}
```

---

## Step 3 — ViewModel with prefetch logic (~15 min)

```swift
// FeedViewModel.swift
import Observation

@MainActor
@Observable
final class FeedViewModel {

    private(set) var state = PaginationState()
    private let service = FeedService()
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedPage: Page<FeedItem>?   // pre-loaded next page

    // MARK: - Public interface

    func loadFirstPage() {
        guard !state.isLoadingFirstPage else { return }
        loadTask?.cancel()

        state = PaginationState()  // reset

        loadTask = Task {
            state.isLoadingFirstPage = true
            state.error = nil

            do {
                let page = try await service.fetchPage(after: nil)
                guard !Task.isCancelled else { return }
                state.apply(page)
                // Immediately prefetch page 2
                schedulePrefetch()
            } catch {
                state.error = error.localizedDescription
            }

            state.isLoadingFirstPage = false
        }
    }

    func loadNextPage() {
        guard !state.isLoadingNextPage,
              state.hasNextPage,
              !state.isLoadingFirstPage
        else { return }

        loadTask = Task {
            state.isLoadingNextPage = true
            state.error = nil

            do {
                // Use pre-fetched page if available
                let page: Page<FeedItem>
                if let prefetched = prefetchedPage {
                    page = prefetched
                    prefetchedPage = nil
                } else {
                    page = try await service.fetchPage(after: state.nextCursor)
                }

                guard !Task.isCancelled else { return }
                state.apply(page)

                // Pre-fetch next page
                schedulePrefetch()

            } catch {
                state.error = error.localizedDescription
            }

            state.isLoadingNextPage = false
        }
    }

    func refresh() async {
        loadTask?.cancel()
        prefetchTask?.cancel()
        prefetchedPage = nil

        state = PaginationState()
        state.isLoadingFirstPage = true

        do {
            let page = try await service.fetchPage(after: nil)
            state.apply(page)
            schedulePrefetch()
        } catch {
            state.error = error.localizedDescription
        }

        state.isLoadingFirstPage = false
    }

    // ★ Prefetch: called when user is N items from the end
    func onItemAppeared(item: FeedItem) {
        let threshold = 5  // trigger load when 5 items from end
        guard let index = state.items.firstIndex(where: { $0.id == item.id }),
              index >= state.items.count - threshold
        else { return }
        loadNextPage()
    }

    // MARK: - Private

    private func schedulePrefetch() {
        guard state.hasNextPage, let cursor = state.nextCursor else { return }
        prefetchTask?.cancel()
        prefetchTask = Task {
            // Slight delay so first page renders before we start prefetch
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let page = try? await service.fetchPage(after: cursor)
            guard !Task.isCancelled else { return }
            prefetchedPage = page
        }
    }
}
```

---

## Step 4 — SwiftUI view with skeleton loading (~15 min)

```swift
// FeedView.swift
import SwiftUI

struct FeedView: View {
    @State private var vm = FeedViewModel()

    var body: some View {
        NavigationStack {
            List {
                // Skeleton loading for first page
                if vm.state.isLoadingFirstPage {
                    ForEach(0..<10, id: \.self) { _ in
                        SkeletonRow()
                    }
                } else {
                    // Actual items
                    ForEach(vm.state.items) { item in
                        FeedRow(item: item)
                            .onAppear { vm.onItemAppeared(item: item) }
                    }

                    // Next-page loader / end state
                    if vm.state.isLoadingNextPage {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                    } else if !vm.state.hasNextPage {
                        HStack {
                            Spacer()
                            Text("You're all caught up 🎉")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                    }

                    // Error + retry
                    if let error = vm.state.error {
                        VStack {
                            Text(error).font(.caption).foregroundStyle(.red)
                            Button("Retry") { vm.loadNextPage() }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Feed")
            .refreshable { await vm.refresh() }
            .task { vm.loadFirstPage() }
        }
    }
}

struct FeedRow: View {
    let item: FeedItem

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray5))
                .frame(width: 60, height: 60)
                .overlay(
                    Text("📷")
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// Shimmer skeleton placeholder
struct SkeletonRow: View {
    @State private var shimmer: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(gradient)
                .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(gradient)
                    .frame(height: 16)
                RoundedRectangle(cornerRadius: 4)
                    .fill(gradient)
                    .frame(width: 140, height: 12)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever()) {
                shimmer.toggle()
            }
        }
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: shimmer
                ? [Color(.systemGray5), Color(.systemGray4), Color(.systemGray5)]
                : [Color(.systemGray4), Color(.systemGray5), Color(.systemGray4)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
```

---

## ★ Challenge

Implement **bidirectional pagination** — support loading both newer and older content (like a message thread where you join in the middle):

```swift
struct BidirectionalState<T: Identifiable & Sendable & Hashable> {
    var items: [T] = []
    var newerCursor: String? = nil
    var olderCursor: String? = nil
    var isLoadingNewer = false
    var isLoadingOlder = false

    mutating func prepend(_ page: Page<T>) { ... }
    mutating func append(_ page: Page<T>) { ... }
}
```

---

## Key concepts to remember

**Why cursor over offset?** A live feed with new items inserted between loads will show duplicates with offset pagination (page 2 slides to become the old page 1 content). Cursors are anchored to a specific item.

**Prefetch timing:** Start prefetch when the user is 5 items from the end (not 1). Network latency means you need a buffer. At Whatnot's scale with live auctions, you'd prefetch entire next pages as background Tasks.

**Deduplication:** Even with cursors, real-time inserts can cause edge items to appear on two pages. Always check `seenIDs`.

---

## Follow-up questions

- *How does cursor pagination work when items are deleted?* (Cursor is anchored to item ID or timestamp; deleted items are just absent from results)
- *How would you implement page caching?* (Store `[cursor: Page]` in the cache actor from Tutorial 07)
- *What's the difference between `onAppear` and `prefetchRows` in UIKit?* (`UITableViewDataSourcePrefetching` triggers earlier than `onAppear` — at 20+ rows ahead)
