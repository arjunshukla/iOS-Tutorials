# Tutorial 29 — Performance Optimization
## Build: PerfKit — identifying and fixing the most common iOS performance problems
**Time:** 45 min | **Swift 6** | **Topics:** view identity, `Equatable` diffing, lazy loading, `task(id:)`, image rendering, off-main-thread work, `@MainActor` boundaries, memory pressure

---

## Mental model first

Performance problems in SwiftUI/UIKit fall into three buckets:

| Bucket | Symptom | Root cause |
|---|---|---|
| **Unnecessary work** | Jank on scroll, slow renders | Views re-evaluating when nothing changed |
| **Work on wrong thread** | UI freeze | Blocking `@MainActor` with CPU/IO work |
| **Memory pressure** | Crashes, slow launches | Caches growing unbounded, retaining large objects |

Fix in this order. Profiling (Tutorial 30) tells you which bucket you're in.

---

## 1. View identity & unnecessary re-renders

SwiftUI re-renders a view when its inputs change. If inputs change more than they should, views re-render unnecessarily.

### Problem: sharing a large `@Observable` object

```swift
// ❌ Every property change on AppModel re-renders every subscriber
@Observable
final class AppModel {
    var articles: [Article] = []
    var selectedTab: Int = 0
    var searchQuery: String = ""
    var userProfile: UserProfile = UserProfile()
    // ... 20 more properties
}

struct ArticleListView: View {
    var model: AppModel
    // Re-renders when selectedTab changes, even though it uses only articles
    var body: some View {
        List(model.articles) { ... }
    }
}
```

```swift
// ✅ Split into focused observable objects
@Observable final class ArticleFeedModel { var articles: [Article] = [] }
@Observable final class TabModel { var selectedTab: Int = 0 }
@Observable final class SearchModel { var query: String = "" }

struct ArticleListView: View {
    var feedModel: ArticleFeedModel   // only re-renders when articles change
    ...
}
```

### `Equatable` on state structs — diffing at the ViewModel level

```swift
// ✅ ViewModels emit a single Equatable state struct
// SwiftUI can diff the entire state in one comparison
struct FeedState: Equatable {
    var articles: [Article] = []
    var isLoading: Bool = false
}

// In your ViewModel:
// Only assign state when it actually changes
private func updateState(_ new: FeedState) {
    guard new != state else { return }   // skip if identical
    state = new
}
```

### `Equatable` on list rows — prevent list thrashing

```swift
// Each row view is only re-rendered if its data changes
struct ArticleRow: View, Equatable {
    let article: Article
    // SwiftUI uses == to decide whether to re-render
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.article.id == rhs.article.id &&
        lhs.article.title == rhs.article.title
    }
    var body: some View { ... }
}
```

---

## 2. Lazy loading — don't load what isn't visible

### `LazyVStack` vs `VStack`

```swift
// ❌ VStack — creates ALL views immediately, even off-screen
ScrollView {
    VStack {
        ForEach(thousandItems) { ArticleRow(article: $0) }
    }
}

// ✅ LazyVStack — creates views on demand as they scroll into view
ScrollView {
    LazyVStack {
        ForEach(thousandItems) { ArticleRow(article: $0) }
    }
}
```

### Pagination — don't fetch what isn't needed

```swift
// Trigger next page load when the last visible item appears
struct FeedView: View {
    let vm: FeedViewModel

    var body: some View {
        LazyVStack {
            ForEach(vm.state.articles) { article in
                ArticleRow(article: article)
                    .onAppear {
                        if article.id == vm.state.articles.last?.id {
                            vm.send(.loadNextPage)
                        }
                    }
            }
        }
    }
}
```

### Image loading — never decode on the main thread

```swift
// ❌ Decoding image data on MainActor — blocks the UI
struct ArticleRow: View {
    let imageURL: URL
    var body: some View {
        // AsyncImage internally dispatches to a background thread ✓
        // But this is correct — shown for contrast
        AsyncImage(url: imageURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.gray.opacity(0.2)
        }
    }
}

// ✅ For custom image loading — decode off main thread
actor ImageDecoder {
    func decode(data: Data) -> UIImage? {
        // Runs on the actor's executor — not on MainActor
        UIImage(data: data)
    }
}
```

