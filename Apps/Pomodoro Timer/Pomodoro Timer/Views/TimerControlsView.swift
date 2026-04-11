import SwiftUI

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
