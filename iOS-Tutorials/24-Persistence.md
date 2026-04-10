# Tutorial 24 — Persistence in Modern Swift & iOS
## Build: NoteKeeper — notes app with SwiftData, AppStorage, and Keychain
**Time:** 45 min | **Swift 6 + SwiftUI + iOS 17+** | **Topics:** SwiftData, CoreData comparison, @AppStorage, Keychain, ModelContext, migrations, Swift Testing

---

## What you'll build

A notes app demonstrating the three persistence tiers every production app uses:

| Tier | Technology | Use case |
|---|---|---|
| Structured data | SwiftData | Notes, user-created content |
| Simple preferences | @AppStorage / UserDefaults | Theme, sort order, toggles |
| Secure secrets | Keychain | PIN, tokens, passwords |

---

## Persistence decision tree

```
What are you storing?
│
├── Sensitive? (tokens, passwords, biometric data)
│   └── Keychain
│
├── Simple scalar / small blob? (theme, last tab, feature flags)
│   └── @AppStorage / UserDefaults
│
├── Structured, queryable, relational?
│   ├── iOS 17+ / greenfield → SwiftData
│   └── Legacy codebase / complex migrations → CoreData
│
└── Ephemeral, session-only?
    └── In-memory (actor / @State)
```

---

## Architecture

```
NoteKeeperApp
├── NoteListView        ← send(.load), send(.delete), send(.create)
│   └── NoteListViewModel
├── NoteEditorView      ← send(.updateTitle), send(.updateBody), send(.save)
│   └── NoteEditorViewModel
└── SettingsView        ← send(.setTheme), send(.toggleBiometrics), send(.setPIN)
    └── SettingsViewModel

Persistence layer (injected via protocol):
├── NoteRepositoryProtocol  ← SwiftData implementation + InMemory mock
├── PreferencesServiceProtocol ← AppStorage implementation + in-memory mock
└── KeychainServiceProtocol ← Security.framework implementation + mock
```

---

## Step 1 — SwiftData model (~5 min)

```swift
// Note.swift
import SwiftData
import Foundation

// ★ @Model replaces NSManagedObject — pure Swift, no subclassing from ObjC base
@Model
final class Note {
    // SwiftData generates a stable identity from these stored properties
    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var tags: [String]

    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.tags = tags
    }
}

// Sendable value type for crossing actor boundaries
// ★ Never pass @Model objects across actor boundaries — SwiftData models
//   are NOT Sendable. Copy to a value type first.
struct NoteSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var tags: [String]

    init(from note: Note) {
        id = note.id
        title = note.title
        body = note.body
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        isPinned = note.isPinned
        tags = note.tags
    }
}
```

---

## Step 2 — Repository protocol + SwiftData implementation (~10 min)

```swift
// NoteRepositoryProtocol.swift
import Foundation

// ★ Protocol = swap SwiftData for InMemoryNoteRepository in tests
// SwiftData's ModelContext is @MainActor-bound — the protocol hides this
@MainActor
protocol NoteRepositoryProtocol: AnyObject {
    func fetchAll(sortedBy: NoteSortOrder) throws -> [NoteSnapshot]
    func fetch(id: UUID) throws -> NoteSnapshot?
    func create(title: String, body: String, tags: [String]) throws -> NoteSnapshot
    func update(_ snapshot: NoteSnapshot) throws
    func delete(id: UUID) throws
    func search(query: String) throws -> [NoteSnapshot]
}

enum NoteSortOrder: String, CaseIterable, Sendable {
    case newestFirst  = "Newest First"
    case oldestFirst  = "Oldest First"
    case titleAZ      = "Title A–Z"
    case pinnedFirst  = "Pinned First"
}

// SwiftDataNoteRepository.swift
import SwiftData

// ★ Thin wrapper around ModelContext — converts between @Model and NoteSnapshot
@MainActor
final class SwiftDataNoteRepository: NoteRepositoryProtocol {

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func fetchAll(sortedBy order: NoteSortOrder) throws -> [NoteSnapshot] {
        let descriptor = FetchDescriptor<Note>(
            predicate: nil,
            sortBy: sortDescriptors(for: order)
        )
        return try context.fetch(descriptor).map(NoteSnapshot.init)
    }

    func fetch(id: UUID) throws -> NoteSnapshot? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first.map(NoteSnapshot.init)
    }

    func create(title: String, body: String, tags: [String]) throws -> NoteSnapshot {
        let note = Note(title: title, body: body, tags: tags)
        context.insert(note)
        try context.save()
        return NoteSnapshot(from: note)
    }

    func update(_ snapshot: NoteSnapshot) throws {
        let id = snapshot.id
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == id }
        )
        guard let note = try context.fetch(descriptor).first else { return }
        note.title     = snapshot.title
        note.body      = snapshot.body
        note.isPinned  = snapshot.isPinned
        note.tags      = snapshot.tags
        note.updatedAt = .now
        try context.save()
    }

    func delete(id: UUID) throws {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == id }
        )
        if let note = try context.fetch(descriptor).first {
            context.delete(note)
            try context.save()
        }
    }

    func search(query: String) throws -> [NoteSnapshot] {
        // ★ SwiftData #Predicate uses Swift keyPaths — type-safe at compile time
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate {
                $0.title.localizedStandardContains(query) ||
                $0.body.localizedStandardContains(query)
            }
        )
        return try context.fetch(descriptor).map(NoteSnapshot.init)
    }

    // MARK: - Private helpers

    private func sortDescriptors(for order: NoteSortOrder) -> [SortDescriptor<Note>] {
        switch order {
        case .newestFirst:  return [SortDescriptor(\.createdAt, order: .reverse)]
        case .oldestFirst:  return [SortDescriptor(\.createdAt)]
        case .titleAZ:      return [SortDescriptor(\.title)]
        case .pinnedFirst:  return [SortDescriptor(\.isPinned, order: .reverse),
                                    SortDescriptor(\.updatedAt, order: .reverse)]
        }
    }
}
```

