# Tutorial 01 — Swift Timers
## Build: PomodoroKit — a precision focus timer
**Time:** 45 min | **Swift 6 + SwiftUI** | **Topics:** Timer, Task.sleep, RunLoop, precision timing, MVVM state machine, Swift Testing

---

## What you'll build
A Pomodoro timer with:
- Work / short break / long break modes
- Self-correcting `Task.sleep` tick loop
- Background-aware foreground sync
- Ring progress indicator
- Fully testable without running the UI

---

## Architecture

```
PomodoroView
├── ModePickerView          ← segmented picker, fires switchMode action
├── TimerRingView           ← ring + digits, pure display
└── TimerControlsView       ← start/pause/resume/reset/skip buttons

PomodoroViewModel           ← owns all state, exposes send(_:)
└── ClockService (protocol) ← injectable time source for tests
```

---

## Why timers are tricky

| Approach | Precision | Battery | Background |
|---|---|---|---|
| `Timer.scheduledTimer` | ~50ms drift/min | Good | Pauses |
| `DispatchSourceTimer` | High | OK | Requires entitlement |
| `Task + Task.sleep` | Good, cancellable | Good | Suspends, self-corrects |

**RunLoop trap:** `Timer.scheduledTimer` fires only in `.default` mode — it pauses while a `ScrollView` is scrolling. Fix: schedule on `.common`, or use `Task.sleep`.

---

## Step 1 — Models (~5 min)

```swift
// Models.swift
import SwiftUI

enum TimerMode: String, CaseIterable, Sendable {
    case work       = "Focus"
    case shortBreak = "Short Break"
    case longBreak  = "Long Break"

    var duration: TimeInterval {
        switch self {
        case .work:       return 25 * 60
        case .shortBreak: return 5  * 60
        case .longBreak:  return 15 * 60
        }
    }

    var accentColor: Color {
        switch self {
        case .work:       return .red
        case .shortBreak: return .green
        case .longBreak:  return .blue
        }
    }
}

// ★ All view state in one Equatable struct — diffable, testable
struct PomodoroState: Equatable {
    enum TimerStatus: Equatable { case idle, running, paused, finished }

    var mode: TimerMode           = .work
    var status: TimerStatus       = .idle
    var timeRemaining: TimeInterval = TimerMode.work.duration
    var completedSessions: Int    = 0

    var progress: Double { 1.0 - (timeRemaining / mode.duration) }

    var displayTime: String {
        let m = Int(timeRemaining) / 60
        let s = Int(timeRemaining) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
```

---

## Step 2 — Service protocol (injectable clock) (~5 min)

```swift
// ClockService.swift
import Foundation

// ★ Protocol = swap real sleep for a controllable one in tests
protocol ClockServiceProtocol: Sendable {
    func sleep(for duration: Duration) async throws
}

struct SystemClock: ClockServiceProtocol {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

// Tests use this to advance time without waiting
final class ManualClock: ClockServiceProtocol, @unchecked Sendable {
    var shouldThrow = false

    func sleep(for duration: Duration) async throws {
        if shouldThrow { throw CancellationError() }
        // Returns immediately — no real waiting in tests
    }
}
```

---

## Step 3 — ViewModel with `send(_:)` dispatch (~15 min)

