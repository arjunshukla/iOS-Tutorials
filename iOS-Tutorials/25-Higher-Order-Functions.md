# Tutorial 25 — Higher-Order Functions in Swift
## Build: DataPipeline — a composable data-transformation layer
**Time:** 45 min | **Swift 6** | **Topics:** `map`, `flatMap`, `compactMap`, `filter`, `reduce`, `sorted`, `zip`, custom HOFs, function composition, `@escaping`, `Result` chaining

---

## What you'll build

A reusable `DataPipeline` that transforms a feed of raw API responses into clean, display-ready view models — using only higher-order functions. The pipeline is injected into a ViewModel, fully testable, and demonstrates every HOF you'll encounter in production.

```
RawProduct → filter(available) → compactMap(toProduct) → sorted(by price)
                                                              ↓
                                                     [Product] → map(toRowViewModel)
```

---

## Concept deep-dive

### What is a higher-order function?
A function that either:
- **takes** a function as an argument, or
- **returns** a function

```swift
// Takes a function — standard library HOF
let doubled = [1, 2, 3].map { $0 * 2 }   // [2, 4, 6]

// Returns a function — your own HOF
func multiplier(by factor: Int) -> (Int) -> Int {
    return { value in value * factor }
}
let triple = multiplier(by: 3)
triple(5)   // 15
```

---

### `map` — transform every element

```swift
// Signature: (T) -> U applied to each element
let names = ["alice", "bob", "carol"]
let uppercased = names.map { $0.capitalized }
// ["Alice", "Bob", "Carol"]

// Mapping to a different type
struct User { let id: Int; let name: String }
struct UserRow { let label: String }

let users = [User(id: 1, name: "Alice"), User(id: 2, name: "Bob")]
let rows = users.map { UserRow(label: "\($0.id): \($0.name)") }
```

**Interview insight**: `map` never changes collection length. Output count == input count.

---

### `compactMap` — transform and drop nils

```swift
// = map + filter(non-nil) in one pass
let raw = ["1", "two", "3", "four", "5"]
let ints = raw.compactMap { Int($0) }   // [1, 3, 5]

// Real-world: parsing optional API fields
struct RawProduct: Decodable {
    let id: String
    let price: String?   // sometimes missing in the API
}

struct Product: Identifiable, Sendable {
    let id: String
    let price: Double
}

let rawProducts: [RawProduct] = [
    RawProduct(id: "A", price: "9.99"),
    RawProduct(id: "B", price: nil),     // ← will be dropped
    RawProduct(id: "C", price: "4.49")
]
let products = rawProducts.compactMap { raw -> Product? in
    guard let priceStr = raw.price, let price = Double(priceStr) else { return nil }
    return Product(id: raw.id, price: price)
}
// count == 2 — "B" silently dropped
```

---

### `flatMap` — transform then flatten

```swift
// Transforms each element to a *sequence*, then flattens one level
let sentences = ["Hello world", "Swift is great"]
let words = sentences.flatMap { $0.split(separator: " ").map(String.init) }
// ["Hello", "world", "Swift", "is", "great"]

// Without flatMap:
let nested = sentences.map { $0.split(separator: " ").map(String.init) }
// [["Hello", "world"], ["Swift", "is", "great"]]  ← still nested
```

**When to use each:**

| Situation | Use |
|---|---|
| Always has a value | `map` |
| Might return nil | `compactMap` |
| Returns a collection | `flatMap` |

---

### `filter` — keep matching elements

```swift
let prices = [4.99, 12.50, 0.99, 7.25, 25.00]
let affordable = prices.filter { $0 < 10.0 }
// [4.99, 0.99, 7.25]

// Chain with map
let labels = prices
    .filter { $0 < 10.0 }
    .map { String(format: "$%.2f", $0) }
// ["$4.99", "$0.99", "$7.25"]
```

---

### `reduce` — collapse to a single value

```swift
// reduce(initialValue) { accumulated, current in ... }
let total = [4.99, 12.50, 0.99].reduce(0.0) { $0 + $1 }
// 18.48

// Shorthand when the operator matches the signature
let total2 = [4.99, 12.50, 0.99].reduce(0.0, +)

// Building a Dictionary — reduce(into:) avoids copy-on-write overhead
let inventory = ["apple": 3, "banana": 5, "cherry": 2]
let abundant = inventory.reduce(into: [String: Int]()) { result, pair in
    if pair.value > 2 { result[pair.key] = pair.value }
}
// ["apple": 3, "banana": 5]
```

**`reduce` vs `reduce(into:)`**: always prefer `reduce(into:)` when building collections — it mutates in place rather than making copies every iteration.

