# Tutorial 28 — State Restoration
## Build: RestoreKit — an app that picks up exactly where you left off
**Time:** 45 min | **Swift 6** | **Topics:** `SceneStorage`, `AppStorage`, SwiftData checkpoints, `NSUserActivity`, `onContinueUserActivity`, restoration after termination/battery death

---

## The problem

Without state restoration, every cold launch drops the user at the root screen with no data. State restoration means:
- **Navigation position** — user was 3 levels deep; they return there
- **Scroll position / selected tab** — minor but professional
- **Unsaved form input** — the draft they were typing
- **In-flight request context** — which page/filter/query was active

Battery death and OS termination are handled by the same mechanism — if you save state correctly on `.background`, it's available on any relaunch regardless of why the app was killed.

---

## Restoration layers

| What | Tool | Scope |
|---|---|---|
| Current tab / selected item | `@SceneStorage` | Per scene, automatic |
| User preferences | `@AppStorage` | Cross-launch, user-facing settings |
| Draft/form text | `@SceneStorage` | Per scene |
| Navigation stack | `NavigationPath` + `@SceneStorage` (JSON) | Per scene |
| Complex model state | SwiftData or Keychain | Persists across reinstall optionally |
| Handoff / Spotlight | `NSUserActivity` | Cross-device |

---

## Concept 1 — `@SceneStorage` (simplest, automatic)

```swift
// Automatically persisted per scene — survives termination
// Restored before body is evaluated on relaunch

struct ContentView: View {
    @SceneStorage("selectedTab") private var selectedTab = 0
    @SceneStorage("searchQuery") private var searchQuery = ""

    var body: some View {
        TabView(selection: $selectedTab) { ... }
    }
}
```

`@SceneStorage` supports: `Bool`, `Int`, `Double`, `String`, `URL`, `Data`.
For anything else, encode to `Data` first.

---

## Concept 2 — Restoring `NavigationPath`

`NavigationPath` is not directly `Codable`, but it exposes a `codable` representation:

```swift
@Observable
final class NavigationStore {
    var path = NavigationPath()

    private static let key = "nav.path"

    func save() {
        guard let rep = path.codable,
              let data = try? JSONEncoder().encode(rep) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let rep = try? JSONDecoder().decode(NavigationPath.CodableRepresentation.self, from: data)
        else { return }
        path = NavigationPath(rep)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
```

Hook into scene lifecycle:

```swift
struct RootView: View {
    @State private var navStore = NavigationStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $navStore.path) {
            HomeView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { navStore.save() }
        }
        .onAppear { navStore.restore() }
    }
}
```

---

## Concept 3 — Draft restoration with `@SceneStorage`

```swift
struct NoteEditorView: View {
    @SceneStorage("draft.title") private var title = ""
    @SceneStorage("draft.body")  private var body  = ""

    var body: some View {
        Form {
            TextField("Title", text: $title)
            TextEditor(text: $body)
        }
        // No save needed — @SceneStorage persists automatically
    }
}
```

Clear the draft on explicit save:

```swift
func saveNote() {
    repository.save(Note(title: title, body: body))
    title = ""
    body  = ""
}
```

---

## Concept 4 — SwiftData checkpoint (complex state)

For model state that's too large or structured for `@SceneStorage`:

```swift
// Checkpoint.swift — lightweight snapshot of current session
import SwiftData

@Model
final class SessionCheckpoint {
    var activeFilter: String
    var activePage: Int
    var savedAt: Date

    init(filter: String, page: Int) {
        self.activeFilter = filter
        self.activePage = page
        self.savedAt = Date()
    }
}
```

```swift
// Save on background
func saveCheckpoint(filter: String, page: Int, context: ModelContext) {
    // Delete old checkpoint first
    try? context.delete(model: SessionCheckpoint.self)
    context.insert(SessionCheckpoint(filter: filter, page: page))
    try? context.save()
}

// Restore on launch
func restoreCheckpoint(context: ModelContext) -> SessionCheckpoint? {
    let descriptor = FetchDescriptor<SessionCheckpoint>(
        sortBy: [SortDescriptor(\.savedAt, order: .reverse)]
    )
    return try? context.fetch(descriptor).first
}
```

---

## Concept 5 — `NSUserActivity` (Handoff + Spotlight)

