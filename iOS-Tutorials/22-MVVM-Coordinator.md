# Tutorial 22 — MVVM + Coordinator Navigation
## Build: TaskFlow — a task manager with clean navigation architecture
**Time:** 45 min | **Swift 6 + SwiftUI** | **Topics:** Coordinator pattern, `send(_:)` dispatch, ViewModel protocols, feature isolation, Swift Testing

---

## Architecture overview

```
AppCoordinator
└── TaskCoordinator         ← owns NavigationPath, creates VMs via factories
    ├── TaskListView        ← displays state, calls vm.send(_:)
    ├── TaskDetailView      ← displays state, calls vm.send(_:)
    └── EditTaskView        ← displays state, calls vm.send(_:)
```

**The rule: ViewModels never navigate. They fire actions. Coordinators respond.**

---

## Why coordinator?

| Without | With |
|---|---|
| VM calls `router.push(.detail(id))` | VM fires `.didSelectTask(id)` — coordinator decides |
| VM imports navigation types | VM has zero navigation imports |
| Hard to reuse screen in different flow | Coordinator wires the same VM differently |
| A/B testing a flow changes VMs | Swap the coordinator only |

---

## Step 1 — Model + service protocol (~5 min)

```swift
// TodoTask.swift
import Foundation

struct TodoTask: Identifiable, Sendable, Hashable {
    let id: UUID
    var title: String
    var isCompleted: Bool

    static func make(title: String) -> TodoTask {
        TodoTask(id: UUID(), title: title, isCompleted: false)
    }
}

// TaskServiceProtocol.swift
// ★ Protocol = swap real store for MockTaskService in tests
protocol TaskServiceProtocol: AnyObject, Sendable {
    func fetchAll() -> [TodoTask]
    func add(title: String) -> TodoTask
    func update(_ task: TodoTask)
    func delete(id: UUID)
    func toggle(id: UUID)
}

// In-memory store — swap for CoreData or network in production
@MainActor
final class TaskService: TaskServiceProtocol {
    static let shared = TaskService()
    private var tasks: [TodoTask] = [
        TodoTask(id: UUID(), title: "Review pull request",   isCompleted: false),
        TodoTask(id: UUID(), title: "Write unit tests",      isCompleted: true),
        TodoTask(id: UUID(), title: "Update documentation",  isCompleted: false),
    ]

    func fetchAll() -> [TodoTask] { tasks }

    func add(title: String) -> TodoTask {
        let task = TodoTask.make(title: title)
        tasks.insert(task, at: 0)
        return task
    }

    func update(_ task: TodoTask) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i] = task
    }

    func delete(id: UUID) { tasks.removeAll { $0.id == id } }

    func toggle(id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].isCompleted.toggle()
    }
}

@MainActor
final class MockTaskService: TaskServiceProtocol {
    var tasks: [TodoTask] = []
    private(set) var addedTitles: [String] = []
    private(set) var deletedIDs: [UUID] = []
    private(set) var toggledIDs: [UUID] = []

    func fetchAll() -> [TodoTask] { tasks }

    func add(title: String) -> TodoTask {
        addedTitles.append(title)
        let task = TodoTask.make(title: title)
        tasks.insert(task, at: 0)
        return task
    }

    func update(_ task: TodoTask) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i] = task
    }

    func delete(id: UUID) {
        deletedIDs.append(id)
        tasks.removeAll { $0.id == id }
    }

    func toggle(id: UUID) {
        toggledIDs.append(id)
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].isCompleted.toggle()
    }
}
```

---

## Step 2 — ViewModels with `send(_:)` and typed action enums (~10 min)

