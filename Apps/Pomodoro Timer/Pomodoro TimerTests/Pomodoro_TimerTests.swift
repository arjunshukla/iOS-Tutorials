import Testing
@testable import Pomodoro_Timer

@Suite("PomodoroViewModel")
@MainActor
struct PomodoroViewModelTests {

    // MARK: - Initial State

    @Test func initialState() {
        let vm = PomodoroViewModel(clock: ManualClock())
        #expect(vm.state.status == .idle)
        #expect(vm.state.mode == .work)
        #expect(vm.state.timeRemaining == TimerMode.work.duration)
        #expect(vm.state.completedSessions == 0)
    }

    // MARK: - Start

    @Test func startTransitionsToRunning() async {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        #expect(vm.state.status == .running)
    }

    @Test func startFromFinishedResetsAndRuns() async {
        let clock = ManualClock()
        let vm = PomodoroViewModel(clock: clock)
        // Drive to finished state
        clock.shouldThrow = false
        vm.send(.start)
        vm.send(._timerFinished)
        #expect(vm.state.status == .finished)
        vm.send(.start)
        #expect(vm.state.status == .running)
    }

    @Test func startIgnoredWhenAlreadyRunning() async {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(.start) // second call is a no-op
        #expect(vm.state.status == .running)
    }

    // MARK: - Pause / Resume

    @Test func pauseTransitionsToPaused() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(.pause)
        #expect(vm.state.status == .paused)
    }

    @Test func pauseIgnoredWhenIdle() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.pause)
        #expect(vm.state.status == .idle)
    }

    @Test func resumeTransitionsToRunning() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(.pause)
        vm.send(.resume)
        #expect(vm.state.status == .running)
    }

    @Test func resumeIgnoredWhenNotPaused() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.resume)
        #expect(vm.state.status == .idle)
    }

    // MARK: - Reset

    @Test func resetFromRunningRestoresIdle() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(.reset)
        #expect(vm.state.status == .idle)
        #expect(vm.state.timeRemaining == TimerMode.work.duration)
    }

    @Test func resetFromPausedRestoresIdle() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(.pause)
        vm.send(.reset)
        #expect(vm.state.status == .idle)
    }

    // MARK: - Switch Mode

    @Test func switchModeUpdatesStateAndResetsTimer() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(.switchMode(.shortBreak))
        #expect(vm.state.mode == .shortBreak)
        #expect(vm.state.status == .idle)
        #expect(vm.state.timeRemaining == TimerMode.shortBreak.duration)
    }

    @Test func switchModeLongBreak() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.switchMode(.longBreak))
        #expect(vm.state.mode == .longBreak)
        #expect(vm.state.timeRemaining == TimerMode.longBreak.duration)
    }

    // MARK: - Finish / Auto-Advance

    @Test func finishIncrementsCompletedSessions() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(._timerFinished)
        #expect(vm.state.completedSessions == 1)
        #expect(vm.state.status == .finished)
    }

    @Test func finishAfterWorkSwitchesToShortBreak() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(._timerFinished)
        #expect(vm.state.mode == .shortBreak)
    }

    @Test func finishAfterShortBreakSwitchesToWork() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.switchMode(.shortBreak))
        vm.send(.start)
        vm.send(._timerFinished)
        #expect(vm.state.mode == .work)
    }

    @Test func fourthSessionTriggersLongBreak() {
        let vm = PomodoroViewModel(clock: ManualClock())
        // Simulate 3 earlier sessions
        vm.send(.start); vm.send(._timerFinished)  // 1 — shortBreak
        vm.send(.start); vm.send(._timerFinished)  // 2 — work
        vm.send(.start); vm.send(._timerFinished)  // 3 — shortBreak
        vm.send(.start); vm.send(._timerFinished)  // 4 — longBreak
        #expect(vm.state.completedSessions == 4)
        #expect(vm.state.mode == .longBreak)
    }

    @Test func finishResetsTimeRemainingToNewModeDuration() {
        let vm = PomodoroViewModel(clock: ManualClock())
        vm.send(.start)
        vm.send(._timerFinished)
        // After work → shortBreak
        #expect(vm.state.timeRemaining == TimerMode.shortBreak.duration)
    }

    // MARK: - Coordinator Event

    @Test func coordinatorEventFiredOnFinish() {
        let vm = PomodoroViewModel(clock: ManualClock())
        var receivedCount: Int?
        vm.onCoordinatorEvent = { event in
            if case .didFinishSession(let count) = event {
                receivedCount = count
            }
        }
        vm.send(.start)
        vm.send(._timerFinished)
        #expect(receivedCount == 1)
    }

    @Test func coordinatorEventFiredWithCorrectCount() {
        let vm = PomodoroViewModel(clock: ManualClock())
        var counts: [Int] = []
        vm.onCoordinatorEvent = { event in
            if case .didFinishSession(let count) = event { counts.append(count) }
        }
        vm.send(.start); vm.send(._timerFinished)
        vm.send(.start); vm.send(._timerFinished)
        vm.send(.start); vm.send(._timerFinished)
        #expect(counts == [1, 2, 3])
    }

    // MARK: - State Equatability

    @Test func stateIsEquatable() {
        let s1 = PomodoroState()
        let s2 = PomodoroState()
        #expect(s1 == s2)
    }

    @Test func statesDifferAfterAction() {
        let vm = PomodoroViewModel(clock: ManualClock())
        let before = vm.state
        vm.send(.start)
        #expect(vm.state != before)
    }

    // MARK: - Display Helpers

    @Test func displayTimeFormatsCorrectly() {
        var state = PomodoroState()
        state.timeRemaining = 25 * 60  // 25:00
        #expect(state.displayTime == "25:00")
    }

    @Test func displayTimeFormatsSeconds() {
        var state = PomodoroState()
        state.timeRemaining = 65  // 1:05
        #expect(state.displayTime == "01:05")
    }

    @Test func progressIsZeroAtStart() {
        let state = PomodoroState()
        #expect(state.progress == 0.0)
    }

    @Test func progressIsOneAtZeroTimeRemaining() {
        var state = PomodoroState()
        state.timeRemaining = 0
        #expect(state.progress == 1.0)
    }

    // MARK: - Clock Cancellation

    @Test func cancelledClockExitsCleanly() async {
        let clock = ManualClock()
        let vm = PomodoroViewModel(clock: clock)
        vm.send(.start)
        clock.shouldThrow = true
        // Pause triggers cancel on the task — no crash expected
        vm.send(.pause)
        #expect(vm.state.status == .paused)
    }
}
