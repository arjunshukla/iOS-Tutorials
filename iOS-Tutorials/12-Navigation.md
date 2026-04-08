# Tutorial 12 — Navigation in SwiftUI (iOS 17+) and UIKit
## Build: NavKit — a deep-link capable multi-stack app
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** NavigationStack, NavigationPath, NavigationSplitView, deep linking, programmatic navigation, UIKit UINavigationController

---

## What you'll build
A navigation demo with:
- `NavigationStack` + typed `NavigationPath` (SwiftUI)
- Programmatic deep-link navigation from a notification
- `NavigationSplitView` for iPad sidebar layout
- UIKit `UINavigationController` pushed from SwiftUI

---

## The evolution of SwiftUI navigation

```
iOS 13: NavigationView + .isDetailLink — confusing, broken on iPad
iOS 16: NavigationStack + NavigationPath — finally correct
iOS 17: .navigationDestination(item:) — even cleaner, no need for bindings
iOS 18: .navigationTransition(.zoom) — hero transitions
```

---

## Step 1 — Type-safe route enum (~10 min)

```swift
// AppRoute.swift
import SwiftUI

// ★ Hashable enum = type-safe navigation paths
// NavigationPath can hold any Hashable value
enum AppRoute: Hashable {
    case productList(category: String)
    case productDetail(id: UUID)
    case checkout
    case orderConfirmation(orderID: String)
    case profile
    case settings(section: SettingsSection)

    enum SettingsSection: String, Hashable, CaseIterable {
        case notifications, privacy, account, help
    }
}

// Deep link URL → AppRoute
extension AppRoute {
    init?(url: URL) {
        guard url.scheme == "navkit",
              let host = url.host
        else { return nil }

        switch host {
        case "product":
            let id = url.pathComponents.dropFirst().first.flatMap(UUID.init)
            guard let id else { return nil }
            self = .productDetail(id: id)
        case "checkout":
            self = .checkout
        case "settings":
            let section = url.pathComponents.dropFirst().first
                .flatMap(AppRoute.SettingsSection.init(rawValue:))
                ?? .notifications
            self = .settings(section: section)
        default:
            return nil
        }
    }
}
```

---

## Step 2 — NavigationStack with path binding (~15 min)

```swift
// MainNavigationView.swift
import SwiftUI

@MainActor
@Observable
final class NavigationRouter {
    var path: NavigationPath = NavigationPath()

    // Programmatic navigation
    func navigate(to route: AppRoute) {
        path.append(route)
    }

    func navigateTo(routes: [AppRoute]) {
        for route in routes { path.append(route) }
    }

    func popToRoot() {
        path = NavigationPath()
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    // Handle deep link: navkit://product/UUID
    func handleDeepLink(_ url: URL) {
        guard let route = AppRoute(url: url) else { return }
        popToRoot()
        navigate(to: route)
    }
}

struct MainNavigationView: View {
    @State private var router = NavigationRouter()

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: AppRoute.self) { route in
                    destinationView(for: route)
                }
        }
        .environment(router)
        // Handle deep links
        .onOpenURL { url in
            router.handleDeepLink(url)
        }
    }

    @ViewBuilder
    func destinationView(for route: AppRoute) -> some View {
        switch route {
        case .productList(let category):
            ProductListView(category: category)
        case .productDetail(let id):
            ProductDetailView(id: id)
        case .checkout:
            CheckoutView()
        case .orderConfirmation(let orderID):
            OrderConfirmationView(orderID: orderID)
        case .profile:
            ProfileView()
        case .settings(let section):
            SettingsView(section: section)
        }
    }
}

struct HomeView: View {
    @Environment(NavigationRouter.self) var router

    var body: some View {
        List {
            Button("Product List → Detail → Checkout") {
                // Deep navigation: push 3 levels at once
                router.navigateTo(routes: [
                    .productList(category: "Electronics"),
                    .productDetail(id: UUID()),
                    .checkout
                ])
            }
            Button("Settings → Privacy") {
                router.navigateTo(routes: [.settings(section: .privacy)])
            }
            Button("Pop to root") {
                router.popToRoot()
            }
        }
        .navigationTitle("Home")
    }
}
```

---

## Step 3 — NavigationSplitView for iPad (~10 min)

```swift
// SplitNavigationView.swift
import SwiftUI

// NavigationSplitView: sidebar + detail — automatic on iPad, sheet on iPhone
struct SplitNavigationView: View {
    @State private var selectedCategory: String? = nil
    @State private var selectedProduct: UUID? = nil

    let categories = ["Electronics", "Clothing", "Books", "Sports", "Home"]

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // Sidebar
            List(categories, id: \.self, selection: $selectedCategory) { category in
                Label(category, systemImage: "folder")
            }
            .navigationTitle("Categories")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)

        } content: {
            // Middle column (iPad three-column only)
            if let category = selectedCategory {
                ProductListView(category: category)
            } else {
                ContentUnavailableView("Select a category", systemImage: "sidebar.left")
            }

        } detail: {
            // Detail column
            if let id = selectedProduct {
                ProductDetailView(id: id)
            } else {
                ContentUnavailableView("Select a product", systemImage: "photo")
            }
        }
    }
}
```