---

## Step 3 — Preferences + Keychain services (~5 min)

```swift
// PreferencesService.swift
import SwiftUI

// ★ Preferences values are plain Codable types — no framework leaking into VM
enum AppTheme: String, CaseIterable, Sendable { case system, light, dark }

protocol PreferencesServiceProtocol: AnyObject, Sendable {
    var theme: AppTheme { get set }
    var sortOrder: NoteSortOrder { get set }
    var isBiometricsEnabled: Bool { get set }
}

// AppStorage-backed implementation — thread-safe because @AppStorage is main actor
@MainActor
final class PreferencesService: PreferencesServiceProtocol {
    @AppStorage("theme")            var theme: AppTheme = .system
    @AppStorage("sortOrder")        var sortOrder: NoteSortOrder = .newestFirst
    @AppStorage("biometricsEnabled") var isBiometricsEnabled: Bool = false
}

// In-memory mock for tests — no UserDefaults side effects
@MainActor
final class MockPreferencesService: PreferencesServiceProtocol {
    var theme: AppTheme = .system
    var sortOrder: NoteSortOrder = .newestFirst
    var isBiometricsEnabled: Bool = false
}

// KeychainService.swift
import Security
import Foundation

// ★ Protocol enables testing without real Keychain (not available in simulators reliably)
protocol KeychainServiceProtocol: Sendable {
    func save(key: String, value: String) throws
    func read(key: String) throws -> String?
    func delete(key: String) throws
}

enum KeychainError: Error, Equatable {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case unexpectedData
}

// Keychain wrapper — simple, Sendable (no mutable state)
struct KeychainService: KeychainServiceProtocol {

    func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrAccount:     key,
            kSecValueData:       data,
            kSecAttrAccessible:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)  // delete before re-add
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
    }

    func read(key: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass:         kSecClassGenericPassword,
            kSecAttrAccount:   key,
            kSecReturnData:    true,
            kSecMatchLimit:    kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return nil }
            throw KeychainError.readFailed(status)
        }

        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw KeychainError.unexpectedData }

        return value
    }

    func delete(key: String) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

// In-memory mock — no Security.framework dependency
final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private var store: [String: String] = [:]
    private(set) var saveCallCount = 0
    private(set) var readCallCount = 0
    var stubbedError: KeychainError? = nil

    func save(key: String, value: String) throws {
        if let error = stubbedError { throw error }
        saveCallCount += 1
        store[key] = value
    }

    func read(key: String) throws -> String? {
        if let error = stubbedError { throw error }
        readCallCount += 1
        return store[key]
    }

    func delete(key: String) throws {
        store[key] = nil
    }
}
```

---

## Step 4 — ViewModels with `send(_:)` (~10 min)

