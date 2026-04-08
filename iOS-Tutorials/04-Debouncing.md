# Tutorial 04 — Debouncing
## Build: LiveSearch — a real-time search with smart request throttling
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** Debounce, Combine, `Task` cancellation, `AsyncStream`

---

## What you'll build
A search bar that:
- Waits 300ms after the user stops typing before fetching
- Cancels in-flight requests when a new query arrives
- Shows "typing…" → "searching…" → results states
- Implemented TWO ways: Combine and plain `async/await`

---

## What debouncing solves

Without debouncing, typing "swift" fires 5 network requests:
`s` → `sw` → `swi` → `swif` → `swift`

With debouncing (300ms threshold):
Only `swift` fires — after the user pauses.

---

## Approach 1: Combine (classic iOS pattern)

```swift
// SearchViewModel+Combine.swift
import Combine
import Observation

@MainActor
@Observable
final class CombineSearchViewModel {

    var query: String = "" {
        didSet { querySubject.send(query) }
    }
    var results: [String] = []
    var phase: SearchPhase = .idle

    private let querySubject = PassthroughSubject<String, Never>()
    private var cancellables = Set<AnyCancellable>()

    enum SearchPhase: Equatable {
        case idle, typing, searching, results(Int), empty, error(String)
    }

    init() {
        querySubject
            .handleEvents(receiveOutput: { [weak self] _ in
                self?.phase = .typing
            })
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .filter { !$0.isEmpty }
            .flatMap { [weak self] query -> AnyPublisher<[String], Never> in
                guard let self else { return Just([]).eraseToAnyPublisher() }
                self.phase = .searching
                return self.search(query: query)
                    .catch { _ in Just([]) }
                    .eraseToAnyPublisher()
            }
            .receive(on: RunLoop.main)
            .sink { [weak self] results in
                guard let self else { return }
                self.results = results
                self.phase = results.isEmpty ? .empty : .results(results.count)
            }
            .store(in: &cancellables)
    }

    private func search(query: String) -> AnyPublisher<[String], Error> {
        // Simulated API — replace with URLSession.dataTaskPublisher
        Future { promise in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                let results = ["swift", "swiftui", "swift concurrency", "swift generics"]
                    .filter { $0.contains(query.lowercased()) }
                promise(.success(results))
            }
        }
        .eraseToAnyPublisher()
    }
}
```

---

## Approach 2: Modern async/await with Task cancellation (preferred in Swift 6)

```swift
// SearchViewModel.swift
import Foundation
import Observation

@MainActor
@Observable
final class SearchViewModel {

    var query: String = ""
    var results: [SearchResult] = []
    var phase: SearchPhase = .idle

    enum SearchPhase: Equatable {
        case idle, typing, searching, loaded, empty, failed(String)
    }

    private var debounceTask: Task<Void, Never>?

    // Called on every keystroke from the view
    func queryChanged(_ newQuery: String) {
        query = newQuery

        // Cancel any pending debounce
        debounceTask?.cancel()

        guard !newQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            phase = .idle
            return
        }

        phase = .typing

        debounceTask = Task {
            // ★ The debounce: wait 300ms, check for cancellation
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return  // cancelled by next keystroke
            }

            guard !Task.isCancelled else { return }

            phase = .searching

            do {
                let fetched = try await performSearch(newQuery)
                guard !Task.isCancelled else { return }
                results = fetched
                phase = fetched.isEmpty ? .empty : .loaded
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func performSearch(_ query: String) async throws -> [SearchResult] {
        // Simulate a real API call
        try await Task.sleep(for: .milliseconds(400))

        let corpus = [
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

struct SearchResult: Identifiable, Sendable {
    let id: Int
    let title: String
    let category: String
}
```

---

## Approach 3: AsyncStream debouncer (reusable utility)