---

## 3. Work on the wrong thread

### Never block `@MainActor` with CPU work

```swift
// ❌ JSON parsing on MainActor — freezes UI
@MainActor
func handleResponse(_ data: Data) {
    let articles = try! JSONDecoder().decode([Article].self, from: data)  // CPU work on main thread
    state.articles = articles
}

// ✅ Decode on a background task, publish result to main
func handleResponse(_ data: Data) async {
    // Task.detached runs without inheriting MainActor isolation
    let articles = await Task.detached(priority: .userInitiated) {
        try? JSONDecoder().decode([Article].self, from: data)
    }.value ?? []

    await MainActor.run {
        state.articles = articles   // UI update — back on main
    }
}
```

### Actor for shared mutable state off main thread

```swift
// ✅ Sorting and filtering on a dedicated actor — never touches MainActor
actor FilterEngine {
    func filter(_ articles: [Article], query: String) -> [Article] {
        guard !query.isEmpty else { return articles }
        return articles.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    func sort(_ articles: [Article], by key: SortKey) -> [Article] {
        switch key {
        case .date:   return articles.sorted { $0.publishedAt > $1.publishedAt }
        case .title:  return articles.sorted { $0.title < $1.title }
        }
    }
}

// In ViewModel:
private let engine = FilterEngine()

private func applyFilter(query: String) {
    Task {
        let filtered = await engine.filter(state.articles, query: query)
        state.displayArticles = filtered   // @MainActor property — safe here
    }
}
```

---

## 4. `task(id:)` — cancel stale work automatically

```swift
// ❌ Without task(id:): old search tasks pile up, results arrive out of order
.task {
    await vm.send(.search(query))
}

// ✅ task(id:) cancels the previous task when id changes
// No manual debounce needed for cancellation — wrong results can't win
.task(id: searchQuery) {
    await vm.send(.search(searchQuery))
}
```

---

## 5. Memory — prevent unbounded growth

### `NSCache` — automatic eviction under memory pressure

```swift
// ✅ NSCache automatically evicts entries when the OS requests memory
// Never use a plain [Key: Value] dict as an image cache
final class ImageCache {
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 200        // max 200 images
        cache.totalCostLimit = 50 * 1024 * 1024   // 50 MB
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * 4)  // bytes
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}
```

### Weak references — break retain cycles

```swift
// ❌ Retain cycle: ViewModel retains closure; closure retains ViewModel
vm.onEvent = { [vm] event in   // strong capture — cycle!
    vm.handleEvent(event)
}

// ✅ Weak capture breaks the cycle
vm.onEvent = { [weak vm] event in
    vm?.handleEvent(event)
}
```

### Large object deallocation — `onDisappear` cleanup

```swift
struct VideoPlayerView: View {
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player = AVPlayer(url: videoURL) }
            .onDisappear {
                player?.pause()
                player = nil   // release the player and its resources
            }
    }
}
```

---

## 6. Rendering — reduce overdraw

```swift
// ❌ Multiple overlapping opaque layers — GPU blends them all
ZStack {
    Color.white
    Color.white.opacity(0.9)   // redundant — already opaque below
    ContentView()
}

// ✅ Use drawingGroup() to flatten complex composited views into one texture
ComplexAnimatedView()
    .drawingGroup()   // offscreen render → single GPU pass

// ✅ For static content that never changes: use fixedSize() to prevent
// layout re-evaluation on every parent update
StaticBadgeView()
    .fixedSize()
```

---

## 7. Launch time — don't do work at startup

```swift
// ❌ Fetching data in App.init — blocks launch
@main
struct PerfKitApp: App {
    init() {
        DataStore.shared.loadFromDisk()   // synchronous disk IO at launch
    }
}

// ✅ Defer to .task on the root view — after first frame renders
@main
struct PerfKitApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .task { await DataStore.shared.loadFromDisk() }
        }
    }
}
```

