# Tutorial 27 — Task Lifecycle: Backgrounding, Navigation, & Termination
## Build: FetchKit — a network layer that cleans up after itself
**Time:** 45 min | **Swift 6** | **Topics:** `scenePhase`, `task(id:)`, `.task {}`, `onDisappear`, `BGProcessingTask`, termination handling, cooperative cancellation

---

## The core problem

A network call is in-flight. Then one of these happens:
- User swipes to another screen
- User presses the home button
- Device battery dies / OS kills the app

In all three cases, the right behavior is the same: **cancel the work, save enough state to resume, release resources.** The difference is how much time you have.

| Event | Time budget | What to do |
|---|---|---|
| Navigate away | Unlimited (app still foreground) | Cancel task, update state |
| App backgrounded | ~5 seconds before suspension | Cancel tasks, persist draft state |
| OS termination (low memory / battery) | ~0 seconds | Already handled if backgrounding is correct |

---

## Concept 1 — How Swift cancellation works

Swift concurrency uses **cooperative cancellation**. The runtime sets a flag; your code checks it.

```swift
// The runtime sets Task.isCancelled = true
// Your code must check and react

func fetchFeed() async throws -> [Article] {
    try Task.checkCancellation()   // throws CancellationError if cancelled

    let data = try await URLSession.shared.data(from: url)

    try Task.checkCancellation()   // check again after each await point

    return try JSONDecoder().decode([Article].self, from: data)
}
```

`URLSession` respects cancellation automatically — when the parent `Task` is cancelled, any in-flight `URLSession.data(from:)` throws `CancellationError`.

---

## Concept 2 — `.task {}` modifier (preferred)

SwiftUI's `.task {}` modifier ties a `Task` to a view's lifetime:

```swift
struct FeedView: View {
    var body: some View {
        List { ... }
            .task {
                // Started when view appears
                // Automatically cancelled when view disappears
                await vm.send(.load)
            }
    }
}
```

No manual `onAppear` / `onDisappear` cleanup needed. This is the recommended approach for view-scoped async work.

### `.task(id:)` — restart on value change

```swift
.task(id: vm.state.selectedFilter) {
    // Cancelled and restarted whenever selectedFilter changes
    await vm.send(.load)
}
```

---

## Concept 3 — Manual task management

When you need more control (e.g., tasks started by user interaction, not view appearance):

```swift
@MainActor
@Observable
final class FeedViewModel {
    private var loadTask: Task<Void, Never>?

    func send(_ action: FeedAction) {
        switch action {
        case .load:
            loadTask?.cancel()   // cancel any existing fetch first
            loadTask = Task { await load() }
        case .cancel:
            loadTask?.cancel()
            loadTask = nil
        }
    }
}
```

Always cancel the previous task before starting a new one — otherwise two fetches race.

---

## Concept 4 — `scenePhase` — detecting background/foreground

```swift
@Environment(\.scenePhase) private var scenePhase

var body: some View {
    FeedView()
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                vm.send(.resumeIfNeeded)
            case .inactive:
                break   // briefly inactive (e.g. Control Center) — don't cancel yet
            case .background:
                vm.send(.appDidBackground)
            @unknown default:
                break
            }
        }
}
```

**`inactive` ≠ `background`**: the app goes `.inactive` during transitions (incoming call overlay, Control Center). Only cancel on `.background`.

---

## Concept 5 — Battery death / OS termination

The OS sends **no notification** on battery death. It does send `applicationWillTerminate` for normal termination, but this is not guaranteed when the OS kills the app for memory pressure.

**The correct strategy**: treat `scenePhase == .background` as if the process might never return.
- Persist all draft/unsaved state there
- Cancel all in-flight tasks there
- On next launch, restore from persisted state (see Tutorial 28)

```swift
// In your AppDelegate or scene delegate
func sceneDidEnterBackground(_ scene: UIScene) {
    // You have ~5 seconds. Save state here.
    persistenceService.saveCheckpoint()
}
```

---

## Production example

### Models

```swift
// Models.swift
import Foundation

enum FetchStatus: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case cancelled
    case failed(String)
}

struct FeedState: Equatable {
    var status: FetchStatus = .idle
    var articles: [Article] = []
    var pendingCount: Int = 0         // tasks in flight
    var lastLoadedAt: Date? = nil
}

struct Article: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let title: String
    let source: String
    let publishedAt: Date
}

enum FeedAction: Sendable {
    case load
    case cancel
    case appDidBackground
    case resumeIfNeeded
}
```