```swift
// PomodoroViewModel.swift
import Observation
import Foundation

// ★ All user intents are modeled as an enum — exhaustive, discoverable
enum PomodoroAction: Sendable {
    case start
    case pause
    case resume
    case reset
    case switchMode(TimerMode)
    case syncOnForeground
    // Internal — coordinator/action from timer loop
    case _timerFinished
}

// ★ Protocol lets tests inject mock VM; coordinator targets the protocol
@MainActor
protocol PomodoroViewModelProtocol: AnyObject {
    var state: PomodoroState { get }
    func send(_ action: PomodoroAction)
}

@MainActor
@Observable
final class PomodoroViewModel: PomodoroViewModelProtocol {

    private(set) var state = PomodoroState()

    private var timerTask: Task<Void, Never>?
    private var startedAt: Date?
    private var elapsedAtPause: TimeInterval = 0
    private let clock: ClockServiceProtocol

    // Coordinator integration — fires when session completes
    var onAction: ((PomodoroAction) -> Void)?

    init(clock: ClockServiceProtocol = SystemClock()) {
        self.clock = clock
    }

    // ★ Single dispatch point — mirrors TCA / Redux pattern
    func send(_ action: PomodoroAction) {
        switch action {
        case .start:               start()
        case .pause:               pause()
        case .resume:              resume()
        case .reset:               reset()
        case .switchMode(let m):   switchMode(m)
        case .syncOnForeground:    syncOnForeground()
        case ._timerFinished:      finish()
        }
    }

    // MARK: - Private handlers

    private func start() {
        guard state.status == .idle || state.status == .finished else { return }
        startedAt = .now
        state.status = .running
        timerTask = Task { await runTimer() }
    }

    private func pause() {
        guard state.status == .running else { return }
        timerTask?.cancel()
        if let start = startedAt {
            elapsedAtPause += Date.now.timeIntervalSince(start)
        }
        state.status = .paused
    }

    private func resume() {
        guard state.status == .paused else { return }
        startedAt = .now
        state.status = .running
        timerTask = Task { await runTimer() }
    }

    private func reset() {
        timerTask?.cancel()
        state.timeRemaining = state.mode.duration
        state.status = .idle
        elapsedAtPause = 0
        startedAt = nil
    }

    private func switchMode(_ newMode: TimerMode) {
        timerTask?.cancel()
        state.mode = newMode
        state.timeRemaining = newMode.duration
        state.status = .idle
        elapsedAtPause = 0
        startedAt = nil
    }

    private func syncOnForeground() {
        guard state.status == .running, let start = startedAt else { return }
        let elapsed = elapsedAtPause + Date.now.timeIntervalSince(start)
        state.timeRemaining = max(0, state.mode.duration - elapsed)
        if state.timeRemaining == 0 { finish() }
    }

    private func finish() {
        state.completedSessions += 1
        // Auto-advance mode
        if state.completedSessions % 4 == 0 {
            state.mode = .longBreak
        } else if state.mode == .work {
            state.mode = .shortBreak
        } else {
            state.mode = .work
        }
        state.timeRemaining = state.mode.duration
        state.status = .finished
        elapsedAtPause = 0
        startedAt = nil
        onAction?(.didFinishSession(count: state.completedSessions))
    }

    // ★ Self-correcting: anchors to wall-clock, not tick count
    private func runTimer() async {
        let deadline = Date.now.addingTimeInterval(state.timeRemaining)
        do {
            while state.timeRemaining > 0 {
                try await clock.sleep(for: .milliseconds(100))
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    state.timeRemaining = 0
                    finish()
                    return
                }
                state.timeRemaining = remaining
            }
        } catch {
            // Cancelled — pause/reset/switchMode — exit cleanly
        }
    }
}

// Separate coordinator-facing actions from timer actions
// (keeps PomodoroAction lean and timer-only)
extension PomodoroViewModel {
    enum CoordinatorEvent {
        case didFinishSession(count: Int)
    }
    var onCoordinatorEvent: ((CoordinatorEvent) -> Void)?
}

// Fix: use proper coordinator event
private extension PomodoroViewModel {
    func notifyCoordinator(count: Int) {
        onCoordinatorEvent?(.didFinishSession(count: count))
    }
}
```

---

## Step 4 — Modular views (~10 min)