```swift
// TaskListViewModel.swift
import Observation

// ★ Actions = all user intents; exhaustive, discoverable, testable
enum TaskListAction: Sendable {
    case load
    case toggleTask(TodoTask)
    case deleteTask(TodoTask)
    case selectTask(TodoTask)    // fires coordinator action — no nav code here
    case tapAddTask              // fires coordinator action — no nav code here
}

struct TaskListState: Equatable {
    enum Phase: Equatable {
        case loading
        case loaded([TodoTask])
        case empty
    }
    var phase: Phase = .loading
}

@MainActor
protocol TaskListViewModelProtocol: AnyObject {
    var state: TaskListState { get }
    func send(_ action: TaskListAction)
}

@MainActor
@Observable
final class TaskListViewModel: TaskListViewModelProtocol {

    private(set) var state = TaskListState()
    var onAction: ((TaskListAction) -> Void)?   // coordinator subscribes here
    private let service: any TaskServiceProtocol

    init(service: any TaskServiceProtocol = TaskService.shared) {
        self.service = service
    }

    func send(_ action: TaskListAction) {
        switch action {
        case .load:                   load()
        case .toggleTask(let task):   toggleTask(task)
        case .deleteTask(let task):   deleteTask(task)
        case .selectTask(let task):   onAction?(.selectTask(task))
        case .tapAddTask:             onAction?(.tapAddTask)
        }
    }

    private func load() {
        let tasks = service.fetchAll()
        state.phase = tasks.isEmpty ? .empty : .loaded(tasks)
    }

    private func toggleTask(_ task: TodoTask) {
        service.toggle(id: task.id)
        load()
    }

    private func deleteTask(_ task: TodoTask) {
        service.delete(id: task.id)
        load()
    }
}

// TaskDetailViewModel.swift
enum TaskDetailAction: Sendable {
    case toggleComplete
    case tapEdit(TodoTask)          // coordinator action
    case tapDelete(TodoTask)        // coordinator action
}

struct TaskDetailState: Equatable {
    var task: TodoTask
}

@MainActor
protocol TaskDetailViewModelProtocol: AnyObject {
    var state: TaskDetailState { get }
    func send(_ action: TaskDetailAction)
}

@MainActor
@Observable
final class TaskDetailViewModel: TaskDetailViewModelProtocol {

    private(set) var state: TaskDetailState
    var onAction: ((TaskDetailAction) -> Void)?
    private let service: any TaskServiceProtocol

    init(task: TodoTask, service: any TaskServiceProtocol = TaskService.shared) {
        self.state = TaskDetailState(task: task)
        self.service = service
    }

    func send(_ action: TaskDetailAction) {
        switch action {
        case .toggleComplete:        toggleComplete()
        case .tapEdit(let task):     onAction?(.tapEdit(task))
        case .tapDelete(let task):
            service.delete(id: task.id)
            onAction?(.tapDelete(task))
        }
    }

    private func toggleComplete() {
        service.toggle(id: state.task.id)
        if let updated = service.fetchAll().first(where: { $0.id == state.task.id }) {
            state.task = updated
        }
    }
}

// EditTaskViewModel.swift
enum EditTaskAction: Sendable {
    case updateTitle(String)
    case save
    case cancel
}

struct EditTaskState: Equatable {
    var title: String
    var isEditMode: Bool
    var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }
}

@MainActor
protocol EditTaskViewModelProtocol: AnyObject {
    var state: EditTaskState { get }
    func send(_ action: EditTaskAction)
}

@MainActor
@Observable
final class EditTaskViewModel: EditTaskViewModelProtocol {

    private(set) var state: EditTaskState
    var onAction: ((EditTaskAction) -> Void)?
    private let existingTask: TodoTask?
    private let service: any TaskServiceProtocol

    init(service: any TaskServiceProtocol = TaskService.shared) {
        self.existingTask = nil
        self.state = EditTaskState(title: "", isEditMode: false)
        self.service = service
    }

    init(task: TodoTask, service: any TaskServiceProtocol = TaskService.shared) {
        self.existingTask = task
        self.state = EditTaskState(title: task.title, isEditMode: true)
        self.service = service
    }

    func send(_ action: EditTaskAction) {
        switch action {
        case .updateTitle(let t): state.title = t
        case .save:               save()
        case .cancel:             onAction?(.cancel)
        }
    }

    private func save() {
        guard state.canSave else { return }
        if var existing = existingTask {
            existing.title = state.title
            service.update(existing)
        } else {
            _ = service.add(title: state.title)
        }
        onAction?(.save)
    }
}
```

---

## Step 3 — Coordinator: owns navigation, wires VMs (~10 min)

