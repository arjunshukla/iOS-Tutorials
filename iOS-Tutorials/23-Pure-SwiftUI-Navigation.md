# Tutorial 23 — Pure SwiftUI Navigation
## Build: ShopKit — browse → product → cart flow
**Time:** 45 min | **Swift 6 + SwiftUI** | **Topics:** NavigationStack, Environment Router, `send(_:)` dispatch, sheet coordination, Swift Testing

---

## Philosophy: No Coordinator Object

Pure SwiftUI navigation uses:
- `NavigationStack` + typed `NavigationPath` for push navigation
- `@Observable` Router in `@Environment` — accessible anywhere in the view tree
- `sheet(item:)` / `fullScreenCover(item:)` for modal flows
- VMs use `send(_:)` for all state changes; navigation stays in the Router

---

## Architecture

```
ShopKitApp
└── RootView                ← declares all navigationDestination, sheets
    ├── CategoryListView    ← calls router.send(.push(.productList))
    ├── ProductListView     ← calls router.send(.push(.productDetail))
    ├── ProductDetailView   ← calls router.send(.presentCart)
    └── CartView            ← presented as fullScreenCover

Router                      ← @Observable, in @Environment
CartStore                   ← @Observable, in @Environment, shared state
```

---

## Step 1 — Router with `send(_:)` (~5 min)

```swift
// Router.swift
import SwiftUI

// ★ Push routes — all Hashable for NavigationPath
enum Route: Hashable, Sendable {
    case productList(category: String)
    case productDetail(id: UUID)
    case checkout
}

// ★ Modal routes — separate from push routes
enum SheetRoute: Identifiable, Sendable {
    case filter
    case review(productID: UUID)

    var id: String {
        switch self {
        case .filter:           return "filter"
        case .review(let id):   return "review-\(id)"
        }
    }
}

// ★ Router also uses send(_:) — consistent with all ViewModels
enum RouterAction: Sendable {
    case push(Route)
    case pop
    case popToRoot
    case presentSheet(SheetRoute)
    case dismissSheet
    case presentCart
    case dismissCart
    case handleDeepLink(URL)
}

@MainActor
@Observable
final class Router {
    var path             = NavigationPath()
    var sheet: SheetRoute? = nil
    var isCartPresented  = false

    func send(_ action: RouterAction) {
        switch action {
        case .push(let route):        path.append(route)
        case .pop:                    pop()
        case .popToRoot:              path = NavigationPath()
        case .presentSheet(let s):    sheet = s
        case .dismissSheet:           sheet = nil
        case .presentCart:            isCartPresented = true
        case .dismissCart:            isCartPresented = false
        case .handleDeepLink(let url): handleDeepLink(url)
        }
    }

    private func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "shopkit", let host = url.host else { return }
        switch host {
        case "product":
            if let idStr = url.pathComponents.dropFirst().first,
               let id = UUID(uuidString: idStr) {
                send(.popToRoot)
                send(.push(.productDetail(id: id)))
            }
        case "cart":
            send(.presentCart)
        default:
            break
        }
    }
}
```

---

## Step 2 — Models + shared store (~5 min)

```swift
// Product.swift
import Foundation

struct Product: Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
    let price: Decimal
    let category: String

    static let samples: [Product] = [
        Product(id: UUID(), name: "iPhone Case",     price: 29.99,  category: "Accessories"),
        Product(id: UUID(), name: "Lightning Cable", price: 19.99,  category: "Accessories"),
        Product(id: UUID(), name: "AirPods Pro",     price: 249.99, category: "Audio"),
        Product(id: UUID(), name: "HomePod Mini",    price: 99.99,  category: "Audio"),
        Product(id: UUID(), name: "Magic Keyboard",  price: 129.99, category: "Peripherals"),
    ]

    static func find(id: UUID) -> Product? { samples.first { $0.id == id } }
}

// CartStore.swift — shared state, injected via @Environment
// ★ CartStore also uses send(_:) — consistent dispatch pattern throughout
enum CartAction: Sendable {
    case addProduct(Product)
    case removeAt(IndexSet)
    case clear
}

struct CartState: Equatable {
    var items: [Product] = []
    var total: Decimal { items.reduce(0) { $0 + $1.price } }
    var count: Int       { items.count }
    var isEmpty: Bool    { items.isEmpty }
}

@MainActor
@Observable
final class CartStore {
    private(set) var state = CartState()

    func send(_ action: CartAction) {
        switch action {
        case .addProduct(let p): state.items.append(p)
        case .removeAt(let i):   state.items.remove(atOffsets: i)
        case .clear:             state.items.removeAll()
        }
    }
}
```

