# Tutorial 04 — Debouncing
## Build: LiveSearch — real-time search with smart request throttling
**Time:** 45 min | **Swift 6 + SwiftUI** | **Topics:** Debounce, Task cancellation, AsyncStream, MVVM state machine, Swift Testing

---

## What you'll build
A search bar that:
- Waits 300ms after the user stops typing before fetching
- Cancels in-flight requests when a new query arrives
- Shows `idle → typing → searching → loaded / empty / failed` states
- Implemented with `async/await` Task cancellation (Swift 6 canonical)

---

## What debouncing solves

Typing "swift" fires 5 keystrokes: `s → sw → swi → swif → swift`

With 300ms debounce, only `swift` reaches the network — after the user pauses.

---

## Architecture

```
LiveSearchView
├── SearchBarView           ← text field, fires queryChanged action
├── SearchPhaseView         ← typing / searching / loaded / empty / failed banner
└── SearchResultsList       ← list of results, fires selectResult action

SearchViewModel             ← owns state, exposes send(_:)
└── SearchServiceProtocol   ← injectable search backend
```

---

## Step 1 — Models (~5 min)

```swift
// Models.swift
import Foundation

struct SearchResult: Identifiable, Sendable, Hashable {
    let id: Int
    let title: String
    let category: String
}

// ★ State machine phases as an enum — exhaustive, UI-driven
enum SearchPhase: Equatable, Sendable {
    case idle
    case typing
    case searching
    case loaded(count: Int)
    case empty
    case failed(String)
}

// ★ All VM state in one value type
struct SearchState: Equatable {
    var query: String      = ""
    var results: [SearchResult] = []
    var phase: SearchPhase = .idle
}
```

---

## Step 2 — Service protocol (~5 min)

```swift
// SearchService.swift
import Foundation

// ★ Protocol = swap URLSession for MockSearchService in tests
protocol SearchServiceProtocol: Sendable {
    func search(query: String) async throws -> [SearchResult]
}

struct LiveSearchService: SearchServiceProtocol {
    func search(query: String) async throws -> [SearchResult] {
        // Replace with real URLSession call
        try await Task.sleep(for: .milliseconds(400))

        let corpus: [SearchResult] = [
            SearchResult(id: 1, title: "Swift Concurrency Guide",  category: "Swift"),
            SearchResult(id: 2, title: "SwiftUI Layout Deep Dive",  category: "SwiftUI"),
            SearchResult(id: 3, title: "Swift Generics Explained",  category: "Swift"),
            SearchResult(id: 4, title: "Combine Framework Primer",  category: "Combine"),
            SearchResult(id: 5, title: "Swift Package Manager",     category: "Tooling"),
        ]

        return corpus.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.category.localizedCaseInsensitiveContains(query)
        }
    }
}

// Mock for tests — no network, no wait
actor MockSearchService: SearchServiceProtocol {
    var stubbedResults: [SearchResult] = []
    var stubbedError: Error? = nil
    private(set) var callCount = 0

    func search(query: String) async throws -> [SearchResult] {
        callCount += 1
        if let error = stubbedError { throw error }
        return stubbedResults
    }
}
```

---

## Step 3 — ViewModel with `send(_:)` dispatch (~15 min)

```swift
// SearchViewModel.swift
import Observation
import Foundation

enum SearchAction: Sendable {
    case queryChanged(String)
    case selectResult(SearchResult)
    case clearQuery
    case retry
}

@MainActor
protocol SearchViewModelProtocol: AnyObject {
    var state: SearchState { get }
    func send(_ action: SearchAction)
}

@MainActor
@Observable
final class SearchViewModel: SearchViewModelProtocol {

    private(set) var state = SearchState()

    private var debounceTask: Task<Void, Never>?
    private let service: any SearchServiceProtocol
    private let debounceInterval: Duration

    // Coordinator integration
    var onResultSelected: ((SearchResult) -> Void)?

    init(
        service: any SearchServiceProtocol = LiveSearchService(),
        debounceInterval: Duration = .milliseconds(300)
    ) {
        self.service = service
        self.debounceInterval = debounceInterval
    }

    // ★ Single dispatch — state machine switch
    func send(_ action: SearchAction) {
        switch action {
        case .queryChanged(let q):  handleQueryChange(q)
        case .selectResult(let r):  onResultSelected?(r)
        case .clearQuery:           clearQuery()
        case .retry:                handleQueryChange(state.query)
        }
    }

    // MARK: - Private handlers

    private func handleQueryChange(_ newQuery: String) {
        state.query = newQuery

        // Cancel any pending debounce immediately
        debounceTask?.cancel()

        let trimmed = newQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            state.results = []
            state.phase = .idle
            return
        }

        state.phase = .typing

        debounceTask = Task { [weak self] in
            guard let self else { return }

            // ★ The debounce window — cancelled if next keystroke arrives
            do {
                try await Task.sleep(for: self.debounceInterval)
            } catch {
                return  // cancelled by next keystroke
            }

            guard !Task.isCancelled else { return }
            await self.performSearch(query: trimmed)
        }
    }

    private func performSearch(query: String) async {
        state.phase = .searching
        do {
            let results = try await service.search(query: query)
            guard !Task.isCancelled else { return }
            state.results = results
            state.phase = results.isEmpty ? .empty : .loaded(count: results.count)
        } catch {
            guard !Task.isCancelled else { return }
            state.phase = .failed(error.localizedDescription)
        }
    }

    private func clearQuery() {
        debounceTask?.cancel()
        state = SearchState()  // reset to initial
    }
}
```

