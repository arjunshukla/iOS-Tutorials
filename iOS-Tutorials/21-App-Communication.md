# Tutorial 21 — iOS App-Internal Communication
## Build: CommKit — a living reference app demonstrating every communication pattern
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** @Environment, NotificationCenter, Combine, delegates, callbacks, actor messaging, shared state, @Observable, AsyncStream

---

## What you'll build

A single app that demonstrates 9 communication patterns side-by-side, with a live "signal log" showing which pattern fired each event. By the end you'll know exactly which pattern to reach for in any situation.

---

## The decision map

```
Who needs to know?        →  Pattern

One specific object       →  Direct call / callback closure
One sibling/parent view   →  @Binding or delegate
Any view in a subtree     →  @Environment (dependency injection)
Any view app-wide         →  @Environment at root / shared @Observable
Loosely coupled modules   →  NotificationCenter
Reactive pipelines        →  Combine / AsyncStream
Cross-actor work          →  async/await + actor methods
Persistent user changes   →  @AppStorage / UserDefaults
System → app events       →  NotificationCenter (UIApplication notifications)

Rules of thumb:
  ✓ Prefer the narrowest scope that works
  ✓ @Binding for parent→child two-way
  ✓ @Environment for shared services (auth, analytics, router)
  ✗ Avoid NotificationCenter for flow you can model as a function call
  ✗ Avoid singletons — use @Environment injection instead
```

---

## Project setup

New Xcode project → App → SwiftUI → iOS 17+

---

## Step 1 — Signal log (shared state for this demo) (~5 min)

```swift
// SignalLog.swift
// A shared, observable log so every pattern's events appear in one place

import Observation
import Foundation

@MainActor
@Observable
final class SignalLog {
    struct Entry: Identifiable {
        let id = UUID()
        let pattern: String
        let message: String
        let timestamp: Date = .now
    }

    var entries: [Entry] = []

    func record(_ pattern: String, _ message: String) {
        entries.insert(Entry(pattern: pattern, message: message), at: 0)
        if entries.count > 50 { entries.removeLast() }
    }
}
```

---

## Pattern 1 — @Binding (parent ↔ child two-way sync)

**When:** A child view needs to read AND write a value owned by its parent.
**Scope:** Local — between two views that are directly connected in the hierarchy.

```swift
// BindingDemo.swift
import SwiftUI

// Parent owns the source of truth
struct BindingDemo: View {
    @State private var volume: Double = 0.5   // single source of truth
    @Environment(SignalLog.self) var log

    var body: some View {
        VStack(spacing: 16) {
            Text("Volume: \(Int(volume * 100))%")
                .font(.headline)

            // Child gets a BINDING — it can read and write the parent's value
            // No callback needed — the binding IS the two-way channel
            VolumeSlider(volume: $volume)

            // Another child reading the same binding
            VolumeIndicator(volume: volume)
        }
        .onChange(of: volume) { _, v in
            log.record("@Binding", "Volume changed to \(Int(v * 100))%")
        }
    }
}

struct VolumeSlider: View {
    @Binding var volume: Double

    var body: some View {
        Slider(value: $volume, in: 0...1)
            .tint(.blue)
    }
}

struct VolumeIndicator: View {
    let volume: Double

    var body: some View {
        HStack {
            Image(systemName: volume > 0.5 ? "speaker.wave.3" : "speaker.wave.1")
            ProgressView(value: volume)
                .tint(volume > 0.8 ? .red : .green)
        }
    }
}

// ★ Key insight: @Binding does NOT copy the value — it's a reference wrapper.
// Both VolumeSlider and VolumeIndicator always see the parent's current value.
// Mutation from either child immediately reflects in the parent and all other children.
```

---

## Pattern 2 — @Environment (dependency injection down the tree)

**When:** A service or shared object needs to be available deep in the view hierarchy without prop-drilling.
**Scope:** Subtree — any view below the `.environment()` modifier.