---

## Step 3 — ViewModels with `send(_:)` (~10 min)

```swift
// ProductCatalogService.swift
protocol ProductCatalogServiceProtocol: Sendable {
    func fetchProducts(category: String) async throws -> [Product]
}

struct ProductCatalogService: ProductCatalogServiceProtocol {
    func fetchProducts(category: String) async throws -> [Product] {
        try await Task.sleep(for: .milliseconds(300))
        return Product.samples.filter { $0.category == category }
    }
}

struct MockProductCatalogService: ProductCatalogServiceProtocol {
    let stubbedProducts: [Product]
    var stubbedError: Error? = nil

    func fetchProducts(category: String) async throws -> [Product] {
        if let error = stubbedError { throw error }
        return stubbedProducts
    }
}

// ProductListViewModel.swift
enum ProductListAction: Sendable {
    case load
    case selectProduct(Product)
    case tapFilter
}

struct ProductListState: Equatable {
    enum Phase: Equatable {
        case loading
        case loaded([Product])
        case empty
        case error(String)
    }
    var phase: Phase = .loading
    let category: String
}

@MainActor
@Observable
final class ProductListViewModel {

    private(set) var state: ProductListState
    var onRouterAction: ((RouterAction) -> Void)?
    private let service: any ProductCatalogServiceProtocol

    init(category: String, service: any ProductCatalogServiceProtocol = ProductCatalogService()) {
        self.state = ProductListState(phase: .loading, category: category)
        self.service = service
    }

    func send(_ action: ProductListAction) {
        switch action {
        case .load:                    Task { await load() }
        case .selectProduct(let p):    onRouterAction?(.push(.productDetail(id: p.id)))
        case .tapFilter:               onRouterAction?(.presentSheet(.filter))
        }
    }

    private func load() async {
        state.phase = .loading
        do {
            let products = try await service.fetchProducts(category: state.category)
            state.phase = products.isEmpty ? .empty : .loaded(products)
        } catch {
            state.phase = .error(error.localizedDescription)
        }
    }
}

// ProductDetailViewModel.swift
enum ProductDetailAction: Sendable {
    case load(id: UUID)
    case addToCart
    case writeReview
}

struct ProductDetailState: Equatable {
    enum Phase: Equatable {
        case loading
        case loaded(Product)
        case notFound
    }
    var phase: Phase     = .loading
    var addedToCart: Bool = false
}

@MainActor
@Observable
final class ProductDetailViewModel {

    private(set) var state = ProductDetailState()
    var onRouterAction: ((RouterAction) -> Void)?
    private let cart: CartStore

    init(cart: CartStore) {
        self.cart = cart
    }

    func send(_ action: ProductDetailAction) {
        switch action {
        case .load(let id):
            Task { await load(id: id) }
        case .addToCart:
            if case .loaded(let product) = state.phase {
                cart.send(.addProduct(product))
                state.addedToCart = true
            }
        case .writeReview:
            if case .loaded(let product) = state.phase {
                onRouterAction?(.presentSheet(.review(productID: product.id)))
            }
        }
    }

    private func load(id: UUID) async {
        state.phase = .loading
        try? await Task.sleep(for: .milliseconds(100))
        state.phase = Product.find(id: id).map { .loaded($0) } ?? .notFound
    }
}
```

---

## Step 4 — Modular views (~10 min)

