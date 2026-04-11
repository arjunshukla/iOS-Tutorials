import Foundation
import SwiftUI

enum TimerMode: String, CaseIterable, Sendable {
    case work = "Focus"
    case shortBreak = "Short Break"
    case longBreak = "Long Break"

    var duration: TimeInterval {
        switch self {
        case.work: return 25 * 60
        case .shortBreak: return 5 * 60
        case .longBreak: return 15 * 60
        }
    }

    var accentColor: Color {
        switch self {
        case.work: return .red
        case .shortBreak: return .green
        case .longBreak: return .blue
        }
    }
}