```swift
// TaskCoordinator.swift
import SwiftUI

@MainActor
@Observable
final class TaskCoordinator {

    enum Route: Hashable {
        case detail(TodoTask)
    }

    var path = NavigationPath()
    var editingTask: TodoTask? = nil
    var isCreating = false

    private let service: any TaskServiceProtocol

    init(service: any TaskServiceProtocol = TaskService.shared) {
        self.service = service
    }

    // MARK: - VM Factories
    // ★ Each factory creates the VM AND wires up action handling
    // ★ [weak self] prevents retain cycle (coordinator → closure → coordinator)

    func makeListViewModel() -> TaskListViewModel {
        let vm = TaskListViewModel(service: service)
        vm.onAction = { [weak self] action in
            switch action {
            case .selectTask(let task): self?.path.append(Route.detail(task))
            case .tapAddTask:           self?.isCreating = true
            default:                    break   // handled inside VM
            }
        }
        return vm
    }

    func makeDetailViewModel(for task: TodoTask) -> TaskDetailViewModel {
        let vm = TaskDetailViewModel(task: task, service: service)
        vm.onAction = { [weak self] action in
            switch action {
            case .tapEdit(let task): self?.editingTask = task
            case .tapDelete:         self?.pop()
            default:                 break
            }
        }
        return vm
    }

    func makeEditViewModel(task: TodoTask? = nil) -> EditTaskViewModel {
        let vm = task.map { EditTaskViewModel(task: $0, service: service) }
                 ?? EditTaskViewModel(service: service)
        vm.onAction = { [weak self] action in
            switch action {
            case .save, .cancel: self?.dismissModals()
            default:             break
            }
        }
        return vm
    }

    // MARK: - Navigation

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    private func dismissModals() {
        editingTask = nil
        isCreating = false
    }
}
```

---

## Step 4 — Modular views (~10 min)

```swift
// TaskRowView.swift
import SwiftUI

struct TaskRowView: View {
    let task: TodoTask
    let onToggle: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            Text(task.title)
                .strikethrough(task.isCompleted)
                .foregroundStyle(task.isCompleted ? .secondary : .primary)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .padding(.vertical, 4)
    }
}

// TaskListEmptyView.swift
struct TaskListEmptyView: View {
    let onAdd: () -> Void

    var body: some View {
        ContentUnavailableView(
            "No Tasks",
            systemImage: "checkmark.circle",
            description: Text("Tap + to add your first task")
        )
    }
}

// TaskListView.swift
struct TaskListView: View {
    @State var vm: TaskListViewModel

    var body: some View {
        Group {
            switch vm.state.phase {
            case .loading:
                ProgressView("Loading…")
            case .empty:
                TaskListEmptyView { vm.send(.tapAddTask) }
            case .loaded(let tasks):
                taskList(tasks)
            }
        }
        .navigationTitle("Tasks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { vm.send(.tapAddTask) } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task { vm.send(.load) }
    }

    private func taskList(_ tasks: [TodoTask]) -> some View {
        List {
            ForEach(tasks) { task in
                TaskRowView(
                    task: task,
                    onToggle: { vm.send(.toggleTask(task)) },
                    onSelect: { vm.send(.selectTask(task)) }
                )
            }
            .onDelete { indexSet in
                indexSet.forEach { vm.send(.deleteTask(tasks[$0])) }
            }
        }
    }
}

// TaskDetailStatusView.swift
struct TaskDetailStatusView: View {
    let isCompleted: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Label(
                isCompleted ? "Completed" : "Pending",
                systemImage: isCompleted ? "checkmark.circle.fill" : "circle"
            )
            .foregroundStyle(isCompleted ? .green : .secondary)

            Spacer()

            Button("Toggle", action: onToggle).buttonStyle(.bordered)
        }
        .padding()
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

// TaskDetailView.swift
struct TaskDetailView: View {
    @State var vm: TaskDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TaskDetailStatusView(
                isCompleted: vm.state.task.isCompleted,
                onToggle: { vm.send(.toggleComplete) }
            )
            Spacer()
        }
        .navigationTitle(vm.state.task.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { vm.send(.tapEdit(vm.state.task)) }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete", role: .destructive) {
                    vm.send(.tapDelete(vm.state.task))
                }
            }
        }
    }
}

// EditTaskFormView.swift
struct EditTaskFormView: View {
    let title: String
    let isEditMode: Bool
    let canSave: Bool
    let onTitleChange: (String) -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section("Task") {
                TextField("Title", text: Binding(
                    get: { title },
                    set: { onTitleChange($0) }
                ))
            }
        }
    }
}

// EditTaskView.swift
struct EditTaskView: View {
    @State var vm: EditTaskViewModel

    var body: some View {
        NavigationStack {
            EditTaskFormView(
                title: vm.state.title,
                isEditMode: vm.state.isEditMode,
                canSave: vm.state.canSave,
                onTitleChange: { vm.send(.updateTitle($0)) },
                onSave: { vm.send(.save) },
                onCancel: { vm.send(.cancel) }
            )
            .navigationTitle(vm.state.isEditMode ? "Edit Task" : "New Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { vm.send(.cancel) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { vm.send(.save) }.disabled(!vm.state.canSave)
                }
            }
        }
    }
}
```