```swift
// CartBadgeButton.swift
import SwiftUI

struct CartBadgeButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "cart")
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.red, in: Circle())
                            .offset(x: 8, y: -8)
                    }
                }
        }
    }
}

// CategoryListView.swift
struct CategoryListView: View {
    @Environment(Router.self) private var router
    let categories = ["Accessories", "Audio", "Peripherals"]

    var body: some View {
        List(categories, id: \.self) { category in
            Button {
                router.send(.push(.productList(category: category)))
            } label: {
                HStack {
                    Label(category, systemImage: "folder")
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }
            .tint(.primary)
        }
        .navigationTitle("Shop")
    }
}

// ProductListContentView.swift — pure display, no routing knowledge
struct ProductListContentView: View {
    let phase: ProductListState.Phase
    let onSelect: (Product) -> Void

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
            case .empty:
                ContentUnavailableView("No Products", systemImage: "bag")
            case .error(let msg):
                ContentUnavailableView(msg, systemImage: "wifi.slash")
            case .loaded(let products):
                List(products) { product in
                    ProductRowView(product: product, onSelect: { onSelect(product) })
                }
            }
        }
    }
}

struct ProductRowView: View {
    let product: Product
    let onSelect: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name).font(.headline)
                Text(product.price, format: .currency(code: "USD"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .padding(.vertical, 4)
    }
}

// ProductListView.swift
struct ProductListView: View {
    @State var vm: ProductListViewModel
    @Environment(Router.self) private var router

    var body: some View {
        ProductListContentView(
            phase: vm.state.phase,
            onSelect: { vm.send(.selectProduct($0)) }
        )
        .navigationTitle(vm.state.category)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Filter") { vm.send(.tapFilter) }
            }
        }
        .task { vm.send(.load) }
        .onAppear {
            // Wire router actions — only once
            vm.onRouterAction = { router.send($0) }
        }
    }
}

// ProductDetailHeroView.swift
struct ProductDetailHeroView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.gray.opacity(0.2))
            .frame(maxWidth: .infinity).frame(height: 200)
    }
}

// ProductDetailActionsView.swift
struct ProductDetailActionsView: View {
    let addedToCart: Bool
    let onAddToCart: () -> Void
    let onWriteReview: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button {
                onAddToCart()
            } label: {
                Label(
                    addedToCart ? "Added to Cart!" : "Add to Cart",
                    systemImage: addedToCart ? "checkmark.circle.fill" : "cart.badge.plus"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(addedToCart)

            Button("Write a Review", action: onWriteReview)
                .buttonStyle(.bordered)
        }
        .padding()
    }
}

// ProductDetailView.swift
struct ProductDetailView: View {
    @State var vm: ProductDetailViewModel
    let productID: UUID
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            switch vm.state.phase {
            case .loading:
                ProgressView()
            case .notFound:
                ContentUnavailableView("Product not found", systemImage: "questionmark")
            case .loaded(let product):
                loadedView(product)
            }
        }
        .task { vm.send(.load(id: productID)) }
        .onAppear { vm.onRouterAction = { router.send($0) } }
    }

    private func loadedView(_ product: Product) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProductDetailHeroView()

                VStack(alignment: .leading, spacing: 8) {
                    Text(product.name).font(.title2.bold())
                    Text(product.price, format: .currency(code: "USD"))
                        .font(.title3).foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                ProductDetailActionsView(
                    addedToCart: vm.state.addedToCart,
                    onAddToCart: { vm.send(.addToCart) },
                    onWriteReview: { vm.send(.writeReview) }
                )
            }
        }
        .navigationTitle(product.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// CartItemRow.swift
struct CartItemRow: View {
    let product: Product

    var body: some View {
        HStack {
            Text(product.name)
            Spacer()
            Text(product.price, format: .currency(code: "USD")).foregroundStyle(.secondary)
        }
    }
}

// CartView.swift — fullScreenCover
struct CartView: View {
    @Environment(CartStore.self) private var cart
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if cart.state.isEmpty {
                    ContentUnavailableView("Cart is Empty", systemImage: "cart")
                } else {
                    cartList
                }
            }
            .navigationTitle("Cart")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if !cart.state.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Checkout") { checkoutTapped() }
                    }
                }
            }
        }
    }

    private var cartList: some View {
        List {
            ForEach(cart.state.items) { CartItemRow(product: $0) }
                .onDelete { cart.send(.removeAt($0)) }

            Section {
                HStack {
                    Text("Total").bold()
                    Spacer()
                    Text(cart.state.total, format: .currency(code: "USD")).bold()
                }
            }
        }
    }

    private func checkoutTapped() {
        dismiss()
        // Wait for cover to dismiss before pushing onto the stack
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            router.send(.push(.checkout))
        }
    }
}
```

---

## Step 5 — Root app wiring (~5 min)

