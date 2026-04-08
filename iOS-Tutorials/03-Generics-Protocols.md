# Tutorial 03 — Swift Generics, Protocols, associatedtype, some, typealias
## Build: DataKit — a type-safe repository layer
**Time:** 60 min | **Swift 6** | **Topics:** Generics, protocols, PAT, `some`, `any`, `typealias`, `where`

---

## What you'll build
A generic repository pattern used in real fintech apps:
- `Repository<T>` — generic CRUD with compile-time type safety
- Protocol with `associatedtype` → type-erased with `any`
- `some` for opaque return types
- `where` constraints on extensions
- `typealias` for ergonomic API

---

## Concept deep-dive

### Generic functions
```swift
// Without generics — duplicated code
func saveUser(_ user: User) { }
func saveProduct(_ product: Product) { }

// With generics — one function, infinite types
func save<T: Encodable>(_ item: T, key: String) throws {
    let data = try JSONEncoder().encode(item)
    UserDefaults.standard.set(data, key)
}
```

### Protocols with associatedtype (PAT)
```swift
// associatedtype = a placeholder type the conformer fills in
protocol Repository {
    associatedtype Entity: Identifiable & Codable & Sendable

    func fetch(id: Entity.ID) async throws -> Entity?
    func fetchAll() async throws -> [Entity]
    func save(_ entity: Entity) async throws
    func delete(id: Entity.ID) async throws
}

// ★ You CANNOT use PAT as a regular type:
// let r: Repository = ...    ← COMPILE ERROR
// Solution: use `any Repository` (type erasure) or generics
```

### `some` vs `any`
```swift
// some = opaque concrete type — caller gets ONE type, compiler knows which
// Allows protocol optimization; cannot be stored heterogeneously
func makeRepository() -> some Repository { ... }

// any = existential — runtime type erasure, slight overhead
// Required when you need heterogeneous collections
var repos: [any Repository] = [UserRepo(), ProductRepo()]
```

---

## Step 1 — Protocols and models (~10 min)

```swift
// Repository.swift
import Foundation

// MARK: - Base constraints
protocol Entity: Identifiable, Codable, Sendable {
    var id: UUID { get }
    var createdAt: Date { get }
}

// MARK: - Repository protocol (PAT)
protocol Repository<E>: Sendable where E: Entity {
    // Primary associatedtype
    associatedtype E

    // typealias for ergonomics — callers write Repo.ID not Repo.E.ID
    typealias ID = E.ID

    func fetch(id: ID) async throws -> E?
    func fetchAll() async throws -> [E]
    func fetchAll(where predicate: @Sendable (E) -> Bool) async throws -> [E]
    func save(_ entity: E) async throws
    func delete(id: ID) async throws
    func count() async throws -> Int
}

// Default implementation via extension + where clause
extension Repository {
    func fetchAll(where predicate: @Sendable (E) -> Bool) async throws -> [E] {
        try await fetchAll().filter(predicate)
    }

    func count() async throws -> Int {
        try await fetchAll().count
    }
}
```

---

## Step 2 — Concrete models (~5 min)

```swift
// Models.swift
import Foundation

struct User: Entity {
    let id: UUID
    let createdAt: Date
    var name: String
    var email: String
    var tier: Tier

    enum Tier: String, Codable, Sendable { case free, pro, enterprise }

    static func make(name: String, email: String) -> User {
        User(id: UUID(), createdAt: .now, name: name, email: email, tier: .free)
    }
}

struct Product: Entity {
    let id: UUID
    let createdAt: Date
    var title: String
    var price: Decimal
    var isAvailable: Bool

    static func make(title: String, price: Decimal) -> Product {
        Product(id: UUID(), createdAt: .now, title: title, price: price, isAvailable: true)
    }
}
```

---

## Step 3 — Generic in-memory store (~15 min)

```swift
// InMemoryStore.swift
import Foundation

// Generic class — T is constrained to Entity
// This one class serves ALL entity types
actor InMemoryRepository<T: Entity>: Repository {
    typealias E = T

    private var store: [T.ID: T] = [:]

    func fetch(id: T.ID) async throws -> T? {
        store[id]
    }

    func fetchAll() async throws -> [T] {
        store.values.sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ entity: T) async throws {
        store[entity.id] = entity
    }

    func delete(id: T.ID) async throws {
        guard store[id] != nil else {
            throw RepositoryError.notFound(String(describing: id))
        }
        store[id] = nil
    }
}

enum RepositoryError: Error {
    case notFound(String)
    case saveFailed(String)
}
```

---

## Step 4 — Generic service layer + `where` constraints (~10 min)