```swift
// EnvironmentDemo.swift
import SwiftUI

// ★ Custom environment key — the type-safe way to inject objects
// Prefer this over EnvironmentObject for Swift 6

// Service to inject
@MainActor
@Observable
final class AuthService {
    private(set) var currentUser: String? = nil
    private(set) var isLoggedIn = false

    func login(as user: String) { currentUser = user; isLoggedIn = true }
    func logout() { currentUser = nil; isLoggedIn = false }
}

// For @Observable objects, just use @Environment directly (iOS 17+)
struct EnvironmentDemo: View {
    @State private var auth = AuthService()
    @Environment(SignalLog.self) var log

    var body: some View {
        VStack(spacing: 12) {
            // Pass down the tree — all descendants can read it
            ProfileHeader()
                .environment(auth)
            LoginButton()
                .environment(auth)
        }
        .onChange(of: auth.isLoggedIn) { _, v in
            log.record("@Environment", v ? "User logged in: \(auth.currentUser ?? "")" : "Logged out")
        }
    }
}

// Deeply nested child — accesses AuthService without any prop drilling
struct ProfileHeader: View {
    @Environment(AuthService.self) var auth

    var body: some View {
        HStack {
            Image(systemName: auth.isLoggedIn ? "person.fill.checkmark" : "person.slash")
                .foregroundStyle(auth.isLoggedIn ? .green : .secondary)
            Text(auth.currentUser ?? "Not logged in")
                .font(.subheadline)
        }
        .padding(10)
        .background(Color(.systemGray6), in: Capsule())
    }
}

struct LoginButton: View {
    @Environment(AuthService.self) var auth

    var body: some View {
        Button(auth.isLoggedIn ? "Log out" : "Log in as Alice") {
            auth.isLoggedIn ? auth.logout() : auth.login(as: "Alice")
        }
        .buttonStyle(.borderedProminent)
        .tint(auth.isLoggedIn ? .red : .blue)
    }
}

// ★ Comparison with old EnvironmentObject:
// OLD: @EnvironmentObject var auth: AuthService  (ObservableObject + @Published)
// NEW: @Environment(AuthService.self) var auth   (@Observable, no property wrappers inside)
// The new pattern re-renders ONLY views that read changed properties — not the whole subtree.
```

---

## Pattern 3 — Delegate protocol (UIKit pattern, still useful)

**When:** A child needs to communicate specific events up to its parent, with multiple event types.
**Scope:** Between two objects — typically a component and its owner.

```swift
// DelegateDemo.swift
import SwiftUI

// Classic delegate pattern
protocol MediaPlayerDelegate: AnyObject {
    func playerDidPlay()
    func playerDidPause()
    func playerDidFinish()
    func playerDidSeek(to time: TimeInterval)
}

// The "child" — a component that fires delegate events
@MainActor
@Observable
final class MediaPlayer {
    weak var delegate: (any MediaPlayerDelegate)?   // weak to prevent retain cycle

    var isPlaying = false
    var currentTime: TimeInterval = 0

    func play()  { isPlaying = true;  delegate?.playerDidPlay() }
    func pause() { isPlaying = false; delegate?.playerDidPause() }
    func finish() { isPlaying = false; delegate?.playerDidFinish() }
    func seek(to time: TimeInterval) {
        currentTime = time
        delegate?.playerDidSeek(to: time)
    }
}

// SwiftUI view acting as delegate
struct DelegateDemo: View {
    @State private var player = MediaPlayer()
    @Environment(SignalLog.self) var log

    var body: some View {
        VStack(spacing: 12) {
            Text(player.isPlaying ? "▶ Playing" : "⏸ Paused")
                .font(.headline)
            HStack(spacing: 20) {
                Button("Play")   { player.play() }
                Button("Pause")  { player.pause() }
                Button("Finish") { player.finish() }
                Button("Seek 30s") { player.seek(to: 30) }
            }
            .buttonStyle(.bordered)
        }
        .onAppear {
            player.delegate = DelegateAdapter(log: log)
        }
    }
}

// Adapter: bridges the UIKit delegate pattern to our log
// (In a real app this would be the parent ViewController or ViewModel)
final class DelegateAdapter: MediaPlayerDelegate, @unchecked Sendable {
    private let log: SignalLog
    init(log: SignalLog) { self.log = log }

    func playerDidPlay()   { Task { @MainActor in log.record("Delegate", "playerDidPlay()") } }
    func playerDidPause()  { Task { @MainActor in log.record("Delegate", "playerDidPause()") } }
    func playerDidFinish() { Task { @MainActor in log.record("Delegate", "playerDidFinish()") } }
    func playerDidSeek(to time: TimeInterval) {
        Task { @MainActor in log.record("Delegate", "playerDidSeek(to: \(Int(time))s)") }
    }
}

// ★ When to use delegate over closure callback:
// Use delegate when you have 3+ related event types that belong together.
// Use closures when you have 1-2 simple completion/action handlers.
```

