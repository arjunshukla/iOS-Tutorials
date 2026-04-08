# Tutorial 01 — Swift Timers
## Build: PomodoroKit — a precision focus timer
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** Timer, Task.sleep, RunLoop, precision timing

---

## What you'll build
A Pomodoro timer app with:
- Work / short break / long break modes
- Sub-second precision tick using `Task.sleep`
- Background-aware timer that syncs on foreground return
- A ring progress indicator

---

## Why timers are tricky

Three common approaches — each with tradeoffs:

| Approach | Precision | Battery | Background |
|---|---|---|---|
| `Timer.scheduledTimer` | ~50ms drift/min | Good | Pauses |
| `DispatchSourceTimer` | High | OK | Requires entitlement |
| `Task + Task.sleep` | Good, cancellable | Good | Suspends, self-corrects |

For UI timers, `Task + Task.sleep` is the Swift 6 canonical approach.

---

## Concept: RunLoop modes

```swift
// Timer.scheduledTimer only fires when RunLoop is in .default mode
// ScrollView tracking uses .tracking mode — your timer PAUSES during scroll!
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    print("may pause during scroll")
}

// Fix: schedule on .common (fires in both .default and .tracking)
RunLoop.main.add(timer, forMode: .common)

// Better fix: use Combine's timer publisher
Timer.publish(every: 1, on: .main, in: .common)
    .autoconnect()
    .sink { _ in print("fires during scroll too") }
```

---

## Project setup

New Xcode project → App → Swift + SwiftUI → iOS 17+

---

## Step 1 — Timer mode model (~5 min)

```swift
// Models.swift
import Foundation

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

    var color: String {
        switch self {
        case .work:       return "AccentRed"
        case .shortBreak: return "AccentGreen"
        case .longBreak:  return "AccentBlue"
        }
    }
}

enum TimerState: Equatable, Sendable {
    case idle
    case running
    case paused
    case finished
}
```

---

## Step 2 — ViewModel with Task-based timer (~15 min)

```swift
// PomodoroViewModel.swift
import Foundation
import Observation

@MainActor
@Observable
final class PomodoroViewModel {

    var mode: TimerMode = .work
    var state: TimerState = .idle
    var timeRemaining: TimeInterval = TimerMode.work.duration
    var completedSessions: Int = 0

    private var timerTask: Task<Void, Never>?
    // ★ Key: store the start time to self-correct on foreground return
    private var startedAt: Date?
    private var elapsedAtPause: TimeInterval = 0

    var progress: Double {
        1.0 - (timeRemaining / mode.duration)
    }

    var displayTime: String {
        let minutes = Int(timeRemaining) / 60
        let seconds = Int(timeRemaining) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Controls

    func start() {
        guard state != .running else { return }
        startedAt = .now
        state = .running
        timerTask = Task { await runTimer() }
    }

    func pause() {
        guard state == .running else { return }
        timerTask?.cancel()
        // Record elapsed so resume is accurate
        if let start = startedAt {
            elapsedAtPause += Date.now.timeIntervalSince(start)
        }
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        startedAt = .now
        state = .running
        timerTask = Task { await runTimer() }
    }

    func reset() {
        timerTask?.cancel()
        timeRemaining = mode.duration
        elapsedAtPause = 0
        startedAt = nil
        state = .idle
    }

    func switchMode(_ newMode: TimerMode) {
        timerTask?.cancel()
        mode = newMode
        timeRemaining = newMode.duration
        elapsedAtPause = 0
        startedAt = nil
        state = .idle
    }

    // MARK: - Background sync
    // Call this from .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification))

    func syncOnForeground() {
        guard state == .running, let start = startedAt else { return }
        let elapsed = elapsedAtPause + Date.now.timeIntervalSince(start)
        timeRemaining = max(0, mode.duration - elapsed)
        if timeRemaining == 0 { finish() }
    }

    // MARK: - Private

    private func runTimer() async {
        // ★ Self-correcting timer: compare wall time, not tick count
        // This avoids accumulated drift from imprecise sleep intervals
        let deadline = Date.now.addingTimeInterval(timeRemaining)

        do {
            while timeRemaining > 0 {
                try await Task.sleep(for: .milliseconds(100))
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    timeRemaining = 0
                    finish()
                    return
                }
                timeRemaining = remaining
            }
        } catch {
            // Cancelled (pause, reset, mode switch) — exit cleanly
        }
    }

    private func finish() {
        state = .finished
        completedSessions += 1
        // Auto-suggest next mode after 4 sessions
        if completedSessions % 4 == 0 {
            mode = .longBreak
        } else if mode == .work {
            mode = .shortBreak
        } else {
            mode = .work
        }
        timeRemaining = mode.duration
        elapsedAtPause = 0
        startedAt = nil
    }
}
```

---

## Step 3 — Ring progress view (~10 min)

```swift
// RingView.swift
import SwiftUI

struct RingView: View {
    let progress: Double       // 0.0 → 1.0
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)

            // Progress arc
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)
        }
    }
}
```

---

## Step 4 — Main view (~20 min)

```swift
// ContentView.swift
import SwiftUI

struct ContentView: View {
    @State private var vm = PomodoroViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 40) {
                // Mode picker
                Picker("Mode", selection: Binding(
                    get: { vm.mode },
                    set: { vm.switchMode($0) }
                )) {
                    ForEach(TimerMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Ring + time display
                ZStack {
                    RingView(
                        progress: vm.progress,
                        color: .red,  // swap per mode
                        lineWidth: 20
                    )
                    .frame(width: 280, height: 280)

                    VStack(spacing: 8) {
                        Text(vm.displayTime)
                            .font(.system(size: 64, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))

                        Text(vm.mode.rawValue)
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        if vm.completedSessions > 0 {
                            Text("🍅 × \(vm.completedSessions)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Controls
                HStack(spacing: 24) {
                    Button("Reset") { vm.reset() }
                        .buttonStyle(.bordered)
                        .tint(.secondary)

                    mainButton

                    Button("Skip") { vm.switchMode(vm.mode) }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                }
                .font(.headline)
            }
            .padding()
        }
        // Background sync
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
        ) { _ in
            vm.syncOnForeground()
        }
    }

    @ViewBuilder
    private var mainButton: some View {
        switch vm.state {
        case .idle, .finished:
            Button("Start") { vm.start() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        case .running:
            Button("Pause") { vm.pause() }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        case .paused:
            Button("Resume") { vm.resume() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
        }
    }
}
```

---

## ★ Challenge — add these before time runs out

1. **Local notification** when the timer finishes (use `UNUserNotificationCenter`)
2. **Haptic pulse** every minute — `UIImpactFeedbackGenerator`
3. **Persist session count** across launches with `@AppStorage`

---

## Key concepts to remember

**Drift problem:** `Timer.scheduledTimer` with 1s intervals drifts ~50ms per minute (RunLoop scheduling overhead). After 20 minutes that's 1 second of error. Anchoring to a `Date` deadline eliminates accumulated drift entirely.

**CancellationError:** When you cancel a `Task`, `Task.sleep` throws `CancellationError`. Always catch it in timer loops — not doing so causes a crash.

**RunLoop.common:** If you use `Timer.scheduledTimer`, always add it to `.common` mode, not `.default`. Otherwise your timer pauses whenever the user scrolls a list.

---

## Follow-up questions

- *What's the difference between `.main` and `.common` RunLoop modes?*
- *How would you keep a timer running while the app is backgrounded?* (Background task + `UIApplication.beginBackgroundTask`)
- *When would you use `DispatchSourceTimer` over `Task.sleep`?* (Sub-millisecond precision needs, e.g., audio engines)