```swift
// ModePickerView.swift
import SwiftUI

struct ModePickerView: View {
    let currentMode: TimerMode
    let onSelect: (TimerMode) -> Void

    var body: some View {
        Picker("Mode", selection: Binding(
            get: { currentMode },
            set: { onSelect($0) }
        )) {
            ForEach(TimerMode.allCases, id: \.self) {
                Text($0.rawValue).tag($0)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }
}

// TimerRingView.swift
struct TimerRingView: View {
    let progress: Double
    let displayTime: String
    let accentColor: Color
    let sessionCount: Int

    var body: some View {
        ZStack {
            RingView(progress: progress, color: accentColor, lineWidth: 20)
                .frame(width: 280, height: 280)

            TimeDisplay(
                displayTime: displayTime,
                sessionCount: sessionCount,
                color: accentColor
            )
        }
    }
}

struct RingView: View {
    let progress: Double
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)
        }
    }
}

struct TimeDisplay: View {
    let displayTime: String
    let sessionCount: Int
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Text(displayTime)
                .font(.system(size: 64, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))

            if sessionCount > 0 {
                Text("🍅 × \(sessionCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// TimerControlsView.swift
struct TimerControlsView: View {
    let status: PomodoroState.TimerStatus
    let onSend: (PomodoroAction) -> Void

    var body: some View {
        HStack(spacing: 24) {
            Button("Reset") { onSend(.reset) }
                .buttonStyle(.bordered)
                .tint(.secondary)

            primaryButton

            Button("Skip") { onSend(.switchMode(.work)) }
                .buttonStyle(.bordered)
                .tint(.secondary)
        }
        .font(.headline)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch status {
        case .idle, .finished:
            Button("Start") { onSend(.start) }
                .buttonStyle(.borderedProminent).tint(.red)
        case .running:
            Button("Pause") { onSend(.pause) }
                .buttonStyle(.borderedProminent).tint(.orange)
        case .paused:
            Button("Resume") { onSend(.resume) }
                .buttonStyle(.borderedProminent).tint(.green)
        }
    }
}

// PomodoroView.swift — root view: thin, delegates all logic to VM
struct PomodoroView: View {
    @State private var vm = PomodoroViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 40) {
                ModePickerView(
                    currentMode: vm.state.mode,
                    onSelect: { vm.send(.switchMode($0)) }
                )

                TimerRingView(
                    progress: vm.state.progress,
                    displayTime: vm.state.displayTime,
                    accentColor: vm.state.mode.accentColor,
                    sessionCount: vm.state.completedSessions
                )

                TimerControlsView(
                    status: vm.state.status,
                    onSend: { vm.send($0) }
                )
            }
            .padding()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.willEnterForegroundNotification
            )
        ) { _ in vm.send(.syncOnForeground) }
    }
}
```

---

## Step 5 — Swift Testing suite (~10 min)

