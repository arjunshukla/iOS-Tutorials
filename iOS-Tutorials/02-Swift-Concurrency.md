# Tutorial 02 — Swift Concurrency
## Build: ParallelFetch — a news aggregator loading from 5 sources simultaneously
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** async/await, Task groups, actors, Sendable, structured concurrency

---

## What you'll build
A news aggregator that:
- Fetches 5 sources in parallel with `TaskGroup`
- Cancels all fetches when the user leaves
- Uses an `actor` to protect a shared cache
- Handles partial failures gracefully

---

## Core concepts map

```
structured concurrency
├── Task {}                    fire-and-forget, inherits actor
├── Task.detached {}           no actor inheritance
├── async let                  parallel, awaited together
└── TaskGroup / ThrowingTaskGroup
        └── withTaskGroup(of:) { group in
                group.addTask { ... }
                for await result in group { ... }
            }

isolation
├── @MainActor                 main thread guarantee
├── actor                      serial access to mutable state
└── Sendable                   safe to cross isolation boundary
```

---

## Project setup

New Xcode project → App → iOS 17+

---

## Step 1 — Models (Sendable is mandatory in Swift 6) (~5 min)

```swift
// Models.swift
import Foundation

// Sendable = safe to send across actor/Task boundaries
struct NewsArticle: Identifiable, Sendable, Hashable {
    let id: UUID
    let source: String
    let title: String
    let publishedAt: Date
    let url: URL
}

struct NewsSource: Sendable {
    let name: String
    let endpoint: URL
}

enum FetchError: Error, Sendable {
    case networkError(String, underlying: Error)
    case decodingError(String)
    case timeout(String)
}

// Per-source fetch status for UI
enum SourceStatus: Sendable {
    case idle
    case loading
    case loaded(Int)      // article count
    case failed(String)
}
```

---

## Step 2 — Cache actor (~10 min)

```swift
// ArticleCache.swift
import Foundation

// actor = reference type with serial access
// Only one caller at a time can enter actor-isolated methods
actor ArticleCache {
    private var articles: [String: [NewsArticle]] = [:]   // keyed by source
    private var lastFetch: [String: Date] = [:]

    static let ttl: TimeInterval = 300  // 5 minutes

    func store(_ articles: [NewsArticle], for source: String) {
        self.articles[source] = articles
        self.lastFetch[source] = .now
    }

    func articles(for source: String) -> [NewsArticle]? {
        guard let fetched = lastFetch[source],
              Date.now.timeIntervalSince(fetched) < ArticleCache.ttl
        else { return nil }
        return articles[source]
    }

    func allArticles() -> [NewsArticle] {
        articles.values.flatMap { $0 }
            .sorted { $0.publishedAt > $1.publishedAt }
    }

    func invalidate(source: String) {
        articles[source] = nil
        lastFetch[source] = nil
    }
}
```

---

## Step 3 — NewsService with parallel fetching (~15 min)

```swift
// NewsService.swift
import Foundation

final class NewsService: Sendable {

    private let cache = ArticleCache()

    static let sources: [NewsSource] = [
        NewsSource(name: "TechCrunch",  endpoint: URL(string: "https://api.example.com/tc")!),
        NewsSource(name: "Hacker News", endpoint: URL(string: "https://api.example.com/hn")!),
        NewsSource(name: "Verge",       endpoint: URL(string: "https://api.example.com/vg")!),
        NewsSource(name: "Wired",       endpoint: URL(string: "https://api.example.com/wd")!),
        NewsSource(name: "Ars",         endpoint: URL(string: "https://api.example.com/at")!),
    ]

    // Fetches ALL sources in parallel, returns partial results on failure
    func fetchAll() async -> [String: Result<[NewsArticle], FetchError>] {
        await withTaskGroup(of: (String, Result<[NewsArticle], FetchError>).self) { group in

            for source in Self.sources {
                group.addTask {
                    // Each task runs concurrently
                    do {
                        let articles = try await self.fetchSource(source)
                        return (source.name, .success(articles))
                    } catch {
                        return (source.name, .failure(.networkError(source.name, underlying: error)))
                    }
                }
            }

            // Collect results as they complete (order not guaranteed)
            var results: [String: Result<[NewsArticle], FetchError>] = [:]
            for await (name, result) in group {
                results[name] = result
            }
            return results
        }
    }

    // async let: fire two requests simultaneously, await both
    func fetchWithMetadata(source: NewsSource) async throws -> ([NewsArticle], Int) {
        async let articles = fetchSource(source)
        async let count    = fetchCount(source)
        return try await (articles, count)
    }

    private func fetchSource(_ source: NewsSource) async throws -> [NewsArticle] {
        // Check cache first
        if let cached = await cache.articles(for: source.name) {
            return cached
        }

        // Simulate network (replace with real URLSession in production)
        try await Task.sleep(for: .milliseconds(Int.random(in: 300...1500)))

        // Simulate occasional failure
        if Bool.random() && source.name == "Wired" {
            throw URLError(.timedOut)
        }

        let articles = (1...Int.random(in: 3...8)).map { i in
            NewsArticle(
                id: UUID(),
                source: source.name,
                title: "\(source.name) headline #\(i): Swift concurrency deep dive",
                publishedAt: Date.now.addingTimeInterval(-Double(i) * 3600),
                url: source.endpoint
            )
        }

        await cache.store(articles, for: source.name)
        return articles
    }

    private func fetchCount(_ source: NewsSource) async throws -> Int {
        try await Task.sleep(for: .milliseconds(100))
        return Int.random(in: 50...500)
    }
}
```