---

## Pattern 4 — Closure callbacks

**When:** Simple one-shot completion or event, child → parent.
**Scope:** Between two directly connected objects.

```swift
// ClosureCallbackDemo.swift
import SwiftUI

struct FormSheet: View {
    let onSubmit: (String) -> Void          // ★ callback stored as property
    let onCancel: () -> Void

    @State private var text = ""

    var body: some View {
        VStack(spacing: 16) {
            TextField("Enter value", text: $text)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", action: onCancel)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Submit") { onSubmit(text) }
                    .disabled(text.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

struct ClosureCallbackDemo: View {
    @State private var showForm = false
    @State private var submittedValue = ""
    @Environment(SignalLog.self) var log

    var body: some View {
        VStack(spacing: 12) {
            if !submittedValue.isEmpty {
                Text("Last submitted: \(submittedValue)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("Open form sheet") { showForm = true }
                .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $showForm) {
            FormSheet(
                onSubmit: { value in
                    submittedValue = value
                    showForm = false
                    log.record("Closure", "Form submitted: \"\(value)\"")
                },
                onCancel: {
                    showForm = false
                    log.record("Closure", "Form cancelled")
                }
            )
        }
    }
}

// ★ @escaping vs non-escaping:
// Non-escaping (default): closure runs synchronously, then released. Safe.
// @escaping: closure outlives the function call (stored, async). Must capture [weak self].
//
// @Sendable: closure is safe to call from another concurrency context.
// Always mark callbacks @Sendable in Swift 6 if they'll be called from a Task.
```

---

## Pattern 5 — NotificationCenter (broadcast, loosely coupled)