```swift
// ShopKitApp.swift
@main
struct ShopKitApp: App {
    @State private var router = Router()
    @State private var cart   = CartStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(cart)
                .onOpenURL { router.send(.handleDeepLink($0)) }
        }
    }
}

// RootView.swift — all navigationDestination declared here at root
struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(CartStore.self) private var cart

    var body: some View {
        @Bindable var router = router

        NavigationStack(path: $router.path) {
            CategoryListView()
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        CartBadgeButton(count: cart.state.count) {
                            router.send(.presentCart)
                        }
                    }
                }
                // ★ ALL navigationDestination modifiers live at the root
                // Declaring them inside ForEach/conditionals can cause them to be missed
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .productList(let category):
                        ProductListView(vm: ProductListViewModel(category: category))
                    case .productDetail(let id):
                        ProductDetailView(vm: ProductDetailViewModel(cart: cart), productID: id)
                    case .checkout:
                        CheckoutView()
                    }
                }
        }
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .filter:            FilterView()
            case .review(let id):   ReviewView(productID: id)
            }
        }
        .fullScreenCover(isPresented: $router.isCartPresented) {
            CartView()
        }
    }
}

// Stub views
struct CheckoutView: View {
    @Environment(CartStore.self) private var cart
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("Order placed!").font(.title.bold())
            Button("Done") { cart.send(.clear) }.buttonStyle(.borderedProminent)
        }
        .navigationTitle("Confirmed")
    }
}
struct FilterView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Text("Filters").toolbar { Button("Done") { dismiss() } }
        }
    }
}
struct ReviewView: View {
    let productID: UUID
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Text("Review").toolbar { Button("Submit") { dismiss() } }
        }
    }
}
```

---

## Step 6 — Swift Testing suite (~10 min)

```swift
// RouterTests.swift
import Testing
@testable import ShopKit

@Suite("Router")
struct RouterTests {

    @Test @MainActor
    func pushAppendsToPath() {
        let router = Router()
        router.send(.push(.productList(category: "Audio")))
        #expect(!router.path.isEmpty)
    }

    @Test @MainActor
    func popOnEmptyPathIsNoop() {
        let router = Router()
        router.send(.pop)
        #expect(router.path.isEmpty)
    }

    @Test @MainActor
    func popToRootClearsPath() {
        let router = Router()
        router.send(.push(.productList(category: "Audio")))
        router.send(.push(.checkout))
        router.send(.popToRoot)
        #expect(router.path.isEmpty)
    }

    @Test @MainActor
    func presentSheetSetsSheet() {
        let router = Router()
        router.send(.presentSheet(.filter))
        #expect(router.sheet?.id == "filter")
    }

    @Test @MainActor
    func dismissSheetClearsSheet() {
        let router = Router()
        router.send(.presentSheet(.filter))
        router.send(.dismissSheet)
        #expect(router.sheet == nil)
    }

    @Test @MainActor
    func presentCartSetsFlag() {
        let router = Router()
        router.send(.presentCart)
        #expect(router.isCartPresented)
    }

    @Test @MainActor
    func deepLinkProductPushesRoute() {
        let router = Router()
        let id = UUID()
        let url = URL(string: "shopkit://product/\(id)")!
        router.send(.handleDeepLink(url))
        #expect(!router.path.isEmpty)
    }
}

@Suite("CartStore")
struct CartStoreTests {

    @Test @MainActor
    func addProductIncreasesCount() {
        let store = CartStore()
        let product = Product.samples[0]
        store.send(.addProduct(product))
        #expect(store.state.count == 1)
    }

    @Test @MainActor
    func clearRemovesAllItems() {
        let store = CartStore()
        store.send(.addProduct(Product.samples[0]))
        store.send(.addProduct(Product.samples[1]))
        store.send(.clear)
        #expect(store.state.isEmpty)
    }

    @Test @MainActor
    func totalSumsCorrectly() {
        let store = CartStore()
        store.send(.addProduct(Product(id: UUID(), name: "A", price: 10.00, category: "X")))
        store.send(.addProduct(Product(id: UUID(), name: "B", price: 20.00, category: "X")))
        #expect(store.state.total == 30.00)
    }
}

@Suite("ProductListViewModel")
struct ProductListViewModelTests {

    @Test @MainActor
    func loadTransitionsToLoaded() async throws {
        let products = [Product.samples[0]]
        let service = MockProductCatalogService(stubbedProducts: products)
        let vm = ProductListViewModel(category: "Audio", service: service)

        vm.send(.load)
        try await Task.sleep(for: .milliseconds(10))

        if case .loaded(let items) = vm.state.phase {
            #expect(items.count == 1)
        } else {
            Issue.record("Expected .loaded phase")
        }
    }

    @Test @MainActor
    func loadWithNoResultsTransitionsToEmpty() async throws {
        let service = MockProductCatalogService(stubbedProducts: [])
        let vm = ProductListViewModel(category: "Audio", service: service)

        vm.send(.load)
        try await Task.sleep(for: .milliseconds(10))

        #expect(vm.state.phase == .empty)
    }

    @Test @MainActor
    func selectProductFiresRouterAction() async throws {
        let product = Product.samples[0]
        let service = MockProductCatalogService(stubbedProducts: [product])
        let vm = ProductListViewModel(category: "Audio", service: service)

        var receivedAction: RouterAction?
        vm.onRouterAction = { receivedAction = $0 }

        vm.send(.load)
        try await Task.sleep(for: .milliseconds(10))
        vm.send(.selectProduct(product))

        if case .push(.productDetail(let id)) = receivedAction {
            #expect(id == product.id)
        } else {
            Issue.record("Expected push .productDetail route")
        }
    }
}

@Suite("ProductDetailViewModel")
struct ProductDetailViewModelTests {

    @Test @MainActor
    func addToCartUpdatesCartStore() async throws {
        let cart = CartStore()
        let vm = ProductDetailViewModel(cart: cart)

        vm.send(.load(id: Product.samples[0].id))
        try await Task.sleep(for: .milliseconds(50))

        vm.send(.addToCart)
        #expect(cart.state.count == 1)
        #expect(vm.state.addedToCart)
    }

    @Test @MainActor
    func loadWithUnknownIDTransitionsToNotFound() async throws {
        let cart = CartStore()
        let vm = ProductDetailViewModel(cart: cart)
        vm.send(.load(id: UUID()))  // Unknown ID
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.state.phase == .notFound)
    }
}
```