---

## Step 4 — ViewModel wiring structured cancellation (~10 min)

```swift
// NewsViewModel.swift
import Observation

@MainActor
@Observable
final class NewsViewModel {

    var articles: [NewsArticle] = []
    var sourceStatuses: [String: SourceStatus] = [:]
    var isLoading = false
    var error: String?

    private let service = NewsService()
    private var fetchTask: Task<Void, Never>?  // hold reference for cancellation

    func refresh() {
        // Cancel any in-flight fetch before starting a new one
        fetchTask?.cancel()

        isLoading = true
        error = nil

        // Mark all sources as loading
        for source in NewsService.sources {
            sourceStatuses[source.name] = .loading
        }

        fetchTask = Task {
            let results = await service.fetchAll()

            guard !Task.isCancelled else { return }  // ★ always check

            var allArticles: [NewsArticle] = []

            for (name, result) in results {
                switch result {
                case .success(let fetched):
                    sourceStatuses[name] = .loaded(fetched.count)
                    allArticles.append(contentsOf: fetched)
                case .failure(let err):
                    sourceStatuses[name] = .failed(err.localizedDescription)
                    self.error = "Some sources failed to load"
                }
            }

            articles = allArticles.sorted { $0.publishedAt > $1.publishedAt }
            isLoading = false
        }
    }

    func cancelFetch() {
        fetchTask?.cancel()
        isLoading = false
    }

    // Demonstrate async let
    func prefetchFirst() async {
        async let a = service.fetchAll()
        // Do other work here while fetching…
        let results = await a
        print("Prefetched \(results.count) sources")
    }
}
```

---

## Step 5 — SwiftUI view (~10 min)

```swift
// ContentView.swift
import SwiftUI

struct ContentView: View {
    @State private var vm = NewsViewModel()

    var body: some View {
        NavigationStack {
            List {
                // Source status header
                Section("Sources") {
                    ForEach(NewsService.sources, id: \.name) { source in
                        HStack {
                            Text(source.name)
                            Spacer()
                            statusBadge(vm.sourceStatuses[source.name] ?? .idle)
                        }
                    }
                }

                // Articles
                Section("Articles (\(vm.articles.count))") {
                    if vm.articles.isEmpty && !vm.isLoading {
                        Text("Pull to refresh")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(vm.articles) { article in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(article.title)
                                .font(.headline)
                            HStack {
                                Text(article.source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(article.publishedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("News")
            .refreshable { vm.refresh() }
            .toolbar {
                if vm.isLoading {
                    ToolbarItem {
                        Button("Cancel") { vm.cancelFetch() }
                    }
                }
            }
            .overlay {
                if vm.isLoading && vm.articles.isEmpty {
                    ProgressView("Fetching \(NewsService.sources.count) sources…")
                }
            }
        }
        .task { vm.refresh() }   // ★ .task cancels automatically on view disappear
    }

    @ViewBuilder
    func statusBadge(_ status: SourceStatus) -> some View {
        switch status {
        case .idle:           Text("—").foregroundStyle(.tertiary)
        case .loading:        ProgressView().scaleEffect(0.7)
        case .loaded(let n):  Text("\(n)").foregroundStyle(.green)
        case .failed(let e):  Image(systemName: "exclamationmark.triangle")
                                  .foregroundStyle(.red)
                                  .help(e)
        }
    }
}
```

---

## ★ Challenge

1. Add **timeout per source**: wrap each `fetchSource` call in a `Task` and race it against `Task.sleep(for: .seconds(5))` — whichever finishes first wins.

```swift
// Pattern: timeout race
func withTimeout<T: Sendable>(_ seconds: Double, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw FetchError.timeout("Timed out after \(seconds)s")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

2. Add **priority**: use `group.addTask(priority: .high)` for the first source to demonstrate task priority propagation.

---

## Key concepts to remember

**Structured vs unstructured:** `Task {}` is unstructured — you own the lifetime. `.task {}` view modifier is structured — SwiftUI cancels it when the view disappears. Always prefer `.task` in views.

**actor ≠ thread:** Actors don't have dedicated threads. They guarantee serial access by suspending callers. Two actor calls can run on different threads — what matters is they never run simultaneously.

**Sendable crossing:** Passing a non-Sendable type into a `Task` is a Swift 6 compile error. Make your models `Sendable` (structs are implicitly Sendable if all stored properties are too).

---

## Follow-up questions

- *What's the difference between `Task {}` and `Task.detached {}`?*
- *Why can't you `await` inside a `map` or `forEach`?* (They're synchronous — use `withTaskGroup` or `async let` instead)
- *How do you propagate cancellation through your own async functions?* (`Task.checkCancellation()` or `Task.isCancelled`)
- *What happens if you throw inside a `TaskGroup` task?* (The group cancels all siblings and re-throws)