**When:** Module A needs to broadcast an event that Module B (which A doesn't know about) should react to.
**Scope:** App-wide. Any object anywhere can post or observe.

```swift
// NotificationCenterDemo.swift
import SwiftUI

// ★ Type-safe notification wrapper — avoids stringly-typed names
extension Notification.Name {
    static let purchaseCompleted = Notification.Name("com.app.purchaseCompleted")
    static let cartUpdated       = Notification.Name("com.app.cartUpdated")
    static let themeChanged      = Notification.Name("com.app.themeChanged")
}

// Userinfo key type — no raw strings at call sites
enum NotificationKey: String {
    case itemName, itemCount, theme
}

// Poster (e.g., a payment module)
struct PaymentModule {
    static func completePurchase(itemName: String) {
        NotificationCenter.default.post(
            name: .purchaseCompleted,
            object: nil,
            userInfo: [NotificationKey.itemName.rawValue: itemName]
        )
    }
}

// Observer in SwiftUI using .onReceive
struct NotificationCenterDemo: View {
    @State private var lastPurchase = "none"
    @Environment(SignalLog.self) var log

    var body: some View {
        VStack(spacing: 12) {
            Text("Last purchase: \(lastPurchase)")
                .font(.subheadline)
            Button("Simulate purchase") {
                PaymentModule.completePurchase(itemName: "Pro Subscription")
            }
            .buttonStyle(.borderedProminent)
        }
        // ★ .onReceive for SwiftUI — cancels automatically when view disappears
        .onReceive(NotificationCenter.default.publisher(for: .purchaseCompleted)) { notification in
            let name = notification.userInfo?[NotificationKey.itemName.rawValue] as? String ?? "unknown"
            lastPurchase = name
            log.record("NotificationCenter", "purchaseCompleted: \(name)")
        }
    }
}

// Observer in a non-SwiftUI class (ViewModel or service)
actor AnalyticsService {
    private var observers: [NSObjectProtocol] = []

    func startListening() {
        let observer = NotificationCenter.default.addObserver(
            forName: .purchaseCompleted,
            object: nil,
            queue: .main
        ) { notification in
            // Track analytics event
            let name = notification.userInfo?[NotificationKey.itemName.rawValue] as? String
            print("Analytics: purchase - \(name ?? "unknown")")
        }
        observers.append(observer)
    }

    func stopListening() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}

// ★ When NOT to use NotificationCenter:
// - When sender and receiver are in the same module (use direct calls or @Observable)
// - When you need type-safe payloads (Combine or async/await are better)
// - When order of observer execution matters (it's unspecified)
```

---

## Pattern 6 — Combine PassthroughSubject (event streams)

**When:** Multiple subscribers need to react to the same event stream; when you want to chain operators (filter, map, debounce, merge).
**Scope:** Any — inject the publisher into subscribers.

```swift
// CombineEventBusDemo.swift
import Combine
import SwiftUI

// A typed event bus using Combine
final class EventBus: @unchecked Sendable {
    static let shared = EventBus()

    // Publishers for different event types
    let userAction = PassthroughSubject<UserAction, Never>()
    let networkEvent = PassthroughSubject<NetworkEvent, Never>()

    enum UserAction: Sendable {
        case tappedButton(String)
        case viewedItem(String)
        case sharedContent
    }

    enum NetworkEvent: Sendable {
        case requestStarted(URL)
        case requestFinished(URL, statusCode: Int)
        case requestFailed(URL, Error)
    }

    private init() {}
}

@MainActor
@Observable
final class CombineObserverViewModel {
    var actionLog: [String] = []
    private var cancellables = Set<AnyCancellable>()

    func start(log: SignalLog) {
        // Chain operators on the stream
        EventBus.shared.userAction
            .filter { if case .tappedButton = $0 { return true }; return false }
            .map { action -> String in
                if case .tappedButton(let name) = action { return name }
                return ""
            }
            .removeDuplicates()
            .sink { [weak self] buttonName in
                self?.actionLog.insert("Button: \(buttonName)", at: 0)
                log.record("Combine", "Filtered button tap: \(buttonName)")
            }
            .store(in: &cancellables)

        // Merge multiple publishers
        Publishers.Merge(
            EventBus.shared.userAction.map { _ in "user" },
            EventBus.shared.networkEvent.map { _ in "network" }
        )
        .sink { source in
            // receives from BOTH streams
            _ = source
        }
        .store(in: &cancellables)
    }
}

struct CombineEventBusDemo: View {
    @State private var vm = CombineObserverViewModel()
    @Environment(SignalLog.self) var log

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(["Buy", "Share", "Like", "Buy"], id: \.self) { name in
                    Button(name) {
                        EventBus.shared.userAction.send(.tappedButton(name))
                    }
                    .buttonStyle(.bordered)
                }
            }
            // Show de-duplicated log
            ForEach(vm.actionLog.prefix(3), id: \.self) { entry in
                Text(entry).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { vm.start(log: log) }
    }
}
```

---

## Pattern 7 — AsyncStream (modern event streams, Swift 6)

**When:** You want Combine-like streaming but without the Combine dependency; when working in async/await contexts; when bridging from callback-based APIs.
**Scope:** Any — pass the stream to observers.

```swift
// AsyncStreamDemo.swift
import SwiftUI

// ★ AsyncStream bridges callback/delegate APIs into async for-await loops

// A sensor that fires callbacks (simulating Core Location, CMMotionManager etc.)
final class StepCounter: @unchecked Sendable {
    var onStep: ((Int) -> Void)?
    private var count = 0

    func startCounting() {
        Task {
            while true {
                try? await Task.sleep(for: .seconds(Double.random(in: 0.5...2)))
                count += 1
                onStep?(count)
            }
        }
    }
}

// Bridge to AsyncStream
func stepStream(counter: StepCounter) -> AsyncStream<Int> {
    AsyncStream { continuation in
        counter.onStep = { steps in
            continuation.yield(steps)
        }
        continuation.onTermination = { _ in
            counter.onStep = nil
        }
        counter.startCounting()
    }
}

@MainActor
@Observable
final class StepViewModel {
    var stepCount = 0
    var rate: Double = 0
    private var lastTime = Date.now
    private var monitorTask: Task<Void, Never>?

    func startMonitoring(log: SignalLog) {
        let counter = StepCounter()
        monitorTask = Task {
            for await steps in stepStream(counter: counter) {
                guard !Task.isCancelled else { break }
                let elapsed = Date.now.timeIntervalSince(lastTime)
                rate = elapsed > 0 ? 1.0 / elapsed : 0
                lastTime = .now
                stepCount = steps
                log.record("AsyncStream", "Step \(steps) — rate: \(String(format: "%.1f", rate))/s")
            }
        }
    }

    func stop() { monitorTask?.cancel() }
}

struct AsyncStreamDemo: View {
    @State private var vm = StepViewModel()
    @State private var isRunning = false
    @Environment(SignalLog.self) var log

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                VStack {
                    Text("\(vm.stepCount)").font(.title.bold())
                    Text("steps").font(.caption).foregroundStyle(.secondary)
                }
                VStack {
                    Text(String(format: "%.1f", vm.rate)).font(.title.bold())
                    Text("per sec").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(isRunning ? "Stop" : "Start counting") {
                isRunning ? vm.stop() : vm.startMonitoring(log: log)
                isRunning.toggle()
            }
            .buttonStyle(.borderedProminent)
            .tint(isRunning ? .red : .green)
        }
    }
}
```

---

## Pattern 8 — Shared @Observable (global app state)

**When:** Multiple unrelated screens need to read/write the same state (e.g., cart, session, theme, feature flags).
**Scope:** App-wide — inject at root.

```swift
// SharedStateDemo.swift
import SwiftUI

// ★ The modern replacement for singletons and global vars
// Inject at the root of the app, access deep in the tree

@MainActor
@Observable
final class CartStore {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let name: String
        var quantity: Int
    }

    private(set) var items: [Item] = []
    var totalCount: Int { items.map(\.quantity).reduce(0, +) }
    var isEmpty: Bool { items.isEmpty }

    func add(name: String) {
        if let i = items.firstIndex(where: { $0.name == name }) {
            items[i].quantity += 1
        } else {
            items.append(Item(name: name, quantity: 1))
        }
    }

    func remove(name: String) {
        items.removeAll { $0.name == name }
    }

    func clear() { items.removeAll() }
}

// Screen A — adds items (knows nothing about Screen B)
struct ProductPageDemo: View {
    @Environment(CartStore.self) var cart
    @Environment(SignalLog.self) var log
    let products = ["Widget Pro", "Gadget Plus", "Doohickey"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Products").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(products, id: \.self) { p in
                HStack {
                    Text(p).font(.subheadline)
                    Spacer()
                    Button("Add") {
                        cart.add(name: p)
                        log.record("Shared @Observable", "Added \(p) to cart")
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

// Screen B — displays cart (knows nothing about Screen A)
struct CartBadgeDemo: View {
    @Environment(CartStore.self) var cart

    var body: some View {
        HStack(spacing: 16) {
            // Cart badge — updates automatically when cart changes
            ZStack(alignment: .topTrailing) {
                Image(systemName: "cart.fill")
                    .font(.title2)
                if cart.totalCount > 0 {
                    Text("\(cart.totalCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.red, in: Circle())
                        .offset(x: 8, y: -8)
                }
            }
            if !cart.isEmpty {
                Button("Clear") { cart.clear() }
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

struct SharedStateDemo: View {
    @State private var cart = CartStore()
    @Environment(SignalLog.self) var log

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Cart:").font(.caption.bold())
                Spacer()
                CartBadgeDemo()
            }
            ProductPageDemo()
        }
        .environment(cart)
    }
}

// ★ Key insight: @Observable tracks property-level access.
// CartBadgeDemo re-renders ONLY when totalCount or isEmpty change.
// ProductPageDemo re-renders ONLY when items changes.
// This is more efficient than ObservableObject which fires for all @Published changes.
```

---

## Pattern 9 — Actor messaging (cross-isolation communication)

**When:** A background actor needs to communicate results to the UI; services in different isolation domains need to cooperate.
**Scope:** Any — actors are the Swift 6 answer to thread-safe shared mutable state.

```swift
// ActorMessagingDemo.swift
import SwiftUI

// Background service actor (does work off main thread)
actor SyncService {
    private var syncCount = 0
    private var isSyncing = false

    // ★ Calling an actor method from MainActor = async hop to actor's queue
    func sync() async throws -> SyncResult {
        guard !isSyncing else { throw SyncError.alreadyRunning }
        isSyncing = true
        defer { isSyncing = false }

        // Simulate background work (DB writes, API calls, etc.)
        try await Task.sleep(for: .seconds(1))
        syncCount += 1
        return SyncResult(itemsSynced: Int.random(in: 5...20), syncNumber: syncCount)
    }

    func status() async -> String {
        isSyncing ? "Syncing…" : "Idle (syncs: \(syncCount))"
    }
}

struct SyncResult: Sendable {
    let itemsSynced: Int
    let syncNumber: Int
}

enum SyncError: Error { case alreadyRunning }

@MainActor
@Observable
final class SyncViewModel {
    var statusText = "Idle"
    var lastResult: SyncResult? = nil
    var isSyncing = false

    private let service = SyncService()

    func triggerSync(log: SignalLog) {
        Task {
            isSyncing = true
            statusText = "Syncing…"
            do {
                // ★ Calling across actor boundary — compiler enforces @Sendable on result
                let result = try await service.sync()
                lastResult = result
                statusText = "Synced \(result.itemsSynced) items"
                log.record("Actor", "Sync #\(result.syncNumber): \(result.itemsSynced) items")
            } catch SyncError.alreadyRunning {
                statusText = "Already running"
                log.record("Actor", "Sync rejected — already running")
            } catch {
                statusText = "Failed: \(error.localizedDescription)"
            }
            isSyncing = false
        }
    }

    func refreshStatus() {
        Task {
            statusText = await service.status()
        }
    }
}

struct ActorMessagingDemo: View {
    @State private var vm = SyncViewModel()
    @Environment(SignalLog.self) var log

    var body: some View {
        VStack(spacing: 12) {
            Text(vm.statusText)
                .font(.subheadline)
                .foregroundStyle(vm.isSyncing ? .orange : .primary)

            if let result = vm.lastResult {
                Text("Last sync: \(result.itemsSynced) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: { vm.triggerSync(log: log) }) {
                HStack {
                    if vm.isSyncing { ProgressView().scaleEffect(0.7) }
                    Text(vm.isSyncing ? "Syncing…" : "Trigger sync")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isSyncing)
        }
    }
}

// ★ Actor isolation rules:
// - Accessing actor properties from outside = must await
// - Passing data into/out of actors = must be Sendable
// - @MainActor is itself an actor — calling its methods from elsewhere = await
// - Two actors can call each other, but beware of deadlock with re-entrant await
```

---

## Putting it all together — root app

```swift
// CommKitApp.swift
import SwiftUI

@main
struct CommKitApp: App {
    // Shared objects injected at root
    @State private var log = SignalLog()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(log)
        }
    }
}

// ContentView.swift
import SwiftUI

struct ContentView: View {
    @Environment(SignalLog.self) var log

    var body: some View {
        NavigationStack {
            List {
                Section("Patterns") {
                    NavigationLink("1. @Binding")          { BindingDemo() }
                    NavigationLink("2. @Environment")      { EnvironmentDemo() }
                    NavigationLink("3. Delegate")          { DelegateDemo() }
                    NavigationLink("4. Closure callback")  { ClosureCallbackDemo() }
                    NavigationLink("5. NotificationCenter"){ NotificationCenterDemo() }
                    NavigationLink("6. Combine Subject")   { CombineEventBusDemo() }
                    NavigationLink("7. AsyncStream")       { AsyncStreamDemo() }
                    NavigationLink("8. Shared @Observable"){ SharedStateDemo() }
                    NavigationLink("9. Actor messaging")   { ActorMessagingDemo() }
                }

                Section("Live signal log") {
                    ForEach(log.entries.prefix(20)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.pattern)
                                .font(.caption.bold())
                                .foregroundStyle(.accentColor)
                            Text(entry.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    if log.entries.isEmpty {
                        Text("Tap a pattern to see signals here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle("CommKit")
        }
    }
}
```

---

## ★ Challenge — Build a typed event bus

Replace the `NotificationCenter` broadcast pattern with a fully type-safe, generic event bus that works across the app:

```swift
// TypedEventBus.swift

// Generic event bus: no stringly-typed names, no userInfo casting
@MainActor
@Observable
final class TypedEventBus {
    static let shared = TypedEventBus()

    // One subject per event type — keyed by ObjectIdentifier
    private var subjects: [ObjectIdentifier: Any] = [:]

    func publisher<E: Sendable>(for type: E.Type) -> PassthroughSubject<E, Never> {
        let key = ObjectIdentifier(type)
        if let existing = subjects[key] as? PassthroughSubject<E, Never> {
            return existing
        }
        let subject = PassthroughSubject<E, Never>()
        subjects[key] = subject
        return subject
    }

    func send<E: Sendable>(_ event: E) {
        publisher(for: E.self).send(event)
    }
}

// Usage:
struct PurchaseEvent: Sendable { let itemName: String; let price: Decimal }
struct CartClearedEvent: Sendable {}

// Post
TypedEventBus.shared.send(PurchaseEvent(itemName: "Widget", price: 9.99))

// Subscribe (in a view)
.onReceive(TypedEventBus.shared.publisher(for: PurchaseEvent.self)) { event in
    print("Purchased: \(event.itemName)")
}
```

---

## Complete cheat sheet

```
Pattern              | Direction      | Coupling   | Best for
---------------------|----------------|------------|-----------------------------
@Binding             | bidirectional  | tight      | form fields, toggles, sliders
@Environment         | down the tree  | loose      | services, theme, router, auth
Delegate protocol    | child → parent | moderate   | UIKit components, reusable UI
Closure callback     | child → parent | tight      | one-shot: completion, dismiss
NotificationCenter   | broadcast      | very loose | cross-module events, system events
Combine Subject      | broadcast      | loose      | reactive pipelines, event streams
AsyncStream          | producer → N   | loose      | Swift 6 streaming, bridged APIs
Shared @Observable   | read/write     | moderate   | cart, session, featureFlags, theme
Actor messaging      | any direction  | loose      | thread-safe state, background work
```

---

## Follow-up questions

- *Why prefer `@Environment` over a singleton `shared` instance?* (Singletons make testing impossible — you can't inject a mock. `@Environment` lets you swap in a test double in previews and XCTests.)
- *When should NotificationCenter fire vs a direct method call?* (NotificationCenter when the poster has no compile-time knowledge of the observer — e.g., a payments SDK doesn't import your analytics module.)
- *What's the Swift 6 issue with `NotificationCenter` observers?* (The completion handler runs on an unspecified queue. Wrap in `Task { @MainActor in ... }` or use `.onReceive` which marshals to the main queue for you.)
- *How do you avoid retain cycles in closure callbacks?* (`[weak self]` capture list; in `@escaping` closures that outlive the function call)
- *What's the difference between `PassthroughSubject` and `CurrentValueSubject`?* (PassthroughSubject has no stored value — new subscribers miss past events. CurrentValueSubject stores the latest value and replays it to new subscribers — like a Combine version of `@Published`.)
- *How does `@Observable` re-rendering compare to `ObservableObject`?* (ObservableObject invalidates the entire view on any `@Published` change. @Observable tracks which specific properties each view body reads and only re-renders that view when those specific properties change.)