---

## Coordinator vs Pure SwiftUI Router

| | Coordinator (Tutorial 22) | Pure SwiftUI Router |
|---|---|---|
| **Navigation owner** | Coordinator object, factory methods | Router in `@Environment` |
| **VM ↔ navigation** | VM fires actions to coordinator via `onAction` closure | VM fires `RouterAction` via `onRouterAction` |
| **Boilerplate** | More (coordinator class, factories) | Less |
| **VM isolation** | Highest — VMs have no navigation imports | Good — VMs know about `RouterAction` |
| **Best for** | Large teams, complex multi-flow apps | SwiftUI-first apps, smaller teams |
| **Testing** | Test VM in isolation; coordinator separately | Test VM with mock router action handler |

---

## Key concepts to remember

**`@Bindable` for `@Observable`:**
`@Observable` objects don't auto-generate `$` bindings like `@ObservedObject` did. Declare `@Bindable var router = router` inside `body` to get `$router.path` for `NavigationStack`.

**All `navigationDestination` at the root:**
SwiftUI searches up the view tree for destination modifiers. Defining them inside a `ForEach` or conditional block can cause them to be silently missed. One `.navigationDestination(for: Route.self)` on the `NavigationStack`'s root view is the safest pattern.

**`NavigationPath` vs `[Route]`:**
Use `NavigationPath` when pushing heterogeneous `Hashable` types. Use `[Route]` when you have one route enum — it's simpler, Codable automatically, and easier to assert in tests.

**`send(_:)` on CartStore:** Applying the same dispatch pattern to shared stores means all state transitions follow one model throughout the app — predictable, auditable, and testable.

---

## Follow-up questions

- *Why `.sheet(item:)` over `.sheet(isPresented:)`?* (`item:` auto-dismisses when set to `nil`; one `@State` covers multiple possible sheets via an `Identifiable` enum instead of N booleans)
- *Can you nest `NavigationStack`s?* (No — one per column. Nested stacks cause undefined behavior. Use `.sheet` for modal navigation with its own stack)
- *How do you navigate after a `fullScreenCover` dismisses?* (`DispatchQueue.main.asyncAfter` with a small delay, or observe `.onChange(of: isPresented)` that fires on dismiss completion)
- *How does state restoration work?* (Encode `router.path.codable` to `UserDefaults` on `scenePhase == .background`; decode and restore on launch — requires all `Route` cases to be `Codable`)
