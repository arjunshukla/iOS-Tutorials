// All view state in one Equatable struct - diffable, testable

import Foundation
struct PomodoroState: Equatable {
    enum TimerStatus: Equatable {
        case idle, running ,paused, finished
    }

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