---

## Step 4 — Modular views (~10 min)

```swift
// SearchBarView.swift
import SwiftUI

struct SearchBarView: View {
    let query: String
    let onQueryChanged: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)

            TextField("Search…", text: Binding(
                get: { query },
                set: { onQueryChanged($0) }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            if !query.isEmpty {
                Button { onClear() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

// SearchPhaseView.swift
struct SearchPhaseView: View {
    let phase: SearchPhase

    var body: some View {
        HStack {
            phaseContent
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
        .animation(.default, value: phase)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .idle:
            Text("Start typing to search").font(.caption).foregroundStyle(.secondary)
        case .typing:
            Label("Typing…", systemImage: "pencil").font(.caption).foregroundStyle(.orange)
        case .searching:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.7)
                Text("Searching…")
            }.font(.caption).foregroundStyle(.blue)
        case .loaded(let count):
            Label("\(count) results", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
        case .empty:
            Label("No results", systemImage: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
        }
    }
}

// SearchResultsList.swift
struct SearchResultsList: View {
    let results: [SearchResult]
    let phase: SearchPhase
    let query: String
    let onSelect: (SearchResult) -> Void

    var body: some View {
        List(results) { result in
            SearchResultRow(result: result)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(result) }
        }
        .listStyle(.plain)
        .overlay { emptyOverlay }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        switch phase {
        case .idle:
            ContentUnavailableView("Search anything", systemImage: "magnifyingglass")
        case .empty:
            ContentUnavailableView.search(text: query)
        default:
            EmptyView()
        }
    }
}

struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.title).font(.headline)
            Text(result.category).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// LiveSearchView.swift — root view
struct LiveSearchView: View {
    @State private var vm = SearchViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchBarView(
                    query: vm.state.query,
                    onQueryChanged: { vm.send(.queryChanged($0)) },
                    onClear: { vm.send(.clearQuery) }
                )
                .padding(.vertical, 8)

                SearchPhaseView(phase: vm.state.phase)

                SearchResultsList(
                    results: vm.state.results,
                    phase: vm.state.phase,
                    query: vm.state.query,
                    onSelect: { vm.send(.selectResult($0)) }
                )
            }
            .navigationTitle("LiveSearch")
        }
    }
}
```

---

## Step 5 — Swift Testing suite (~10 min)