---

### Service

```swift
// FeedServiceProtocol.swift
import Foundation

protocol FeedServiceProtocol: Sendable {
    func fetchArticles() async throws -> [Article]
}

struct LiveFeedService: FeedServiceProtocol {
    func fetchArticles() async throws -> [Article] {
        // URLSession respects task cancellation automatically
        let url = URL(string: "https://api.example.com/articles")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([Article].self, from: data)
    }
}

struct MockFeedService: FeedServiceProtocol {
    var articles: [Article] = []
    var delay: Duration = .zero
    var shouldFail = false

    func fetchArticles() async throws -> [Article] {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()   // respect cancellation even in mock
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return articles
    }
}
```

---

### ViewModel

```swift
// FeedViewModel.swift
import Foundation

@MainActor
protocol FeedViewModelProtocol: AnyObject, Observable {
    var state: FeedState { get }
    func send(_ action: FeedAction)
}

@MainActor
@Observable
final class FeedViewModel: FeedViewModelProtocol {

    private(set) var state = FeedState()

    private let service: any FeedServiceProtocol
    private var loadTask: Task<Void, Never>?

    init(service: any FeedServiceProtocol) { self.service = service }
    init() { self.service = LiveFeedService() }

    func send(_ action: FeedAction) {
        switch action {
        case .load:             startLoad()
        case .cancel:           cancelLoad(reason: .cancelled)
        case .appDidBackground: handleBackground()
        case .resumeIfNeeded:   resumeIfStale()
        }
    }

    // MARK: - Private

    private func startLoad() {
        guard state.status != .loading else { return }
        loadTask?.cancel()
        state.status = .loading

        loadTask = Task {
            do {
                let articles = try await service.fetchArticles()
                // Check cancellation after the await — view may have disappeared
                guard !Task.isCancelled else { return }
                state.articles = articles
                state.status = .loaded
                state.lastLoadedAt = Date()
            } catch is CancellationError {
                // Normal — user navigated away or app backgrounded
                // Only update status if we didn't already mark it cancelled
                if state.status == .loading {
                    state.status = .cancelled
                }
            } catch {
                state.status = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelLoad(reason: FetchStatus) {
        loadTask?.cancel()
        loadTask = nil
        if state.status == .loading {
            state.status = reason
        }
    }

    private func handleBackground() {
        // Cancel in-flight work. State persisted separately (see Tutorial 28).
        cancelLoad(reason: .cancelled)
    }

    private func resumeIfStale() {
        // Re-fetch only if data is older than 5 minutes
        guard let lastLoaded = state.lastLoadedAt else {
            startLoad()
            return
        }
        if Date().timeIntervalSince(lastLoaded) > 5 * 60 {
            startLoad()
        }
    }
}
```

---

### Views

```swift
// FeedView.swift
import SwiftUI

struct FeedRootView: View {
    @State private var vm: any FeedViewModelProtocol
    @Environment(\.scenePhase) private var scenePhase

    init(vm: any FeedViewModelProtocol) { self._vm = State(initialValue: vm) }

    var body: some View {
        FeedView(vm: vm)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: vm.send(.appDidBackground)
                case .active:     vm.send(.resumeIfNeeded)
                default:          break
                }
            }
    }
}

struct FeedView: View {
    let vm: any FeedViewModelProtocol

    var body: some View {
        NavigationStack {
            Group {
                switch vm.state.status {
                case .idle:               Color.clear
                case .loading:            LoadingView()
                case .loaded:             ArticleList(articles: vm.state.articles)
                case .cancelled:          CancelledView { vm.send(.load) }
                case .failed(let msg):    ErrorView(message: msg) { vm.send(.load) }
                }
            }
            .navigationTitle("Feed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if vm.state.status == .loading {
                        Button("Cancel") { vm.send(.cancel) }
                    }
                }
            }
            // .task ties load to view lifetime — auto-cancelled on disappear
            .task { vm.send(.load) }
        }
    }
}

// MARK: - Subviews

struct ArticleList: View {
    let articles: [Article]
    var body: some View {
        List(articles) { article in
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title).font(.headline)
                Text(article.source).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading…").foregroundStyle(.secondary)
        }
    }
}

struct CancelledView: View {
    let onRetry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Fetch cancelled", systemImage: "xmark.circle")
        } actions: {
            Button("Retry", action: onRetry)
        }
    }
}

struct ErrorView: View {
    let message: String
    let onRetry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: onRetry)
        }
    }
}
```