```swift
// PomodoroViewModelTests.swift
import Testing
@testable import PomodoroKit

@Suite("PomodoroViewModel")
struct PomodoroViewModelTests {

    // MARK: - Initial state

    @Test @MainActor
    func startsInIdleState() {
        let vm = PomodoroViewModel(clock: ManualClock())
        #expect(vm.state.status == .idle)
        #expect(vm.state.mode == .work)
        #expect(vm.state.timeRemaining == TimerMode.work.duration)
    }

    // MARK: - send(.start)

    @Test @MainActor
    func startTransitionsToRunning() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        #expect(vm.state.status == .running)
    }

    @Test @MainActor
    func startWhileRunningIsNoop() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(.start)         // second call should be ignored
        #expect(vm.state.status == .running)
    }

    // MARK: - send(.pause) / send(.resume)

    @Test @MainActor
    func pauseAndResume() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(.pause)
        #expect(vm.state.status == .paused)
        vm.send(.resume)
        #expect(vm.state.status == .running)
    }

    @Test @MainActor
    func pauseWhenNotRunningIsNoop() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.pause)
        #expect(vm.state.status == .idle)
    }

    // MARK: - send(.reset)

    @Test @MainActor
    func resetRestoresIdleState() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(.reset)
        #expect(vm.state.status == .idle)
        #expect(vm.state.timeRemaining == TimerMode.work.duration)
    }

    // MARK: - send(.switchMode)

    @Test @MainActor
    func switchModeResetsTimerToNewDuration() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(.switchMode(.shortBreak))
        #expect(vm.state.mode == .shortBreak)
        #expect(vm.state.status == .idle)
        #expect(vm.state.timeRemaining == TimerMode.shortBreak.duration)
    }

    // MARK: - State struct properties

    @Test @MainActor
    func progressIsZeroAtStart() {
        let vm = PomodoroViewModel(clock: ManualClock())
        #expect(vm.state.progress == 0.0)
    }

    @Test @MainActor
    func displayTimeFormatsCorrectly() {
        var state = PomodoroState()
        state.timeRemaining = 90   // 1:30
        #expect(state.displayTime == "01:30")
    }

    // MARK: - Session counting

    @Test @MainActor
    func completedSessionsStartAtZero() {
        let vm = PomodoroViewModel(clock: ManualClock())
        #expect(vm.state.completedSessions == 0)
    }

    // MARK: - Mode auto-advance after 4 sessions (integration)

    @Test @MainActor
    func afterFourWorkSessionsModeBecomesLongBreak() {
        let vm = PomodoroViewModel(clock: ManualClock())
        // Directly trigger finish 4 times via internal action
        for _ in 0..<4 {
            vm.state.mode = .work
            vm.send(._timerFinished)
        }
        #expect(vm.state.mode == .longBreak)
    }
}

// MARK: - PomodoroState unit tests (pure value type — no async needed)

@Suite("PomodoroState")
struct PomodoroStateTests {

    @Test
    func progressIsZeroWhenTimeRemainingEqualsDuration() {
        let state = PomodoroState()
        #expect(state.progress == 0.0)
    }

    @Test
    func progressIsOneWhenTimeRemainingIsZero() {
        var state = PomodoroState()
        state.timeRemaining = 0
        #expect(state.progress == 1.0)
    }

    @Test
    func displayTimeFormats() {
        var state = PomodoroState()
        state.timeRemaining = 65   // 1 min 5 sec
        #expect(state.displayTime == "01:05")
    }
}
```

---

## Coordinator integration

```swift
// PomodoroCoordinator.swift
@MainActor
@Observable
final class PomodoroCoordinator {
    var path = NavigationPath()
    var isSummaryPresented = false
    private(set) var lastCompletedCount = 0

    func makeTimerViewModel() -> PomodoroViewModel {
        let vm = PomodoroViewModel()
        vm.onCoordinatorEvent = { [weak self] event in
            switch event {
            case .didFinishSession(let count):
                self?.lastCompletedCount = count
                if count % 4 == 0 { self?.isSummaryPresented = true }
            }
        }
        return vm
    }
}
```

---

## Key concepts to remember

**`send(_:)` dispatch:** One entry point for all state changes. The switch statement inside is the state machine — exhaustive, readable, testable by calling `send()` directly.

**Injected clock:** `ClockServiceProtocol` decouples the timer loop from real time. `ManualClock.sleep` returns immediately — tests run at full speed with no `await` waiting.

**Self-correcting timer:** Anchoring to a `Date` deadline (`deadline.timeIntervalSinceNow`) eliminates accumulated drift. 100 ticks of 100ms each ≠ exactly 10s. The wall clock is always exact.

**State struct:** `PomodoroState: Equatable` means `#expect(vm.state == expectedState)` works in tests. Individual property checks also work since the struct properties are all value types.

---

## Follow-up questions

- *Why `send(_ action:)` over individual methods?* (Centralises all state transitions in one switch. Easy to add logging, analytics, or middleware. Mirrors how TCA and Redux work.)
- *What's the difference between `.main` and `.common` RunLoop modes?*
- *How would you keep a timer running while backgrounded?* (`UIApplication.beginBackgroundTask` + time sync on `willEnterForeground`)
- *When would you use `DispatchSourceTimer` over `Task.sleep`?* (Sub-millisecond precision — audio, game engines)