```swift
// SearchViewModelTests.swift
import Testing
@testable import LiveSearch

@Suite("SearchViewModel")
struct SearchViewModelTests {

    // MARK: - Helpers

    @MainActor
    private func makeVM(
        results: [SearchResult] = [],
        error: Error? = nil,
        debounceInterval: Duration = .zero  // ★ zero debounce = instant in tests
    ) async -> (SearchViewModel, MockSearchService) {
        let service = MockSearchService()
        await service.stub(results: results, error: error)
        let vm = SearchViewModel(service: service, debounceInterval: debounceInterval)
        return (vm, service)
    }

    // MARK: - Initial state

    @Test @MainActor
    func initialStateIsIdle() async {
        let (vm, _) = await makeVM()
        #expect(vm.state.phase == .idle)
        #expect(vm.state.query.isEmpty)
        #expect(vm.state.results.isEmpty)
    }

    // MARK: - Query change

    @Test @MainActor
    func emptyQueryResetsToIdle() async {
        let (vm, _) = await makeVM()
        vm.send(.queryChanged("swift"))
        vm.send(.clearQuery)
        #expect(vm.state.phase == .idle)
        #expect(vm.state.query.isEmpty)
    }

    @Test @MainActor
    func whitespaceOnlyQueryResetsToIdle() async {
        let (vm, _) = await makeVM()
        vm.send(.queryChanged("   "))
        #expect(vm.state.phase == .idle)
    }

    // MARK: - Debounce + search

    @Test @MainActor
    func searchLoadsResultsAfterDebounce() async throws {
        let results = [SearchResult(id: 1, title: "Swift", category: "Swift")]
        let (vm, _) = await makeVM(results: results, debounceInterval: .zero)

        vm.send(.queryChanged("swift"))
        // Give the async search task time to complete
        try await Task.sleep(for: .milliseconds(10))

        #expect(vm.state.phase == .loaded(count: 1))
        #expect(vm.state.results.count == 1)
    }

    @Test @MainActor
    func searchPhaseIsEmptyWhenNoMatches() async throws {
        let (vm, _) = await makeVM(results: [], debounceInterval: .zero)

        vm.send(.queryChanged("zzzzz"))
        try await Task.sleep(for: .milliseconds(10))

        #expect(vm.state.phase == .empty)
    }

    @Test @MainActor
    func searchPhaseIsFailedOnError() async throws {
        struct TestError: Error {}
        let (vm, _) = await makeVM(error: TestError(), debounceInterval: .zero)

        vm.send(.queryChanged("swift"))
        try await Task.sleep(for: .milliseconds(10))

        if case .failed = vm.state.phase { } else {
            Issue.record("Expected .failed phase")
        }
    }

    // MARK: - Debounce cancellation

    @Test @MainActor
    func rapidQueryChangesOnlySearchOnce() async throws {
        let results = [SearchResult(id: 1, title: "Swift", category: "Swift")]
        let (vm, service) = await makeVM(results: results, debounceInterval: .milliseconds(50))

        // Rapid fire — only the last should reach the service
        vm.send(.queryChanged("s"))
        vm.send(.queryChanged("sw"))
        vm.send(.queryChanged("swi"))
        vm.send(.queryChanged("swift"))

        try await Task.sleep(for: .milliseconds(100))

        let count = await service.callCount
        #expect(count == 1)  // only one network call despite 4 keystrokes
    }

    // MARK: - State struct

    @Test
    func searchStateEquality() {
        var a = SearchState()
        var b = SearchState()
        a.query = "swift"
        b.query = "swift"
        #expect(a == b)
    }
}

// MockSearchService with stub API
extension MockSearchService {
    func stub(results: [SearchResult], error: Error?) {
        self.stubbedResults = results
        self.stubbedError = error
    }
}
```

---

## Approach 2: AsyncStream-based reusable debouncer (staff-level extra)

```swift
// Debouncer.swift
// ★ Generic, reusable — shows understanding of custom async operators
final class Debouncer<Input: Sendable>: @unchecked Sendable {
    private let duration: Duration
    private let stream: AsyncStream<Input>
    private var continuation: AsyncStream<Input>.Continuation?

    init(duration: Duration) {
        self.duration = duration
        var cont: AsyncStream<Input>.Continuation?
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    func send(_ value: Input) { continuation?.yield(value) }

    // Returns a new AsyncStream that only emits after `duration` of silence
    func debounced() -> AsyncStream<Input> {
        AsyncStream { [stream, duration] outerCont in
            Task {
                var pending: Task<Void, Never>?
                for await value in stream {
                    pending?.cancel()
                    pending = Task {
                        try? await Task.sleep(for: duration)
                        if !Task.isCancelled { outerCont.yield(value) }
                    }
                }
            }
        }
    }

    deinit { continuation?.finish() }
}
```

---

## Key concepts to remember

**`debounceInterval: .zero` in tests:** Injecting a zero debounce lets tests run synchronously-ish — `Task.sleep(for: .zero)` still yields but completes in microseconds. No `XCTestExpectation` waits or arbitrary timeouts needed.

**Task cancellation is cooperative:** `Task.sleep` throws `CancellationError`. Your own loops need `try Task.checkCancellation()` to propagate it — `Task.isCancelled` is a non-throwing poll for the flag.

**`send(.clearQuery)` resets state struct:** Assigning `state = SearchState()` atomically resets all fields. No chance of partial reset leaving stale results visible.

---

## Follow-up questions

- *How does Combine `.debounce` differ from Task cancellation?* (Combine is declarative pipeline with backpressure; Task approach is imperative but simpler and has zero framework dependency in Swift 6)
- *What's throttle vs debounce?* (Debounce fires after silence; throttle fires at most once per window *while* input is ongoing)
- *How would you test a 300ms debounce without sleeping 300ms?* (Inject `debounceInterval: .zero`, or use a controllable `Clock` — the injectable `ClockServiceProtocol` pattern from Tutorial 01)