---

## Step 5 — Wire coordinator view (~5 min)

```swift
// TaskCoordinatorView.swift
import SwiftUI

struct TaskCoordinatorView: View {
    @State private var coordinator = TaskCoordinator()
    // ★ Store listVM in @State — NavigationStack re-renders root on every path change
    //   Creating inside body would reset its state on every navigation
    @State private var listVM: TaskListViewModel?

    var body: some View {
        @Bindable var coordinator = coordinator

        NavigationStack(path: $coordinator.path) {
            TaskListView(vm: listVM ?? makeListVM())
                .navigationDestination(for: TaskCoordinator.Route.self) { route in
                    switch route {
                    case .detail(let task):
                        TaskDetailView(vm: coordinator.makeDetailViewModel(for: task))
                    }
                }
        }
        .sheet(item: $coordinator.editingTask) { task in
            EditTaskView(vm: coordinator.makeEditViewModel(task: task))
        }
        .sheet(isPresented: $coordinator.isCreating) {
            EditTaskView(vm: coordinator.makeEditViewModel())
        }
    }

    private func makeListVM() -> TaskListViewModel {
        let vm = coordinator.makeListViewModel()
        listVM = vm
        return vm
    }
}
```

---

## Step 6 — Swift Testing suite (~10 min)

```swift
// TaskListViewModelTests.swift
import Testing
@testable import TaskFlow

@Suite("TaskListViewModel")
struct TaskListViewModelTests {

    @MainActor
    private func makeVM(tasks: [TodoTask] = []) -> (TaskListViewModel, MockTaskService) {
        let service = MockTaskService()
        service.tasks = tasks
        let vm = TaskListViewModel(service: service)
        return (vm, service)
    }

    @Test @MainActor
    func loadWithTasksTransitionsToLoaded() {
        let tasks = [TodoTask.make(title: "Test")]
        let (vm, _) = makeVM(tasks: tasks)
        vm.send(.load)
        if case .loaded(let items) = vm.state.phase {
            #expect(items.count == 1)
        } else {
            Issue.record("Expected .loaded phase")
        }
    }

    @Test @MainActor
    func loadWithNoTasksTransitionsToEmpty() {
        let (vm, _) = makeVM(tasks: [])
        vm.send(.load)
        #expect(vm.state.phase == .empty)
    }

    @Test @MainActor
    func toggleTaskCallsServiceAndReloads() {
        let task = TodoTask.make(title: "Test")
        let (vm, service) = makeVM(tasks: [task])
        vm.send(.load)
        vm.send(.toggleTask(task))
        #expect(service.toggledIDs.contains(task.id))
    }

    @Test @MainActor
    func deleteTaskCallsServiceAndReloads() {
        let task = TodoTask.make(title: "Test")
        let (vm, service) = makeVM(tasks: [task])
        vm.send(.load)
        vm.send(.deleteTask(task))
        #expect(service.deletedIDs.contains(task.id))
    }

    @Test @MainActor
    func selectTaskFiresCoordinatorAction() {
        let task = TodoTask.make(title: "Test")
        let (vm, _) = makeVM(tasks: [task])
        var received: TaskListAction?
        vm.onAction = { received = $0 }
        vm.send(.selectTask(task))
        if case .selectTask(let t) = received {
            #expect(t.id == task.id)
        } else {
            Issue.record("Expected selectTask action")
        }
    }

    @Test @MainActor
    func tapAddFiresCoordinatorAction() {
        let (vm, _) = makeVM()
        var received: TaskListAction?
        vm.onAction = { received = $0 }
        vm.send(.tapAddTask)
        if case .tapAddTask = received { } else {
            Issue.record("Expected tapAddTask action")
        }
    }
}

@Suite("EditTaskViewModel")
struct EditTaskViewModelTests {

    @MainActor
    private func makeCreateVM() -> (EditTaskViewModel, MockTaskService) {
        let service = MockTaskService()
        let vm = EditTaskViewModel(service: service)
        return (vm, service)
    }

    @Test @MainActor
    func initialCreateModeState() {
        let (vm, _) = makeCreateVM()
        #expect(vm.state.isEditMode == false)
        #expect(vm.state.title.isEmpty)
        #expect(!vm.state.canSave)
    }

    @Test @MainActor
    func updateTitleEnablesCanSave() {
        let (vm, _) = makeCreateVM()
        vm.send(.updateTitle("New task"))
        #expect(vm.state.canSave)
    }

    @Test @MainActor
    func whitespaceOnlyTitleDisablesCanSave() {
        let (vm, _) = makeCreateVM()
        vm.send(.updateTitle("   "))
        #expect(!vm.state.canSave)
    }

    @Test @MainActor
    func saveDelegatesToServiceAndFiresAction() {
        let (vm, service) = makeCreateVM()
        var actionFired: EditTaskAction?
        vm.onAction = { actionFired = $0 }

        vm.send(.updateTitle("My task"))
        vm.send(.save)

        #expect(service.addedTitles.contains("My task"))
        if case .save = actionFired { } else {
            Issue.record("Expected .save action")
        }
    }

    @Test @MainActor
    func cancelFiresActionWithoutSaving() {
        let (vm, service) = makeCreateVM()
        var actionFired: EditTaskAction?
        vm.onAction = { actionFired = $0 }

        vm.send(.cancel)

        #expect(service.addedTitles.isEmpty)
        if case .cancel = actionFired { } else {
            Issue.record("Expected .cancel action")
        }
    }

    @Test @MainActor
    func editModePrePopulatesTitle() {
        let task = TodoTask.make(title: "Existing task")
        let service = MockTaskService()
        service.tasks = [task]
        let vm = EditTaskViewModel(task: task, service: service)
        #expect(vm.state.title == "Existing task")
        #expect(vm.state.isEditMode)
        #expect(vm.state.canSave)
    }
}

@Suite("TaskCoordinator")
struct TaskCoordinatorTests {

    @Test @MainActor
    func selectTaskPushesRoute() {
        let coordinator = TaskCoordinator(service: MockTaskService())
        let vm = coordinator.makeListViewModel()
        let task = TodoTask.make(title: "Test")

        vm.onAction?(.selectTask(task))

        #expect(!coordinator.path.isEmpty)
    }

    @Test @MainActor
    func tapAddTaskPresentsCreateSheet() {
        let coordinator = TaskCoordinator(service: MockTaskService())
        let vm = coordinator.makeListViewModel()

        vm.onAction?(.tapAddTask)

        #expect(coordinator.isCreating)
    }
}
```