```swift
// Declare what the user is doing — enables Handoff to other devices
// and return-to-app from Spotlight/Siri

struct ArticleDetailView: View {
    let article: Article

    var body: some View {
        ArticleBodyView(article: article)
            .userActivity("com.example.app.viewArticle") { activity in
                activity.title = article.title
                activity.userInfo = ["articleID": article.id]
                activity.isEligibleForHandoff = true
                activity.isEligibleForSearch = true
            }
    }
}

// Receive at the scene level
struct RootView: View {
    var body: some View {
        ContentView()
            .onContinueUserActivity("com.example.app.viewArticle") { activity in
                guard let id = activity.userInfo?["articleID"] as? String else { return }
                navigationStore.push(.articleDetail(id: id))
            }
    }
}
```

---

## Full production example

### Models

```swift
// RestorationModels.swift
import Foundation

struct AppSession: Codable, Equatable {
    var selectedTab: Int = 0
    var activeFilter: String = "all"
    var scrollOffset: Double = 0
    var draftTitle: String = ""
    var savedAt: Date = .distantPast
}

enum RestoreAction: Sendable {
    case saveSession
    case restoreSession
    case updateTab(Int)
    case updateFilter(String)
    case updateDraft(String)
    case clearDraft
}

struct RestoreState: Equatable {
    var session: AppSession = AppSession()
    var isRestored: Bool = false
}
```

---

### RestorationService

```swift
// RestorationService.swift
import Foundation

protocol RestorationServiceProtocol: Sendable {
    func save(_ session: AppSession) throws
    func load() throws -> AppSession?
    func clear()
}

struct RestorationService: RestorationServiceProtocol {
    private static let key = "app.session"

    func save(_ session: AppSession) throws {
        let data = try JSONEncoder().encode(session)
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func load() throws -> AppSession? {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return nil }
        return try JSONDecoder().decode(AppSession.self, from: data)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

struct MockRestorationService: RestorationServiceProtocol {
    var stored: AppSession? = nil
    var shouldFailLoad = false

    mutating func save(_ session: AppSession) {
        stored = session
    }

    func load() throws -> AppSession? {
        if shouldFailLoad { throw URLError(.cannotDecodeContentData) }
        return stored
    }

    func clear() { }
}
```

---

### ViewModel

```swift
// SessionViewModel.swift
import Foundation

@MainActor
protocol SessionViewModelProtocol: AnyObject, Observable {
    var state: RestoreState { get }
    func send(_ action: RestoreAction)
}

@MainActor
@Observable
final class SessionViewModel: SessionViewModelProtocol {

    private(set) var state = RestoreState()
    private let service: any RestorationServiceProtocol

    init(service: any RestorationServiceProtocol) { self.service = service }
    init() { self.service = RestorationService() }

    func send(_ action: RestoreAction) {
        switch action {
        case .saveSession:              saveSession()
        case .restoreSession:           restoreSession()
        case .updateTab(let tab):       state.session.selectedTab = tab
        case .updateFilter(let filter): state.session.activeFilter = filter
        case .updateDraft(let text):    state.session.draftTitle = text
        case .clearDraft:               state.session.draftTitle = ""
        }
    }

    // MARK: - Private

    private func saveSession() {
        state.session.savedAt = Date()
        try? service.save(state.session)
    }

    private func restoreSession() {
        guard let restored = try? service.load() else {
            state.isRestored = true
            return
        }
        state.session = restored
        state.isRestored = true
    }
}
```

---

### Root view wiring

```swift
// AppRootView.swift
import SwiftUI

struct AppRootView: View {
    @State private var vm: any SessionViewModelProtocol
    @State private var navStore = NavigationStore()
    @Environment(\.scenePhase) private var scenePhase

    init(vm: any SessionViewModelProtocol) { self._vm = State(initialValue: vm) }

    var body: some View {
        Group {
            if vm.state.isRestored {
                mainContent
            } else {
                ProgressView()   // brief restoration window
            }
        }
        .onAppear {
            navStore.restore()
            vm.send(.restoreSession)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                vm.send(.saveSession)
                navStore.save()
            }
        }
    }

    private var mainContent: some View {
        NavigationStack(path: $navStore.path) {
            TabView(selection: Binding(
                get: { vm.state.session.selectedTab },
                set: { vm.send(.updateTab($0)) }
            )) {
                FeedTab(vm: vm).tabItem { Label("Feed", systemImage: "newspaper") }.tag(0)
                DraftTab(vm: vm).tabItem { Label("Draft", systemImage: "pencil") }.tag(1)
            }
        }
    }
}

struct FeedTab: View {
    let vm: any SessionViewModelProtocol
    var body: some View {
        Text("Filter: \(vm.state.session.activeFilter)")
    }
}

struct DraftTab: View {
    let vm: any SessionViewModelProtocol
    var body: some View {
        TextField("Draft title", text: Binding(
            get: { vm.state.session.draftTitle },
            set: { vm.send(.updateDraft($0)) }
        ))
        .padding()
    }
}
```