```swift
// NoteListViewModel.swift
import Observation

enum NoteListAction: Sendable {
    case load
    case create
    case delete(id: UUID)
    case togglePin(id: UUID)
    case selectNote(NoteSnapshot)
    case updateSearchQuery(String)
    case setSortOrder(NoteSortOrder)
}

struct NoteListState: Equatable {
    enum Phase: Equatable {
        case loading
        case loaded([NoteSnapshot])
        case empty
        case error(String)
    }
    var phase: Phase            = .loading
    var searchQuery: String     = ""
    var sortOrder: NoteSortOrder = .newestFirst
    var isSearching: Bool       { !searchQuery.isEmpty }
}

@MainActor
@Observable
final class NoteListViewModel {

    private(set) var state = NoteListState()
    var onNoteSelected: ((NoteSnapshot) -> Void)?   // coordinator hook
    var onCreateNote: ((NoteSnapshot) -> Void)?     // coordinator hook

    private let repository: any NoteRepositoryProtocol

    init(repository: any NoteRepositoryProtocol) {
        self.repository = repository
    }

    func send(_ action: NoteListAction) {
        switch action {
        case .load:                            load()
        case .create:                          create()
        case .delete(let id):                  delete(id: id)
        case .togglePin(let id):               togglePin(id: id)
        case .selectNote(let note):            onNoteSelected?(note)
        case .updateSearchQuery(let q):        updateSearch(query: q)
        case .setSortOrder(let order):         setSortOrder(order)
        }
    }

    // MARK: - Private handlers

    private func load() {
        do {
            let notes = try state.isSearching
                ? repository.search(query: state.searchQuery)
                : repository.fetchAll(sortedBy: state.sortOrder)
            state.phase = notes.isEmpty ? .empty : .loaded(notes)
        } catch {
            state.phase = .error(error.localizedDescription)
        }
    }

    private func create() {
        do {
            let note = try repository.create(title: "", body: "", tags: [])
            onCreateNote?(note)   // coordinator navigates to editor
        } catch {
            state.phase = .error(error.localizedDescription)
        }
    }

    private func delete(id: UUID) {
        do {
            try repository.delete(id: id)
            load()
        } catch {
            state.phase = .error(error.localizedDescription)
        }
    }

    private func togglePin(id: UUID) {
        do {
            guard var note = try repository.fetch(id: id) else { return }
            note.isPinned.toggle()
            try repository.update(note)
            load()
        } catch {
            state.phase = .error(error.localizedDescription)
        }
    }

    private func updateSearch(query: String) {
        state.searchQuery = query
        load()
    }

    private func setSortOrder(_ order: NoteSortOrder) {
        state.sortOrder = order
        load()
    }
}

// NoteEditorViewModel.swift
enum NoteEditorAction: Sendable {
    case load
    case updateTitle(String)
    case updateBody(String)
    case addTag(String)
    case removeTag(String)
    case save
    case delete
}

struct NoteEditorState: Equatable {
    var snapshot: NoteSnapshot
    var isDirty: Bool   = false
    var isSaving: Bool  = false
    var error: String?  = nil
}

@MainActor
@Observable
final class NoteEditorViewModel {

    private(set) var state: NoteEditorState
    var onSave: ((NoteSnapshot) -> Void)?     // coordinator hook
    var onDelete: (() -> Void)?               // coordinator hook

    private let repository: any NoteRepositoryProtocol

    init(note: NoteSnapshot, repository: any NoteRepositoryProtocol) {
        self.state = NoteEditorState(snapshot: note)
        self.repository = repository
    }

    func send(_ action: NoteEditorAction) {
        switch action {
        case .load:                   reload()
        case .updateTitle(let t):     updateTitle(t)
        case .updateBody(let b):      updateBody(b)
        case .addTag(let tag):        addTag(tag)
        case .removeTag(let tag):     removeTag(tag)
        case .save:                   save()
        case .delete:                 delete()
        }
    }

    private func reload() {
        guard let fresh = try? repository.fetch(id: state.snapshot.id) else { return }
        state.snapshot = fresh
        state.isDirty = false
    }

    private func updateTitle(_ title: String) {
        state.snapshot.title = title
        state.isDirty = true
    }

    private func updateBody(_ body: String) {
        state.snapshot.body = body
        state.isDirty = true
    }

    private func addTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !state.snapshot.tags.contains(trimmed) else { return }
        state.snapshot.tags.append(trimmed)
        state.isDirty = true
    }

    private func removeTag(_ tag: String) {
        state.snapshot.tags.removeAll { $0 == tag }
        state.isDirty = true
    }

    private func save() {
        state.isSaving = true
        state.error = nil
        do {
            try repository.update(state.snapshot)
            state.isDirty = false
            state.isSaving = false
            onSave?(state.snapshot)
        } catch {
            state.error = error.localizedDescription
            state.isSaving = false
        }
    }

    private func delete() {
        do {
            try repository.delete(id: state.snapshot.id)
            onDelete?()
        } catch {
            state.error = error.localizedDescription
        }
    }
}

// SettingsViewModel.swift
enum SettingsAction: Sendable {
    case setTheme(AppTheme)
    case setSortOrder(NoteSortOrder)
    case setBiometrics(Bool)
    case savePIN(String)
    case clearPIN
    case loadPINStatus
}

struct SettingsState: Equatable {
    var theme: AppTheme           = .system
    var sortOrder: NoteSortOrder  = .newestFirst
    var isBiometricsEnabled: Bool = false
    var hasPIN: Bool              = false
    var pinError: String?         = nil
}

@MainActor
@Observable
final class SettingsViewModel {

    private(set) var state = SettingsState()
    private let preferences: any PreferencesServiceProtocol
    private let keychain: any KeychainServiceProtocol
    private let pinKey = "com.notekeeper.pin"

    init(
        preferences: any PreferencesServiceProtocol,
        keychain: any KeychainServiceProtocol = KeychainService()
    ) {
        self.preferences = preferences
        self.keychain = keychain
    }

    func send(_ action: SettingsAction) {
        switch action {
        case .setTheme(let t):       setTheme(t)
        case .setSortOrder(let o):   setSortOrder(o)
        case .setBiometrics(let on): setBiometrics(on)
        case .savePIN(let pin):      savePIN(pin)
        case .clearPIN:              clearPIN()
        case .loadPINStatus:         loadPINStatus()
        }
    }

    private func setTheme(_ theme: AppTheme) {
        preferences.theme = theme
        state.theme = theme
    }

    private func setSortOrder(_ order: NoteSortOrder) {
        preferences.sortOrder = order
        state.sortOrder = order
    }

    private func setBiometrics(_ enabled: Bool) {
        preferences.isBiometricsEnabled = enabled
        state.isBiometricsEnabled = enabled
    }

    private func savePIN(_ pin: String) {
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else {
            state.pinError = "PIN must be 4 digits"
            return
        }
        do {
            try keychain.save(key: pinKey, value: pin)
            state.hasPIN = true
            state.pinError = nil
        } catch {
            state.pinError = error.localizedDescription
        }
    }

    private func clearPIN() {
        try? keychain.delete(key: pinKey)
        state.hasPIN = false
        state.pinError = nil
    }

    private func loadPINStatus() {
        state.theme = preferences.theme
        state.sortOrder = preferences.sortOrder
        state.isBiometricsEnabled = preferences.isBiometricsEnabled
        state.hasPIN = (try? keychain.read(key: pinKey)) != nil
    }
}
```