```swift
// GenericService.swift
import Foundation

// Generic service — works with ANY Repository
struct CRUDService<Repo: Repository> {
    let repository: Repo

    // typealias makes the API clean
    typealias Item = Repo.E

    func create(_ item: Item) async throws -> Item {
        try await repository.save(item)
        return item
    }

    func get(id: Item.ID) async throws -> Item {
        guard let item = try await repository.fetch(id: id) else {
            throw RepositoryError.notFound("\(id)")
        }
        return item
    }

    func list() async throws -> [Item] {
        try await repository.fetchAll()
    }

    func update(_ item: Item) async throws -> Item {
        try await repository.save(item)
        return item
    }

    func remove(id: Item.ID) async throws {
        try await repository.delete(id: id)
    }
}

// Extension constrained to repos whose Entity has a `name` property
// (where clause on extension — very powerful pattern)
extension CRUDService where Item: Nameable {
    func search(query: String) async throws -> [Item] {
        try await repository.fetchAll(where: { item in
            item.name.localizedCaseInsensitiveContains(query)
        })
    }
}

protocol Nameable {
    var name: String { get }
}

extension User: Nameable { var name: String { name } }
```

---

## Step 5 — `some` keyword and opaque types (~10 min)

```swift
// RepositoryFactory.swift
import Foundation

// `some` = opaque return type
// Caller gets a Repository-conforming value, but doesn't need to know the concrete type
// Enables changing implementation without breaking callers

struct RepositoryFactory {

    // ★ `some Repository<User>` — Swift 5.7+ primary associated types
    static func makeUserRepository() -> some Repository<User> {
        InMemoryRepository<User>()
    }

    static func makeProductRepository() -> some Repository<Product> {
        InMemoryRepository<Product>()
    }
}

// Convenience typealiases — clean up generic noise at call sites
typealias UserService    = CRUDService<InMemoryRepository<User>>
typealias ProductService = CRUDService<InMemoryRepository<Product>>
```

---

## Step 6 — ViewModel demonstrating all concepts (~10 min)

```swift
// AppViewModel.swift
import Observation

@MainActor
@Observable
final class AppViewModel {

    var users: [User] = []
    var products: [Product] = []
    var searchResults: [User] = []
    var isLoading = false
    var errorMessage: String?

    // Concrete types via typealias
    private let userService = UserService(
        repository: InMemoryRepository<User>()
    )
    private let productService = ProductService(
        repository: InMemoryRepository<Product>()
    )

    func bootstrap() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // Parallel creation using async let
            async let _ = userService.create(.make(name: "Alice", email: "alice@example.com"))
            async let _ = userService.create(.make(name: "Bob",   email: "bob@example.com"))
            async let _ = productService.create(.make(title: "Pro Plan", price: 9.99))

            // Await both to complete
            users    = try await userService.list()
            products = try await productService.list()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func search(query: String) async {
        guard !query.isEmpty else {
            searchResults = users
            return
        }
        // ★ This method only exists when Item: Nameable (where extension)
        searchResults = (try? await userService.search(query: query)) ?? []
    }
}
```

---

## ★ Challenge

Build a `PaginatedRepository` wrapper:

```swift
// Generic wrapper — works with ANY Repository
struct PaginatedRepository<Base: Repository> {
    let base: Base
    let pageSize: Int

    typealias E = Base.E

    func page(_ number: Int) async throws -> [Base.E] {
        let all = try await base.fetchAll()
        let start = number * pageSize
        guard start < all.count else { return [] }
        return Array(all[start..<min(start + pageSize, all.count)])
    }
}
```

Then make it conform to `Repository` itself. Hint: you'll need to forward all methods.

---

## Key concepts to remember

**`some` vs `any`:** `some` is a compile-time optimization — the compiler knows the real type and can inline/optimize. `any` is a runtime box — slower but required for heterogeneous storage like arrays. Prefer `some` in function signatures when you return one specific implementation.

**PAT + primary associated types:** `Repository<User>` syntax (Swift 5.7+) avoids the need for full type erasure in many cases.

**`where` on extensions:** This is extremely powerful in production code — add methods only when constraints are satisfied. Avoids polluting base types with domain-specific logic.

---

## Follow-up questions

- *What's the difference between `protocol P {}` and `protocol P<T> {}`?* (Primary associated type — allows `some P<T>` syntax)
- *When would you use `any` over generics?* (Heterogeneous collections, Objective-C interop, stored properties that vary at runtime)
- *What's a phantom type?* (Generic parameter that constrains usage without being stored: `struct TypedID<T: Entity>: Sendable { let value: UUID }`)
