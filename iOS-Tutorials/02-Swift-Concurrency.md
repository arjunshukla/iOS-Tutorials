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

## Step 4 — State struct + ViewModel with `send(_:)` (~10 min)

```swift
// NewsViewModel.swift
import Observation

// ★ All user intents modeled as an enum
enum NewsAction: Sendable {
    case refresh
    case cancelFetch
    case selectArticle(NewsArticle)    // fires coordinator action
}

// ★ All view state in one Equatable struct
struct NewsState: Equatable {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }
    var phase: Phase = .idle
    var articles: [NewsArticle] = []
    var sourceStatuses: [String: SourceStatus] = [:]
    var partialError: String? = nil    // some sources failed but others loaded
}

@MainActor
protocol NewsViewModelProtocol: AnyObject {
    var state: NewsState { get }
    func send(_ action: NewsAction)
}

@MainActor
@Observable
final class NewsViewModel: NewsViewModelProtocol {

    private(set) var state = NewsState()
    var onArticleSelected: ((NewsArticle) -> Void)?   // coordinator integration

    private let service: any NewsServiceProtocol
    private var fetchTask: Task<Void, Never>?

    init(service: any NewsServiceProtocol = NewsService()) {
        self.service = service
    }

    // ★ Single dispatch point
    func send(_ action: NewsAction) {
        switch action {
        case .refresh:                   refresh()
        case .cancelFetch:               cancelFetch()
        case .selectArticle(let article): onArticleSelected?(article)
        }
    }

    // MARK: - Private handlers

    private func refresh() {
        fetchTask?.cancel()

        state.phase = .loading
        state.partialError = nil

        for source in NewsService.sources {
            state.sourceStatuses[source.name] = .loading
        }

        fetchTask = Task {
            let results = await service.fetchAll()
            guard !Task.isCancelled else { return }

            var allArticles: [NewsArticle] = []
            var hadFailure = false

            for (name, result) in results {
                switch result {
                case .success(let fetched):
                    state.sourceStatuses[name] = .loaded(fetched.count)
                    allArticles.append(contentsOf: fetched)
                case .failure:
                    state.sourceStatuses[name] = .failed("Failed")
                    hadFailure = true
                }
            }

            state.articles = allArticles.sorted { $0.publishedAt > $1.publishedAt }
            state.partialError = hadFailure ? "Some sources failed to load" : nil
            state.phase = .loaded
        }
    }

    private func cancelFetch() {
        fetchTask?.cancel()
        state.phase = state.articles.isEmpty ? .idle : .loaded
    }
}

// NewsServiceProtocol — injectable for testing
protocol NewsServiceProtocol: Sendable {
    func fetchAll() async -> [String: Result<[NewsArticle], FetchError>]
}

extension NewsService: NewsServiceProtocol {}
```

---

## Step 5 — Modular views (~10 min)