---

## Step 5 — Modular views (~10 min)

```swift
// NoteRowView.swift
import SwiftUI

struct NoteRowView: View {
    let note: NoteSnapshot
    let onTap: () -> Void
    let onPin: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(note.body.isEmpty ? "No content" : note.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(note.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(note.tags.prefix(2), id: \.self) { tag in
                        TagChipView(tag: tag)
                    }
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .swipeActions(edge: .leading) {
            Button { onPin() } label: {
                Label(note.isPinned ? "Unpin" : "Pin", systemImage: "pin")
            }
            .tint(.orange)
        }
    }
}

// TagChipView.swift
struct TagChipView: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

// NoteSearchBar.swift
struct NoteSearchBar: View {
    let query: String
    let onQueryChanged: (String) -> Void

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search notes…", text: Binding(
                get: { query },
                set: { onQueryChanged($0) }
            ))
            .autocorrectionDisabled()
        }
        .padding(10)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

// SortOrderPicker.swift
struct SortOrderPicker: View {
    let currentOrder: NoteSortOrder
    let onSelect: (NoteSortOrder) -> Void

    var body: some View {
        Menu {
            ForEach(NoteSortOrder.allCases, id: \.self) { order in
                Button {
                    onSelect(order)
                } label: {
                    if order == currentOrder {
                        Label(order.rawValue, systemImage: "checkmark")
                    } else {
                        Text(order.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}

// NoteListView.swift — root list view
struct NoteListView: View {
    @State var vm: NoteListViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NoteSearchBar(
                    query: vm.state.searchQuery,
                    onQueryChanged: { vm.send(.updateSearchQuery($0)) }
                )
                .padding(.vertical, 8)

                listContent
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { vm.send(.create) } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    SortOrderPicker(
                        currentOrder: vm.state.sortOrder,
                        onSelect: { vm.send(.setSortOrder($0)) }
                    )
                }
            }
            .task { vm.send(.load) }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        switch vm.state.phase {
        case .loading:
            ProgressView()
        case .empty:
            emptyState
        case .error(let msg):
            ContentUnavailableView(msg, systemImage: "exclamationmark.triangle")
        case .loaded(let notes):
            List {
                ForEach(notes) { note in
                    NoteRowView(
                        note: note,
                        onTap: { vm.send(.selectNote(note)) },
                        onPin: { vm.send(.togglePin(id: note.id)) }
                    )
                }
                .onDelete { indexSet in
                    if case .loaded(let notes) = vm.state.phase {
                        indexSet.forEach { vm.send(.delete(id: notes[$0].id)) }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            vm.state.isSearching ? "No matches" : "No Notes",
            systemImage: vm.state.isSearching ? "magnifyingglass" : "note.text",
            description: Text(vm.state.isSearching ? "Try a different search" : "Tap + to create your first note")
        )
    }
}

// NoteEditorView.swift
struct NoteEditorView: View {
    @State var vm: NoteEditorViewModel
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoteEditorTitleField(
                title: vm.state.snapshot.title,
                isFocused: $isTitleFocused,
                onUpdate: { vm.send(.updateTitle($0)) }
            )
            Divider()
            TextEditor(text: Binding(
                get: { vm.state.snapshot.body },
                set: { vm.send(.updateBody($0)) }
            ))
            .font(.body)
            .padding(.horizontal)

            NoteTagsView(
                tags: vm.state.snapshot.tags,
                onAdd: { vm.send(.addTag($0)) },
                onRemove: { vm.send(.removeTag($0)) }
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if vm.state.isSaving {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button("Save") { vm.send(.save) }
                        .disabled(!vm.state.isDirty)
                        .bold()
                }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete", role: .destructive) { vm.send(.delete) }
            }
        }
        .task { vm.send(.load) }
        .onDisappear {
            if vm.state.isDirty { vm.send(.save) }   // auto-save on back
        }
    }
}

// NoteEditorTitleField.swift
struct NoteEditorTitleField: View {
    let title: String
    var isFocused: FocusState<Bool>.Binding
    let onUpdate: (String) -> Void

    var body: some View {
        TextField("Title", text: Binding(get: { title }, set: onUpdate))
            .font(.title2.bold())
            .padding()
            .focused(isFocused)
    }
}

// NoteTagsView.swift
struct NoteTagsView: View {
    let tags: [String]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void

    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 2) {
                            TagChipView(tag: tag)
                            Button { onRemove(tag) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    TextField("Add tag…", text: $newTag)
                        .font(.caption)
                        .frame(width: 80)
                        .onSubmit {
                            onAdd(newTag)
                            newTag = ""
                        }
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 8)
    }
}

// PINSetupView.swift — secure entry
struct PINSetupView: View {
    @State private var pin = ""
    let onSave: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Enter a 4-digit PIN").font(.headline)

                // ★ Use .numberPad + SecureField for PIN entry
                SecureField("PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.title)
                    .frame(width: 120)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: pin) {
                        if pin.count > 4 { pin = String(pin.prefix(4)) }
                    }

                Button("Save PIN") { onSave(pin) }
                    .buttonStyle(.borderedProminent)
                    .disabled(pin.count != 4)
            }
            .navigationTitle("Set PIN")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
```