---

## AppCoordinator pattern for multi-feature apps

```swift
// AppCoordinator.swift
@MainActor
@Observable
final class AppCoordinator {

    enum Tab { case tasks, settings }

    var selectedTab: Tab = .tasks

    lazy var taskCoordinator = TaskCoordinator()

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "taskflow" else { return }
        switch url.host {
        case "tasks":
            selectedTab = .tasks
        default:
            break
        }
    }
}

struct AppView: View {
    @State private var appCoordinator = AppCoordinator()

    var body: some View {
        @Bindable var c = appCoordinator
        TabView(selection: $c.selectedTab) {
            TaskCoordinatorView()
                .tabItem { Label("Tasks", systemImage: "checkmark.circle") }
                .tag(AppCoordinator.Tab.tasks)
        }
        .onOpenURL { appCoordinator.handleDeepLink($0) }
    }
}
```

---

## Key concepts to remember

**`send(_:)` is the state machine:** The switch inside `send` is the entire state transition table. It's exhaustive — the compiler guarantees all cases are handled.

**VMs are navigation-blind:** `TaskListViewModel` has no import of SwiftUI. `onAction?(.selectTask(task))` is a data callback — it could push a screen, open a URL, log to analytics, or be ignored in a test.

**`[weak self]` in coordinator closures:** The coordinator holds VMs implicitly (via view `@State`). VMs hold `onAction` closures that capture the coordinator. `weak` breaks the cycle.

**`@State listVM` in coordinator view:** Without storing `listVM` in `@State`, `NavigationStack` recreates it every time `path` changes — resetting all loaded tasks. Store the root VM once.

---

## Follow-up questions

- *How does coordinator differ from a plain `@Observable` Router?* (Coordinator owns VM lifecycle + wires actions. Router is just navigation state. Coordinator is higher-level.)
- *How do you pass data back from a child screen?* (The coordinator's action handler receives it — `case .didSave(let task): parentVM.reload()`)
- *What if you need multiple modals at the same time?* (Track each as separate optional on coordinator: `var sheet1: Route?`, `var sheet2: Route?`)
- *How would you handle auth gating?* (AppCoordinator observes auth state, swaps root between `AuthCoordinatorView` and `MainCoordinatorView` — zero ViewModel changes needed)