---

### `sorted` — order with a comparator

```swift
struct Product: Identifiable, Sendable {
    let id: String
    let name: String
    let price: Double
    let rating: Double
}

let products: [Product] = [...]

// Single key
let byPrice = products.sorted { $0.price < $1.price }

// Multiple keys (price ascending, then name)
let byPriceThenName = products.sorted {
    $0.price != $1.price ? $0.price < $1.price : $0.name < $1.name
}

// Using KeyPath — cleaner at call site
let byRating = products.sorted(using: KeyPathComparator(\.rating, order: .reverse))
```

---

### `zip` — pair two sequences

```swift
let ids = ["A", "B", "C"]
let prices = [9.99, 4.49, 14.99]

let pairs = zip(ids, prices).map { Product(id: $0, name: $0, price: $1, rating: 0) }
// Stops at the shorter sequence — safe with mismatched lengths
```

---

### Function composition — build pipelines

```swift
// Composing transforms as values
typealias Transform<T> = ([T]) -> [T]

func filtering<T>(_ predicate: @escaping (T) -> Bool) -> Transform<T> {
    { $0.filter(predicate) }
}

func mapping<T, U>(_ transform: @escaping (T) -> U) -> ([T]) -> [U] {
    { $0.map(transform) }
}

// Compose with a custom operator
infix operator >>>: AdditionPrecedence
func >>> <A, B, C>(f: @escaping (A) -> B, g: @escaping (B) -> C) -> (A) -> C {
    { g(f($0)) }
}

// Usage:
let pipeline = filtering { (p: Product) in p.price < 10 }
    >>> mapping { ProductRowViewModel(product: $0) }

let rows = pipeline(products)
```

---

### `@escaping` closures

```swift
// A closure "escapes" when it outlives the function call
// (stored, passed to async work, retained by a property)

class SearchViewModel {
    private var onResult: ((String) -> Void)?   // stored = escaping

    // @escaping required — closure outlives the function
    func onSearchComplete(_ handler: @escaping (String) -> Void) {
        self.onResult = handler
    }
}

// Non-escaping (default): closure is only called DURING the function
func transform(_ items: [Int], using block: (Int) -> Int) -> [Int] {
    items.map(block)   // block does not outlive transform()
}
```

---

## Production example — DataPipeline

### Models

```swift
// Models.swift
import Foundation

struct RawProduct: Decodable, Sendable {
    let id: String
    let name: String
    let price: String?          // raw from API — may be malformed
    let rating: Double
    let isAvailable: Bool
    let categoryIDs: [String]
}

struct Product: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let price: Double
    let rating: Double
    let categoryIDs: [String]
}

struct ProductRowViewModel: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let priceLabel: String
    let ratingLabel: String
}
```

---

### DataPipeline

```swift
// DataPipeline.swift
import Foundation

// Protocol makes it mockable in tests
protocol DataPipelineProtocol: Sendable {
    func process(_ raw: [RawProduct]) -> [ProductRowViewModel]
    func categories(from raw: [RawProduct]) -> [String]
    func priceRange(of raw: [RawProduct]) -> ClosedRange<Double>?
}

struct DataPipeline: DataPipelineProtocol {

    // MARK: - Public API

    func process(_ raw: [RawProduct]) -> [ProductRowViewModel] {
        raw
            .filter(\.isAvailable)                        // 1. keep available only
            .compactMap(toProduct)                        // 2. parse & drop malformed
            .sorted { $0.rating > $1.rating }            // 3. highest rated first
            .map(toRowViewModel)                          // 4. map to display type
    }

    func categories(from raw: [RawProduct]) -> [String] {
        let allIDs = raw.flatMap(\.categoryIDs)          // flatten nested arrays
        return Array(Set(allIDs)).sorted()               // deduplicate + sort
    }

    func priceRange(of raw: [RawProduct]) -> ClosedRange<Double>? {
        let prices = raw.compactMap { $0.price.flatMap(Double.init) }
        guard let min = prices.min(), let max = prices.max() else { return nil }
        return min...max
    }

    // MARK: - Private transforms (named functions = easier to test in isolation)

    private func toProduct(_ raw: RawProduct) -> Product? {
        guard let priceStr = raw.price, let price = Double(priceStr) else { return nil }
        return Product(
            id: raw.id,
            name: raw.name,
            price: price,
            rating: raw.rating,
            categoryIDs: raw.categoryIDs
        )
    }

    private func toRowViewModel(_ product: Product) -> ProductRowViewModel {
        ProductRowViewModel(
            id: product.id,
            title: product.name,
            priceLabel: String(format: "$%.2f", product.price),
            ratingLabel: String(format: "%.1f ★", product.rating)
        )
    }
}
```