---

## Step 6 — App entry + SwiftData container setup (~5 min)

```swift
// NoteKeeperApp.swift
import SwiftUI
import SwiftData

@main
struct NoteKeeperApp: App {

    // ★ .modelContainer sets up the SQLite store and provides ModelContext to the hierarchy
    var body: some Scene {
        WindowGroup {
            NoteKeeperRootView()
        }
        .modelContainer(for: Note.self)
    }
}

// NoteKeeperRootView.swift
struct NoteKeeperRootView: View {
    // ★ @Environment(\.modelContext) gives access to the container's context
    @Environment(\.modelContext) private var modelContext
    @State private var listVM: NoteListViewModel?

    var body: some View {
        if let vm = listVM {
            NoteListView(vm: vm)
        } else {
            ProgressView()
                .task {
                    let repo = SwiftDataNoteRepository(context: modelContext)
                    listVM = NoteListViewModel(repository: repo)
                }
        }
    }
}

// MARK: - SwiftData migration strategy (versioned schema)

// ★ When you add/change model properties, use VersionedSchema + SchemaMigrationPlan
// This is the interview-level answer for "how do you handle schema changes?"

enum NoteSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Note.self] }

    @Model final class Note { /* original schema */ }
}

enum NoteSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Note.self] }

    @Model final class Note {
        // ★ Added `priority` in v2
        var priority: Int = 0
    }
}

enum NoteMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [NoteSchemaV1.self, NoteSchemaV2.self] }

    static var stages: [MigrationStage] {
        [
            // Lightweight migration — SwiftData handles it automatically if:
            // - You only add optional properties
            // - You only rename properties (with originalName:)
            .lightweight(fromVersion: NoteSchemaV1.self, toVersion: NoteSchemaV2.self)

            // Custom migration — run Swift code to transform data:
            // .custom(fromVersion:toVersion:willMigrate:didMigrate:)
        ]
    }
}
```