```swift
// Debouncer.swift
import Foundation

// Reusable generic debouncer using AsyncStream
// ★ Staff-level: shows understanding of async streams + custom operators
final class Debouncer<Input: Sendable>: @unchecked Sendable {

    private let duration: Duration
    private var continuation: AsyncStream<Input>.Continuation?
    private let stream: AsyncStream<Input>

    init(duration: Duration) {
        self.duration = duration
        var cont: AsyncStream<Input>.Continuation?
        self.stream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func send(_ value: Input) {
        continuation?.yield(value)
    }

    // Returns debounced values
    func debounced() -> AsyncStream<Input> {
        AsyncStream { [weak self] outerCont in
            guard let self else { return }
            Task {
                var pendingTask: Task<Void, Never>?
                for await value in self.stream {
                    pendingTask?.cancel()
                    let d = self.duration
                    pendingTask = Task {
                        do {
                            try await Task.sleep(for: d)
                            outerCont.yield(value)
                        } catch { }
                    }
                }
            }
        }
    }
}

// Usage:
// let debouncer = Debouncer<String>(duration: .milliseconds(300))
// Task {
//     for await query in debouncer.debounced() {
//         // Only fires after 300ms pause
//         await search(query)
//     }
// }
// debouncer.send(textFieldValue)
```

---

## Step — SwiftUI view (~15 min)

```swift
// ContentView.swift
import SwiftUI

struct ContentView: View {
    @State private var vm = SearchViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // Search bar (iOS 17+)
                TextField("Search…", text: Binding(
                    get: { vm.query },
                    set: { vm.queryChanged($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .padding()
                .autocorrectionDisabled()

                // Phase indicator
                phaseRow

                // Results
                List(vm.results) { result in
                    VStack(alignment: .leading) {
                        Text(result.title).font(.headline)
                        Text(result.category)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if vm.results.isEmpty {
                        emptyOverlay
                    }
                }
            }
            .navigationTitle("LiveSearch")
            .animation(.default, value: vm.phase)
        }
    }

    @ViewBuilder
    private var phaseRow: some View {
        HStack {
            switch vm.phase {
            case .idle:
                Text("Start typing to search")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .typing:
                Label("Typing…", systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .searching:
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.7)
                    Text("Searching…")
                }
                .font(.caption)
                .foregroundStyle(.blue)
            case .loaded:
                Label("\(vm.results.count) results", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .empty:
                Label("No results", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let msg):
                Label(msg, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        switch vm.phase {
        case .idle:
            ContentUnavailableView("Search anything", systemImage: "magnifyingglass")
        case .empty:
            ContentUnavailableView.search(text: vm.query)
        default:
            EmptyView()
        }
    }
}
```

---

## ★ Challenge

1. Add **throttling** (different from debouncing):
   - Debounce: fires after user STOPS typing
   - Throttle: fires at most once per interval WHILE typing
   
```swift
// Throttle: cancel if last fire was < 500ms ago
func throttled(interval: Duration) -> some AsyncSequence { ... }
```

2. Add **search history** — save last 5 searches in `UserDefaults`, show as suggestions when the field is empty.

---

## Key concepts to remember

**Debounce vs Throttle:**
- Debounce → delay and collapse, emit after silence
- Throttle → emit at most once per window

**Task cancellation is cooperative:** `Task.sleep` throws `CancellationError` when cancelled. Your own async functions must `try Task.checkCancellation()` explicitly to propagate it.

**`flatMap` in Combine:** Cancels the inner publisher when a new value arrives — this is how `switchToLatest` works. The equivalent in async/await is cancelling the previous `Task`.

---

## Follow-up questions

- *How does Combine's `.debounce` differ from your `Task`-based approach?* (Combine is declarative pipeline; Task approach is simpler and works without Combine dependency)
- *What's the difference between debounce and `removeDuplicates`?* (removeDuplicates filters same consecutive values; debounce filters by time)
- *How would you test debouncing logic?* (Inject a controllable clock; in Combine use `TestScheduler`)