---

### ViewModel

```swift
// ProductFeedViewModel.swift
import Foundation

// MARK: - Action / State

enum ProductFeedAction: Sendable {
    case load
    case filterByCategory(String?)
    case sortByPrice
    case sortByRating
}

struct ProductFeedState: Equatable {
    enum Status: Equatable {
        case idle, loading, loaded, failed(String)
    }
    var status: Status = .idle
    var rows: [ProductRowViewModel] = []
    var categories: [String] = []
    var priceRange: ClosedRange<Double>? = nil
    var activeCategory: String? = nil
}

// MARK: - Protocol

@MainActor
protocol ProductFeedViewModelProtocol: AnyObject, Observable {
    var state: ProductFeedState { get }
    func send(_ action: ProductFeedAction)
}

// MARK: - ViewModel

@MainActor
@Observable
final class ProductFeedViewModel: ProductFeedViewModelProtocol {

    private(set) var state = ProductFeedState()

    private let service: any ProductServiceProtocol
    private let pipeline: any DataPipelineProtocol
    private var allRaw: [RawProduct] = []

    init(service: any ProductServiceProtocol, pipeline: any DataPipelineProtocol = DataPipeline()) {
        self.service = service
        self.pipeline = pipeline
    }

    func send(_ action: ProductFeedAction) {
        switch action {
        case .load:            Task { await load() }
        case .filterByCategory(let id): applyFilter(category: id)
        case .sortByPrice:     applySort(byPrice: true)
        case .sortByRating:    applySort(byPrice: false)
        }
    }

    // MARK: - Private

    private func load() async {
        state.status = .loading
        do {
            allRaw = try await service.fetchProducts()
            state.categories = pipeline.categories(from: allRaw)
            state.priceRange  = pipeline.priceRange(of: allRaw)
            state.rows        = pipeline.process(allRaw)
            state.status      = .loaded
        } catch {
            state.status = .failed(error.localizedDescription)
        }
    }

    private func applyFilter(category: String?) {
        state.activeCategory = category
        let subset = category.map { cat in allRaw.filter { $0.categoryIDs.contains(cat) } }
            ?? allRaw
        state.rows = pipeline.process(subset)
    }

    private func applySort(byPrice: Bool) {
        state.rows = byPrice
            ? state.rows.sorted { lhs, rhs in
                  // extract Double from "$9.99" → 9.99 for comparison
                  let l = Double(lhs.priceLabel.dropFirst()) ?? 0
                  let r = Double(rhs.priceLabel.dropFirst()) ?? 0
                  return l < r
              }
            : state.rows.sorted { $0.ratingLabel > $1.ratingLabel }
    }
}
```

---

### Service protocol

```swift
// ProductServiceProtocol.swift
import Foundation

protocol ProductServiceProtocol: Sendable {
    func fetchProducts() async throws -> [RawProduct]
}

struct MockProductService: ProductServiceProtocol {
    let products: [RawProduct]
    var shouldFail = false

    func fetchProducts() async throws -> [RawProduct] {
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return products
    }
}
```

---

### Views

```swift
// ProductFeedView.swift
import SwiftUI

struct ProductFeedView: View {
    @State private var vm: any ProductFeedViewModelProtocol

    init(vm: any ProductFeedViewModelProtocol) { self._vm = State(initialValue: vm) }

    var body: some View {
        NavigationStack {
            Group {
                switch vm.state.status {
                case .idle:             Color.clear
                case .loading:          ProgressView("Loading…")
                case .loaded:           feedContent
                case .failed(let msg):  ErrorView(message: msg)
                }
            }
            .navigationTitle("Products")
            .toolbar { sortMenu }
            .task { vm.send(.load) }
        }
    }

    private var feedContent: some View {
        VStack(spacing: 0) {
            CategoryFilterBar(
                categories: vm.state.categories,
                active: vm.state.activeCategory,
                onSelect: { vm.send(.filterByCategory($0)) }
            )
            ProductRowList(rows: vm.state.rows)
        }
    }

    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu("Sort") {
                Button("Price ↑") { vm.send(.sortByPrice) }
                Button("Rating ↓") { vm.send(.sortByRating) }
            }
        }
    }
}

// MARK: - Subviews

struct CategoryFilterBar: View {
    let categories: [String]
    let active: String?
    let onSelect: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                FilterChip(label: "All", isActive: active == nil) { onSelect(nil) }
                ForEach(categories, id: \.self) { cat in
                    FilterChip(label: cat, isActive: active == cat) { onSelect(cat) }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
}

struct FilterChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? Color.accentColor : Color(.systemGray5), in: Capsule())
                .foregroundStyle(isActive ? .white : .primary)
        }
    }
}

struct ProductRowList: View {
    let rows: [ProductRowViewModel]

    var body: some View {
        List(rows) { row in
            ProductRow(row: row)
        }
        .listStyle(.plain)
    }
}

struct ProductRow: View {
    let row: ProductRowViewModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.headline)
                Text(row.ratingLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.priceLabel).font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, 4)
    }
}

struct ErrorView: View {
    let message: String
    var body: some View {
        ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(message))
    }
}
```