---

## Tests

```swift
// FeedViewModelTests.swift
import Testing
@testable import FetchKit

private let sampleArticles = [
    Article(id: "1", title: "Swift 6 is here", source: "Swift.org", publishedAt: Date()),
    Article(id: "2", title: "WWDC 2026", source: "Apple", publishedAt: Date())
]

@Suite("FeedViewModel — Task Lifecycle")
@MainActor
struct FeedViewModelTests {

    func makeVM(articles: [Article] = sampleArticles,
                delay: Duration = .zero,
                fail: Bool = false) -> FeedViewModel {
        FeedViewModel(service: MockFeedService(articles: articles, delay: delay, shouldFail: fail))
    }

    @Test func initialStatusIsIdle() {
        #expect(makeVM().state.status == .idle)
    }

    @Test func loadTransitionsToLoading() {
        let vm = makeVM(delay: .seconds(60))
        vm.send(.load)
        #expect(vm.state.status == .loading)
    }

    @Test func loadCompletesWithArticles() async {
        let vm = makeVM()
        vm.send(.load)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.state.status == .loaded)
        #expect(vm.state.articles.count == sampleArticles.count)
    }

    @Test func cancelDuringLoadSetsCancelledStatus() async {
        let vm = makeVM(delay: .seconds(60))
        vm.send(.load)
        vm.send(.cancel)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.state.status == .cancelled)
    }

    @Test func backgroundingCancelsLoad() async {
        let vm = makeVM(delay: .seconds(60))
        vm.send(.load)
        vm.send(.appDidBackground)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.state.status == .cancelled)
    }

    @Test func secondLoadCancelsPreviousLoad() async {
        let vm = makeVM()
        vm.send(.load)
        vm.send(.load)   // should cancel first, start second
        try? await Task.sleep(for: .milliseconds(50))
        // Only one load completes — no duplicate results
        #expect(vm.state.articles.count == sampleArticles.count)
    }

    @Test func resumeIfNeededFetchesWhenNoData() async {
        let vm = makeVM()
        vm.send(.resumeIfNeeded)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.state.status == .loaded)
    }

    @Test func resumeIfNeededSkipsWhenDataIsFresh() async {
        let vm = makeVM()
        vm.send(.load)
        try? await Task.sleep(for: .milliseconds(50))
        let countBefore = vm.state.articles.count
        vm.send(.resumeIfNeeded)   // data is <5 min old — should skip
        #expect(vm.state.articles.count == countBefore)
    }

    @Test func failureSetsFailedStatus() async {
        let vm = makeVM(fail: true)
        vm.send(.load)
        try? await Task.sleep(for: .milliseconds(50))
        if case .failed = vm.state.status { } else {
            Issue.record("Expected .failed, got \(vm.state.status)")
        }
    }

    @Test func lastLoadedAtSetAfterSuccess() async {
        let vm = makeVM()
        vm.send(.load)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.state.lastLoadedAt != nil)
    }

    @Test func lastLoadedAtNilAfterCancel() async {
        let vm = makeVM(delay: .seconds(60))
        vm.send(.load)
        vm.send(.cancel)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.state.lastLoadedAt == nil)
    }
}
```

---

## Decision tree for in-flight tasks

```
User navigates away
    └── Using .task {} modifier?
            YES → SwiftUI cancels automatically ✓
            NO  → Cancel in onDisappear or ViewModel deinit

App backgrounded (scenePhase == .background)
    └── Cancel all tasks
    └── Persist state (→ Tutorial 28)
    └── Time budget: ~5 seconds

OS kills app (low memory / battery)
    └── No notification — rely on background handler having run
    └── On relaunch: restore from last checkpoint (→ Tutorial 28)
```

## Interview questions

| Question | Concept |
|---|---|
| "What happens to a Task when the view disappears?" | `.task {}` cancels it; manual tasks live on unless you cancel |
| "How do you cancel a URLSession request in async/await?" | Cancel the parent Task — URLSession cooperates |
| "What's the difference between `.inactive` and `.background`?" | `.inactive` is transient (overlays); only cancel on `.background` |
| "How do you handle the app being killed with no warning?" | Persist on `.background` — termination gives no additional time |
| "What is cooperative cancellation?" | Runtime sets a flag; your code checks `Task.isCancelled` or `checkCancellation()` |