---

## Production ViewModel with all optimizations applied

```swift
// OptimizedFeedViewModel.swift
import Foundation

enum SortKey: Sendable { case date, title }

struct OptimizedFeedState: Equatable {
    var allArticles: [Article] = []
    var displayArticles: [Article] = []
    var isLoading: Bool = false
    var searchQuery: String = ""
    var sortKey: SortKey = .date

    // Custom == to skip irrelevant fields
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.displayArticles == rhs.displayArticles &&
        lhs.isLoading == rhs.isLoading &&
        lhs.searchQuery == rhs.searchQuery &&
        lhs.sortKey == rhs.sortKey
    }
}

enum OptimizedFeedAction: Sendable {
    case load
    case search(String)
    case sort(SortKey)
}

@MainActor
@Observable
final class OptimizedFeedViewModel {

    private(set) var state = OptimizedFeedState()

    private let service: any FeedServiceProtocol
    private let engine = FilterEngine()
    private var filterTask: Task<Void, Never>?

    init(service: any FeedServiceProtocol) { self.service = service }
    init() { self.service = LiveFeedService() }

    func send(_ action: OptimizedFeedAction) {
        switch action {
        case .load:               Task { await load() }
        case .search(let query):  scheduleFilter(query: query, sort: state.sortKey)
        case .sort(let key):      scheduleFilter(query: state.searchQuery, sort: key)
        }
    }

    // MARK: - Private

    private func load() async {
        state.isLoading = true
        if let articles = try? await service.fetchArticles() {
            state.allArticles = articles
            scheduleFilter(query: state.searchQuery, sort: state.sortKey)
        }
        state.isLoading = false
    }

    // Cancel previous filter task before starting new one — task(id:) equivalent
    private func scheduleFilter(query: String, sort: SortKey) {
        state.searchQuery = query
        state.sortKey = sort
        filterTask?.cancel()
        filterTask = Task {
            // Off-MainActor filtering
            let filtered = await engine.filter(state.allArticles, query: query)
            guard !Task.isCancelled else { return }
            let sorted = await engine.sort(filtered, by: sort)
            guard !Task.isCancelled else { return }
            // Only update state if result actually changed
            if sorted != state.displayArticles {
                state.displayArticles = sorted
            }
        }
    }
}
```

---

## Checklist — performance review before shipping

```
Views
  [ ] Large lists use LazyVStack / LazyHGrid / List (not VStack)
  [ ] Row views are Equatable where possible
  [ ] @Observable objects are focused (not one giant model)
  [ ] No synchronous disk/network IO in body or init

Threading
  [ ] JSON decoding happens off MainActor
  [ ] Image decoding happens off MainActor
  [ ] Sorting/filtering delegated to an actor or Task.detached

Memory
  [ ] Image caches use NSCache with countLimit + totalCostLimit
  [ ] Closures capturing self use [weak self]
  [ ] Large resources (AVPlayer, ARSession) released in onDisappear

Launch
  [ ] No synchronous work in App.init or scene(_:willConnectTo:)
  [ ] First meaningful content renders in <400 ms
```

---

## Interview questions

| Question | Concept |
|---|---|
| "How do you reduce unnecessary SwiftUI re-renders?" | Focused `@Observable` objects, `Equatable` state structs |
| "What's the difference between `LazyVStack` and `VStack`?" | Lazy creates views on demand; `VStack` creates all upfront |
| "How do you move work off the main thread in Swift 6?" | `Task.detached`, dedicated `actor`, then `await MainActor.run` |
| "How do you prevent image cache memory growth?" | `NSCache` with `countLimit` and `totalCostLimit` |
| "What causes retain cycles in Swift?" | Strong closure captures — break with `[weak self]` |
| "How do you cancel stale search tasks?" | `task(id: searchQuery)` or manual `filterTask?.cancel()` |
| "What blocks app launch time?" | Synchronous disk/network IO in init — defer with `.task` |