---

## Tests

```swift
// DataPipelineTests.swift
import Testing
@testable import DataPipeline   // replace with your module name

// MARK: - Fixtures

private let available = RawProduct(
    id: "A", name: "Widget", price: "9.99", rating: 4.5, isAvailable: true, categoryIDs: ["tools"]
)
private let unavailable = RawProduct(
    id: "B", name: "Gadget", price: "4.99", rating: 3.0, isAvailable: false, categoryIDs: ["tools"]
)
private let malformedPrice = RawProduct(
    id: "C", name: "Thingamajig", price: "N/A", rating: 5.0, isAvailable: true, categoryIDs: ["misc"]
)
private let noPrice = RawProduct(
    id: "D", name: "Doohickey", price: nil, rating: 4.0, isAvailable: true, categoryIDs: ["misc"]
)
private let highRated = RawProduct(
    id: "E", name: "Pro Widget", price: "19.99", rating: 4.9, isAvailable: true, categoryIDs: ["tools", "pro"]
)

@Suite("DataPipeline")
struct DataPipelineTests {

    let pipeline = DataPipeline()

    // MARK: - filter (isAvailable)

    @Test func unavailableProductsAreExcluded() {
        let result = pipeline.process([available, unavailable])
        #expect(!result.contains { $0.id == unavailable.id })
    }

    @Test func availableProductsAreIncluded() {
        let result = pipeline.process([available])
        #expect(result.count == 1)
        #expect(result[0].id == available.id)
    }

    // MARK: - compactMap (price parsing)

    @Test func malformedPriceIsDropped() {
        let result = pipeline.process([malformedPrice])
        #expect(result.isEmpty)
    }

    @Test func nilPriceIsDropped() {
        let result = pipeline.process([noPrice])
        #expect(result.isEmpty)
    }

    @Test func validPriceIsFormatted() {
        let result = pipeline.process([available])
        #expect(result[0].priceLabel == "$9.99")
    }

    // MARK: - sorted (rating descending)

    @Test func outputIsSortedByRatingDescending() {
        let result = pipeline.process([available, highRated])
        #expect(result[0].id == highRated.id)   // 4.9 > 4.5
        #expect(result[1].id == available.id)
    }

    @Test func emptyInputProducesEmptyOutput() {
        let result = pipeline.process([])
        #expect(result.isEmpty)
    }

    // MARK: - map (toRowViewModel)

    @Test func ratingLabelIncludesStar() {
        let result = pipeline.process([available])
        #expect(result[0].ratingLabel.contains("★"))
    }

    @Test func titleMatchesProductName() {
        let result = pipeline.process([available])
        #expect(result[0].title == available.name)
    }

    // MARK: - categories (flatMap + dedup + sort)

    @Test func categoriesAreDeduplicated() {
        // "tools" appears in both available and highRated
        let cats = pipeline.categories(from: [available, highRated])
        #expect(cats.filter { $0 == "tools" }.count == 1)
    }

    @Test func categoriesIncludeAllUniqueIDs() {
        let cats = pipeline.categories(from: [available, highRated])
        #expect(cats.contains("pro"))
        #expect(cats.contains("tools"))
    }

    @Test func categoriesAreSorted() {
        let cats = pipeline.categories(from: [available, highRated])
        #expect(cats == cats.sorted())
    }

    @Test func categoriesFromEmptyInputAreEmpty() {
        #expect(pipeline.categories(from: []).isEmpty)
    }

    // MARK: - priceRange (reduce-like min/max)

    @Test func priceRangeCoversMinAndMax() {
        let range = pipeline.priceRange(of: [available, highRated])
        #expect(range?.lowerBound == 9.99)
        #expect(range?.upperBound == 19.99)
    }

    @Test func priceRangeNilWhenNoParsablePrice() {
        let range = pipeline.priceRange(of: [malformedPrice, noPrice])
        #expect(range == nil)
    }

    @Test func priceRangeNilForEmptyInput() {
        #expect(pipeline.priceRange(of: []) == nil)
    }
}

// MARK: - ViewModel tests

@Suite("ProductFeedViewModel")
@MainActor
struct ProductFeedViewModelTests {

    func makeVM(products: [RawProduct] = [available, highRated], fail: Bool = false)
        -> ProductFeedViewModel
    {
        ProductFeedViewModel(
            service: MockProductService(products: products, shouldFail: fail),
            pipeline: DataPipeline()
        )
    }

    @Test func initialStateIsIdle() {
        let vm = makeVM()
        #expect(vm.state.status == .idle)
        #expect(vm.state.rows.isEmpty)
    }

    @Test func loadTransitionsToLoaded() async {
        let vm = makeVM()
        vm.send(.load)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.state.status == .loaded)
    }

    @Test func loadPopulatesRows() async {
        let vm = makeVM()
        vm.send(.load)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!vm.state.rows.isEmpty)
    }

    @Test func loadPopulatesCategories() async {
        let vm = makeVM()
        vm.send(.load)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!vm.state.categories.isEmpty)
    }

    @Test func loadFailureSetsFailedStatus() async {
        let vm = makeVM(fail: true)
        vm.send(.load)
        try? await Task.sleep(for: .milliseconds(50))
        if case .failed = vm.state.status { } else {
            Issue.record("Expected .failed, got \(vm.state.status)")
        }
    }

    @Test func filterByCategoryNarrowsRows() async {
        let vm = makeVM()
        vm.send(.load)
        try? await Task.sleep(for: .milliseconds(50))
        let totalCount = vm.state.rows.count
        vm.send(.filterByCategory("pro"))
        #expect(vm.state.rows.count < totalCount)
    }

    @Test func filterByNilRestoresAllRows() async {
        let vm = makeVM()
        vm.send(.load)
        try? await Task.sleep(for: .milliseconds(50))
        let totalCount = vm.state.rows.count
        vm.send(.filterByCategory("pro"))
        vm.send(.filterByCategory(nil))
        #expect(vm.state.rows.count == totalCount)
    }

    @Test func sortByPriceOrdersRowsAscending() async {
        let vm = makeVM()
        vm.send(.load)
        try? await Task.sleep(for: .milliseconds(50))
        vm.send(.sortByPrice)
        let prices = vm.state.rows.compactMap { Double($0.priceLabel.dropFirst()) }
        #expect(prices == prices.sorted())
    }
}
```