---

## Step 7 — Swift Testing suite (~10 min)

```swift
// NoteListViewModelTests.swift
import Testing
@testable import NoteKeeper

// In-memory repository — synchronous, no SwiftData, no SQLite
@MainActor
final class InMemoryNoteRepository: NoteRepositoryProtocol {
    private var notes: [UUID: NoteSnapshot] = [:]
    private(set) var deleteCallCount = 0
    private(set) var updateCallCount = 0
    var stubbedError: Error? = nil

    func fetchAll(sortedBy: NoteSortOrder) throws -> [NoteSnapshot] {
        if let error = stubbedError { throw error }
        return Array(notes.values).sorted { $0.createdAt > $1.createdAt }
    }

    func fetch(id: UUID) throws -> NoteSnapshot? { notes[id] }

    func create(title: String, body: String, tags: [String]) throws -> NoteSnapshot {
        if let error = stubbedError { throw error }
        let note = NoteSnapshot(
            id: UUID(), title: title, body: body,
            createdAt: .now, updatedAt: .now, isPinned: false, tags: tags
        )
        notes[note.id] = note
        return note
    }

    func update(_ snapshot: NoteSnapshot) throws {
        if let error = stubbedError { throw error }
        updateCallCount += 1
        notes[snapshot.id] = snapshot
    }

    func delete(id: UUID) throws {
        if let error = stubbedError { throw error }
        deleteCallCount += 1
        notes[id] = nil
    }

    func search(query: String) throws -> [NoteSnapshot] {
        notes.values.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.body.localizedCaseInsensitiveContains(query)
        }
    }

    // Test helper
    func seed(count: Int = 3) {
        for i in 0..<count {
            let id = UUID()
            notes[id] = NoteSnapshot(
                id: id, title: "Note \(i)", body: "Body \(i)",
                createdAt: .now, updatedAt: .now, isPinned: false, tags: []
            )
        }
    }
}

@Suite("NoteListViewModel")
struct NoteListViewModelTests {

    @MainActor
    private func makeVM(seeded: Int = 0) -> (NoteListViewModel, InMemoryNoteRepository) {
        let repo = InMemoryNoteRepository()
        if seeded > 0 { repo.seed(count: seeded) }
        let vm = NoteListViewModel(repository: repo)
        return (vm, repo)
    }

    @Test @MainActor
    func loadWithNotesTransitionsToLoaded() {
        let (vm, _) = makeVM(seeded: 3)
        vm.send(.load)
        if case .loaded(let notes) = vm.state.phase {
            #expect(notes.count == 3)
        } else {
            Issue.record("Expected .loaded")
        }
    }

    @Test @MainActor
    func loadWithNoNotesTransitionsToEmpty() {
        let (vm, _) = makeVM()
        vm.send(.load)
        #expect(vm.state.phase == .empty)
    }

    @Test @MainActor
    func createFiresCoordinatorCallback() {
        let (vm, _) = makeVM()
        var createdNote: NoteSnapshot?
        vm.onCreateNote = { createdNote = $0 }
        vm.send(.create)
        #expect(createdNote != nil)
    }

    @Test @MainActor
    func deleteRemovesNoteAndReloads() {
        let (vm, repo) = makeVM(seeded: 2)
        vm.send(.load)
        if case .loaded(let notes) = vm.state.phase {
            vm.send(.delete(id: notes[0].id))
            #expect(repo.deleteCallCount == 1)
            if case .loaded(let remaining) = vm.state.phase {
                #expect(remaining.count == 1)
            }
        }
    }

    @Test @MainActor
    func togglePinFlipsPinnedState() {
        let (vm, repo) = makeVM(seeded: 1)
        vm.send(.load)
        if case .loaded(let notes) = vm.state.phase {
            let initial = notes[0].isPinned
            vm.send(.togglePin(id: notes[0].id))
            #expect(repo.updateCallCount == 1)
            if case .loaded(let updated) = vm.state.phase {
                #expect(updated[0].isPinned == !initial)
            }
        }
    }

    @Test @MainActor
    func searchQueryFiltersResults() {
        let (vm, repo) = makeVM()
        var note = NoteSnapshot(
            id: UUID(), title: "Swift Testing Guide", body: "",
            createdAt: .now, updatedAt: .now, isPinned: false, tags: []
        )
        try? repo.update(note)  // seed manually
        _ = try? repo.create(title: "Swift Testing Guide", body: "", tags: [])

        vm.send(.updateSearchQuery("Swift"))
        if case .loaded(let results) = vm.state.phase {
            #expect(results.allSatisfy {
                $0.title.localizedCaseInsensitiveContains("Swift")
            })
        }
    }

    @Test @MainActor
    func errorInRepositoryTransitionsToErrorPhase() {
        let (vm, repo) = makeVM()
        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "DB corrupted" }
        }
        repo.stubbedError = TestError()
        vm.send(.load)
        if case .error(let msg) = vm.state.phase {
            #expect(msg == "DB corrupted")
        } else {
            Issue.record("Expected .error phase")
        }
    }
}

@Suite("NoteEditorViewModel")
struct NoteEditorViewModelTests {

    @MainActor
    private func makeVM() -> (NoteEditorViewModel, InMemoryNoteRepository) {
        let repo = InMemoryNoteRepository()
        let note = (try? repo.create(title: "Original", body: "Body", tags: []))!
        let vm = NoteEditorViewModel(note: note, repository: repo)
        return (vm, repo)
    }

    @Test @MainActor
    func updateTitleMarksDirty() {
        let (vm, _) = makeVM()
        #expect(!vm.state.isDirty)
        vm.send(.updateTitle("New Title"))
        #expect(vm.state.isDirty)
        #expect(vm.state.snapshot.title == "New Title")
    }

    @Test @MainActor
    func updateBodyMarksDirty() {
        let (vm, _) = makeVM()
        vm.send(.updateBody("New body content"))
        #expect(vm.state.isDirty)
    }

    @Test @MainActor
    func addTagAppendsUniqueTag() {
        let (vm, _) = makeVM()
        vm.send(.addTag("swift"))
        vm.send(.addTag("swift"))   // duplicate — should be ignored
        #expect(vm.state.snapshot.tags == ["swift"])
    }

    @Test @MainActor
    func removeTagDeletesIt() {
        let (vm, _) = makeVM()
        vm.send(.addTag("swift"))
        vm.send(.addTag("ios"))
        vm.send(.removeTag("swift"))
        #expect(vm.state.snapshot.tags == ["ios"])
    }

    @Test @MainActor
    func savePersistsToRepositoryAndClearsDirty() {
        let (vm, repo) = makeVM()
        vm.send(.updateTitle("Saved Title"))
        vm.send(.save)
        #expect(!vm.state.isDirty)
        #expect(repo.updateCallCount == 1)
    }

    @Test @MainActor
    func saveFiresCoordinatorCallback() {
        let (vm, _) = makeVM()
        var savedNote: NoteSnapshot?
        vm.onSave = { savedNote = $0 }
        vm.send(.updateTitle("Test"))
        vm.send(.save)
        #expect(savedNote?.title == "Test")
    }

    @Test @MainActor
    func deleteFiresCoordinatorCallback() {
        let (vm, _) = makeVM()
        var deleteCalled = false
        vm.onDelete = { deleteCalled = true }
        vm.send(.delete)
        #expect(deleteCalled)
    }
}

@Suite("SettingsViewModel")
struct SettingsViewModelTests {

    @MainActor
    private func makeVM() -> (SettingsViewModel, MockPreferencesService, MockKeychainService) {
        let prefs = MockPreferencesService()
        let keychain = MockKeychainService()
        let vm = SettingsViewModel(preferences: prefs, keychain: keychain)
        return (vm, prefs, keychain)
    }

    @Test @MainActor
    func setThemeUpdatesPreferencesAndState() {
        let (vm, prefs, _) = makeVM()
        vm.send(.setTheme(.dark))
        #expect(vm.state.theme == .dark)
        #expect(prefs.theme == .dark)
    }

    @Test @MainActor
    func savePINPersistsToKeychain() {
        let (vm, _, keychain) = makeVM()
        vm.send(.savePIN("1234"))
        #expect(vm.state.hasPIN)
        #expect(keychain.saveCallCount == 1)
        #expect(vm.state.pinError == nil)
    }

    @Test @MainActor
    func invalidPINShowsError() {
        let (vm, _, keychain) = makeVM()
        vm.send(.savePIN("12"))    // too short
        #expect(!vm.state.hasPIN)
        #expect(vm.state.pinError != nil)
        #expect(keychain.saveCallCount == 0)
    }

    @Test @MainActor
    func nonNumericPINShowsError() {
        let (vm, _, keychain) = makeVM()
        vm.send(.savePIN("12ab"))
        #expect(vm.state.pinError != nil)
        #expect(keychain.saveCallCount == 0)
    }

    @Test @MainActor
    func clearPINRemovesFlag() {
        let (vm, _, _) = makeVM()
        vm.send(.savePIN("1234"))
        vm.send(.clearPIN)
        #expect(!vm.state.hasPIN)
        #expect(vm.state.pinError == nil)
    }

    @Test @MainActor
    func keychainErrorPropagatesAsMessage() {
        let (vm, _, keychain) = makeVM()
        keychain.stubbedError = .saveFailed(-25293)
        vm.send(.savePIN("1234"))
        #expect(vm.state.pinError != nil)
        #expect(!vm.state.hasPIN)
    }
}

@Suite("KeychainService (unit — mock)")
struct KeychainServiceTests {

    @Test
    func saveAndReadRoundtrip() throws {
        let keychain = MockKeychainService()
        try keychain.save(key: "test", value: "secret")
        let result = try keychain.read(key: "test")
        #expect(result == "secret")
    }

    @Test
    func readMissingKeyReturnsNil() throws {
        let keychain = MockKeychainService()
        let result = try keychain.read(key: "nonexistent")
        #expect(result == nil)
    }

    @Test
    func deleteRemovesValue() throws {
        let keychain = MockKeychainService()
        try keychain.save(key: "test", value: "value")
        try keychain.delete(key: "test")
        let result = try keychain.read(key: "test")
        #expect(result == nil)
    }

    @Test
    func stubbedErrorThrowsOnSave() {
        let keychain = MockKeychainService()
        keychain.stubbedError = .saveFailed(-1)
        #expect(throws: KeychainError.self) {
            try keychain.save(key: "k", value: "v")
        }
    }
}
```

