// PomodoroView.swift — root view: thin, delegates all logic to VM

import Foundation
import SwiftUI
import UIKit

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