---

## Cheat sheet

| HOF | Input → Output | Key use case |
|---|---|---|
| `map` | `[T]` → `[U]` | Transform every element (same count) |
| `compactMap` | `[T]` → `[U]` | Transform + drop nils |
| `flatMap` | `[T]` → `[U]` | Transform to sequence, then flatten |
| `filter` | `[T]` → `[T]` | Keep matching elements |
| `reduce` | `[T]` → `U` | Collapse to single value |
| `reduce(into:)` | `[T]` → `U` | Same but mutable accumulator — prefer for collections |
| `sorted` | `[T]` → `[T]` | Order by comparator or KeyPath |
| `zip` | `[A]`, `[B]` → `[(A,B)]` | Pair two sequences |
| `forEach` | `[T]` → `Void` | Side effects only — prefer regular `for in` |

### When NOT to chain HOFs
```swift
// Readable — two passes but clear intent
let available = products.filter { $0.isAvailable }
let names = available.map(\.name)

// Clever but hard to debug — avoid for more than 3 stages
let names = products.filter(\.isAvailable).map(\.name)

// For large collections: prefer a single compactMap over filter + map
let names = products.compactMap { $0.isAvailable ? $0.name : nil }
```

### `lazy` — defer work until consumed

```swift
// Without lazy: all three passes run on the full array upfront
let result = products.filter { ... }.map { ... }.first

// With lazy: stops as soon as first matching element is found
let result = products.lazy.filter { ... }.map { ... }.first
```

---

## Interview questions this covers

| Question | Concept |
|---|---|
| "What's the difference between `map`, `flatMap`, and `compactMap`?" | All three |
| "How would you transform an API response into display models?" | `compactMap` → `sorted` → `map` pipeline |
| "Explain `@escaping`" | Closure lifetime |
| "How do you write a testable data transformation?" | Protocol-backed `DataPipelineProtocol` |
| "What is a higher-order function?" | Function taking/returning functions |
| "When would you use `reduce(into:)` over `reduce`?" | CoW performance on collections |
| "How do you compose functions in Swift?" | `>>>` operator or nested closures |