---

## CoreData vs SwiftData comparison (interview cheat sheet)

```
                    CoreData            SwiftData
─────────────────────────────────────────────────────────
Minimum iOS         iOS 3               iOS 17
Language            ObjC heritage       Pure Swift
Model definition    .xcdatamodeld       @Model macro
Fetch               NSFetchRequest      #Predicate / @Query
Context             NSManagedObjectContext  ModelContext
Thread safety       ⚠️ context-bound     ⚠️ still context-bound
Migrations          NSMigrationPolicy   SchemaMigrationPlan
CloudKit sync       NSPersistentCloud   .cloudKitDatabase()
ObservableObject    manual @Published   automatic with @Model
Sendable            ❌ (NSManagedObject) ❌ (copy to value type)
Testing             in-memory store     in-memory store
```

**When to still use CoreData in 2025:**
- Complex custom migration logic with `NSMigrationPolicy`
- Existing large CoreData codebase (migration cost)
- Complex multi-context concurrency (background save + main read)
- NSFetchedResultsController-powered UITableView

**SwiftData gotcha to know for interviews:**
`@Model` objects are NOT `Sendable`. Never pass them across actor boundaries. Copy to a value-type snapshot first (as shown with `NoteSnapshot` above).

---

## Key concepts to remember

**`@Model` macro generates:** `PersistentModel` conformance, change tracking, relationship management, `#Predicate` support — all from a single annotation.