---

## Step 4 — UIKit UINavigationController from SwiftUI (~10 min)

```swift
// UIKitNavigationBridge.swift
import SwiftUI
import UIKit

// Scenario: you need to push a UIViewController from SwiftUI
// Pattern: wrap UINavigationController in UIViewControllerRepresentable

struct UIKitNavigationBridge: UIViewControllerRepresentable {
    let rootViewControllerBuilder: () -> UIViewController

    func makeUIViewController(context: Context) -> UINavigationController {
        let root = rootViewControllerBuilder()
        return UINavigationController(rootViewController: root)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) { }
}

// ─────────────────────────────────────────────────────────────────
// Opposite direction: push SwiftUI view from UIKit
// ─────────────────────────────────────────────────────────────────

class UIKitViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UIKit Screen"

        let button = UIButton(type: .system)
        button.setTitle("Push SwiftUI Screen", for: .normal)
        button.addTarget(self, action: #selector(pushSwiftUI), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc func pushSwiftUI() {
        // Wrap SwiftUI view in UIHostingController and push
        let swiftUIView = SwiftUIDetailView(title: "Pushed from UIKit")
        let hostingController = UIHostingController(rootView: swiftUIView)
        hostingController.title = "SwiftUI Detail"
        navigationController?.pushViewController(hostingController, animated: true)
    }
}

struct SwiftUIDetailView: View {
    let title: String

    var body: some View {
        VStack {
            Text(title).font(.headline)
            Text("Pushed from UIKit UINavigationController")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(title)
    }
}
```

---

## Step 5 — .navigationDestination(item:) — iOS 17 pattern (~5 min)

```swift
// iOS 17 cleaner binding pattern
struct ProductListView: View {
    let category: String
    @State private var selectedProduct: ProductSummary? = nil

    struct ProductSummary: Identifiable, Hashable {
        let id: UUID
        let name: String
    }

    let products: [ProductSummary] = (1...20).map {
        ProductSummary(id: UUID(), name: "Product \($0)")
    }

    var body: some View {
        List(products) { product in
            Button(product.name) {
                selectedProduct = product  // set item → navigation activates
            }
        }
        // ★ iOS 17: bind to Optional<Item> directly
        // Navigation appears when item != nil, dismisses when item = nil
        .navigationDestination(item: $selectedProduct) { product in
            ProductDetailView(id: product.id)
        }
        .navigationTitle(category)
    }
}

// Placeholder views
struct ProductDetailView: View {
    let id: UUID
    var body: some View { Text("Product \(id)").navigationTitle("Detail") }
}
struct CheckoutView: View {
    var body: some View { Text("Checkout").navigationTitle("Checkout") }
}
struct OrderConfirmationView: View {
    let orderID: String
    var body: some View { Text("Order \(orderID)").navigationTitle("Confirmed") }
}
struct ProfileView: View {
    var body: some View { Text("Profile").navigationTitle("Profile") }
}
struct SettingsView: View {
    let section: AppRoute.SettingsSection
    var body: some View { Text("Settings: \(section.rawValue)").navigationTitle("Settings") }
}
```

---

## ★ Challenge

Implement **navigation state restoration** — serialize `NavigationPath` to JSON and restore it on next launch:

```swift
extension NavigationRouter {
    func save() {
        // NavigationPath is Codable when all appended types are Codable
        if let data = try? JSONEncoder().encode(path.codable) {
            UserDefaults.standard.set(data, forKey: "navPath")
        }
    }

    func restore() {
        if let data = UserDefaults.standard.data(forKey: "navPath"),
           let repr = try? JSONDecoder().decode(NavigationPath.CodableRepresentation.self, from: data) {
            path = NavigationPath(repr)
        }
    }
}
```

---

## Key concepts to remember

**`NavigationPath` vs typed array:** `NavigationPath` can hold ANY `Hashable` type — you can push `String`, `Int`, custom enums all in one path. A `[AppRoute]` works too when you have a single route type.

**`navigationDestination` placement:** Put it on the `NavigationStack` or a root view — NOT inside a `ForEach`. Multiple `.navigationDestination(for:)` modifiers for different types all work.

**iPad `NavigationSplitView`:** On iPhone it collapses to a stack automatically. Set `.navigationSplitViewStyle(.prominentDetail)` to control this behavior.

**`UIHostingController`:** The bridge from UIKit to SwiftUI. You can push it in a UINavigationController, present it modally, or embed it as a child. The SwiftUI view inside gets a `.navigationTitle` that sets the UIKit nav bar title.

---

## Follow-up questions

- *How do you handle back-swipe when you have a custom navigation transition?* (Override `interactivePopGestureRecognizer.delegate` in UIKit; in SwiftUI use `.navigationTransition`)
- *What's wrong with the old `NavigationView`?* (Broken two-column behavior on iPad, inconsistent back behavior, no path API)
- *How do you deep-link directly into a tab + stack combination?* (Hold router objects in `@Environment`, trigger navigation in the correct tab from `onOpenURL`)