```swift
// SourceStatusBadge.swift
import SwiftUI

struct SourceStatusBadge: View {
    let status: SourceStatus

    var body: some View {
        switch status {
        case .idle:           Text("—").foregroundStyle(.tertiary)
        case .loading:        ProgressView().scaleEffect(0.7)
        case .loaded(let n):  Text("\(n)").foregroundStyle(.green)
        case .failed(let e):  Image(systemName: "exclamationmark.triangle")
                                  .foregroundStyle(.red).help(e)
        }
    }
}

// SourceStatusSection.swift
struct SourceStatusSection: View {
    let statuses: [String: SourceStatus]
    let sources: [NewsSource]

    var body: some View {
        Section("Sources") {
            ForEach(sources, id: \.name) { source in
                HStack {
                    Text(source.name)
                    Spacer()
                    SourceStatusBadge(status: statuses[source.name] ?? .idle)
                }
            }
        }
    }
}

// ArticleRow.swift
struct ArticleRow: View {
    let article: NewsArticle
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(article.title).font(.headline)
            HStack {
                Text(article.source).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(article.publishedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// ArticlesSection.swift
struct ArticlesSection: View {
    let articles: [NewsArticle]
    let isLoading: Bool
    let onSelect: (NewsArticle) -> Void

    var body: some View {
        Section("Articles (\(articles.count))") {
            if articles.isEmpty && !isLoading {
                Text("Pull to refresh").foregroundStyle(.secondary)
            }
            ForEach(articles) { article in
                ArticleRow(article: article, onSelect: { onSelect(article) })
            }
        }
    }
}

// NewsView.swift — root view
struct NewsView: View {
    @State private var vm = NewsViewModel()

    var body: some View {
        NavigationStack {
            List {
                SourceStatusSection(
                    statuses: vm.state.sourceStatuses,
                    sources: NewsService.sources
                )
                ArticlesSection(
                    articles: vm.state.articles,
                    isLoading: vm.state.phase == .loading,
                    onSelect: { vm.send(.selectArticle($0)) }
                )
            }
            .navigationTitle("News")
            .refreshable { vm.send(.refresh) }
            .toolbar {
                if vm.state.phase == .loading {
                    ToolbarItem {
                        Button("Cancel") { vm.send(.cancelFetch) }
                    }
                }
            }
            .overlay {
                if vm.state.phase == .loading && vm.state.articles.isEmpty {
                    ProgressView("Fetching \(NewsService.sources.count) sources…")
                }
            }
        }
        .task { vm.send(.refresh) }   // ★ .task auto-cancels on view disappear
    }
}
```

---

## Swift Testing suite

```swift
// NewsViewModelTests.swift
import Testing
@testable import ParallelFetch

// Deterministic mock service
struct MockNewsService: NewsServiceProtocol {
    let results: [String: Result<[NewsArticle], FetchError>]

    func fetchAll() async -> [String: Result<[NewsArticle], FetchError>] { results }
}

@Suite("NewsViewModel")
struct NewsViewModelTests {

    private func article(source: String) -> NewsArticle {
        NewsArticle(
            id: UUID(),
            source: source,
            title: "Test: \(source)",
            publishedAt: .now,
            url: URL(string: "https://example.com")!
        )
    }

    @Test @MainActor
    func initialPhaseIsIdle() {
        let vm = NewsViewModel(service: MockNewsService(results: [:]))
        #expect(vm.state.phase == .idle)
    }

    @Test @MainActor
    func refreshSetsLoadingPhase() {
        let vm = NewsViewModel(service: MockNewsService(results: [:]))
        vm.send(.refresh)
        #expect(vm.state.phase == .loading)
    }

    @Test @MainActor
    func refreshWithSuccessTransitionsToLoaded() async throws {
        let a = article(source: "TechCrunch")
        let service = MockNewsService(results: ["TechCrunch": .success([a])])
        let vm = NewsViewModel(service: service)

        vm.send(.refresh)
        try await Task.sleep(for: .milliseconds(10))

        #expect(vm.state.phase == .loaded)
        #expect(vm.state.articles.count == 1)
    }

    @Test @MainActor
    func refreshWithAllFailuresShowsPartialError() async throws {
        let service = MockNewsService(results: [
            "TechCrunch": .failure(.networkError("TC", underlying: URLError(.notConnectedToInternet)))
        ])
        let vm = NewsViewModel(service: service)

        vm.send(.refresh)
        try await Task.sleep(for: .milliseconds(10))

        #expect(vm.state.partialError != nil)
    }

    @Test @MainActor
    func cancelFetchTransitionsToIdleWhenNoArticles() async throws {
        let vm = NewsViewModel(service: MockNewsService(results: [:]))
        vm.send(.refresh)
        vm.send(.cancelFetch)
        #expect(vm.state.phase == .idle)
    }

    @Test @MainActor
    func selectArticleFiresCallback() async throws {
        let a = article(source: "TechCrunch")
        let service = MockNewsService(results: ["TechCrunch": .success([a])])
        let vm = NewsViewModel(service: service)

        var selectedArticle: NewsArticle?
        vm.onArticleSelected = { selectedArticle = $0 }

        vm.send(.refresh)
        try await Task.sleep(for: .milliseconds(10))
        vm.send(.selectArticle(a))

        #expect(selectedArticle?.id == a.id)
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