**`ModelContext` is `@MainActor`-bound.** For background work, use a new context: `modelContainer.mainContext` for reads, `ModelContext(modelContainer)` for background writes.

**`#Predicate` is type-safe:** Unlike `NSPredicate(format:)` strings, `#Predicate { $0.title == "x" }` is checked by the compiler. Typos don't compile.

**`@AppStorage` keys as constants:** Never use raw strings. Define a `StorageKeys` enum:
```swift
enum StorageKeys {
    static let theme = "theme"
    static let sortOrder = "sortOrder"
}
```

**Keychain is device-bound:** `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` means the item can't be restored from iCloud backup — correct for PINs. Use `kSecAttrAccessible` (without `ThisDeviceOnly`) for tokens that should survive device restore.

---

## Follow-up questions

- *How do you test SwiftData without hitting disk?* (Pass an in-memory configuration: `ModelConfiguration(isStoredInMemoryOnly: true)`, or use `InMemoryNoteRepository` as shown above — no SwiftData at all)
- *How does SwiftData handle relationships?* (`@Relationship(deleteRule: .cascade)` — SwiftData manages the inverse automatically; CoreData required you to set both sides)
- *What's the difference between `@Query` and fetching manually?* (`@Query` is a SwiftUI property wrapper that live-updates the view when data changes; manual fetch is a one-shot call — use `@Query` in views, manual fetch in ViewModels)
- *How would you handle concurrent writes?* (Create a detached `Task` with its own `ModelContext(container)`, perform writes, call `try context.save()` — never share a context across actors)
- *Why is `NoteSnapshot` a struct instead of passing `Note` directly?* (SwiftData `@Model` objects are reference types tied to a `ModelContext`. They can't cross actor boundaries. Converting to a value type at the boundary is the correct isolation pattern in Swift 6.)
