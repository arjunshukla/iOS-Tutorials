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
    private let clock: any ClockServiceProtocol

    // Coordinator integration — stored properties MUST be in the class body, not an extension
    enum CoordinatorEvent {
        case didFinishSession(count: Int)
    }
    var onCoordinatorEvent: ((CoordinatorEvent) -> Void)?

    // ★ Fix 1: Two explicit inits instead of a default parameter expression.
    // In Swift 6, default parameter expressions evaluate in a nonisolated context,
    // which conflicts with @MainActor class inits. Splitting into two inits avoids this.
    init() {
        self.clock = SystemClock()
    }

    init(clock: any ClockServiceProtocol) {
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
        // ★ Fix 2: Use onCoordinatorEvent, not onAction — didFinishSession is on CoordinatorEvent
        onCoordinatorEvent?(.didFinishSession(count: state.completedSessions))
    }

    // ★ Self-correcting: anchors to wall-clock deadline, not tick count
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