---

## Tests

```swift
// SessionViewModelTests.swift
import Testing
@testable import RestoreKit

@Suite("SessionViewModel — State Restoration")
@MainActor
struct SessionViewModelTests {

    func makeVM(stored: AppSession? = nil) -> SessionViewModel {
        SessionViewModel(service: MockRestorationService(stored: stored))
    }

    // MARK: - Restore

    @Test func restoreWithNoStoredSessionSetsIsRestored() {
        let vm = makeVM()
        vm.send(.restoreSession)
        #expect(vm.state.isRestored)
    }

    @Test func restoreLoadsStoredTab() {
        var session = AppSession()
        session.selectedTab = 2
        let vm = makeVM(stored: session)
        vm.send(.restoreSession)
        #expect(vm.state.session.selectedTab == 2)
    }

    @Test func restoreLoadsStoredFilter() {
        var session = AppSession()
        session.activeFilter = "videos"
        let vm = makeVM(stored: session)
        vm.send(.restoreSession)
        #expect(vm.state.session.activeFilter == "videos")
    }

    @Test func restoreLoadsDraft() {
        var session = AppSession()
        session.draftTitle = "My unfinished draft"
        let vm = makeVM(stored: session)
        vm.send(.restoreSession)
        #expect(vm.state.session.draftTitle == "My unfinished draft")
    }

    @Test func restoreWithFailureStillSetsIsRestored() {
        let vm = SessionViewModel(service: MockRestorationService(shouldFailLoad: true))
        vm.send(.restoreSession)
        #expect(vm.state.isRestored)   // graceful degradation
        #expect(vm.state.session == AppSession())   // defaults
    }

    // MARK: - State updates

    @Test func updateTabChangesSessionTab() {
        let vm = makeVM()
        vm.send(.updateTab(1))
        #expect(vm.state.session.selectedTab == 1)
    }

    @Test func updateFilterChangesFilter() {
        let vm = makeVM()
        vm.send(.updateFilter("podcasts"))
        #expect(vm.state.session.activeFilter == "podcasts")
    }

    @Test func updateDraftSavesDraftText() {
        let vm = makeVM()
        vm.send(.updateDraft("Hello world"))
        #expect(vm.state.session.draftTitle == "Hello world")
    }

    @Test func clearDraftEmptiesDraft() {
        let vm = makeVM()
        vm.send(.updateDraft("Some text"))
        vm.send(.clearDraft)
        #expect(vm.state.session.draftTitle.isEmpty)
    }

    // MARK: - Save

    @Test func saveSessionStoresCurrentState() throws {
        var mockService = MockRestorationService()
        let vm = SessionViewModel(service: mockService)
        vm.send(.updateTab(1))
        vm.send(.updateFilter("tracks"))
        vm.send(.saveSession)
        // Verify savedAt was set
        #expect(vm.state.session.savedAt > Date.distantPast)
    }

    @Test func saveAndRestoreRoundTrip() throws {
        var session = AppSession()
        session.selectedTab = 1
        session.activeFilter = "tracks"
        session.draftTitle = "Draft text"

        // Save
        let service = RestorationService()
        try service.save(session)

        // Restore into a new VM
        let vm = SessionViewModel(service: service)
        vm.send(.restoreSession)

        #expect(vm.state.session.selectedTab == 1)
        #expect(vm.state.session.activeFilter == "tracks")
        #expect(vm.state.session.draftTitle == "Draft text")

        service.clear()
    }
}
```

---

## Restoration priority order

```
On cold launch:
    1. Attempt service.load() — SwiftData / UserDefaults / Keychain
    2. If nil or decode error → use default AppSession (never crash)
    3. Apply session to ViewModels before first render
    4. Set isRestored = true → show UI

On background:
    1. service.save(currentSession)
    2. navStore.save()
    3. Any pending SwiftData context.save()
    4. Return within 5 seconds
```

## Interview questions

| Question | Concept |
|---|---|
| "How do you restore navigation state after termination?" | `NavigationPath.codable` → JSON → `UserDefaults` |
| "What's the difference between `@SceneStorage` and `@AppStorage`?" | Scene-scoped vs app-scoped; both survive termination |
| "What happens to state when the battery dies?" | Same as normal termination — rely on background save |
| "How do you restore form drafts?" | `@SceneStorage` on text fields — automatic |
| "How do you implement Handoff?" | `NSUserActivity` + `.userActivity()` modifier |
| "What if restoration itself fails (corrupt data)?" | Always fall back to defaults — never crash on bad saved state |
