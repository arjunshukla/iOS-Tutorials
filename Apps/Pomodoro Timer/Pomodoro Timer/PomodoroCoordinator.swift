import Observation
import SwiftUI
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
