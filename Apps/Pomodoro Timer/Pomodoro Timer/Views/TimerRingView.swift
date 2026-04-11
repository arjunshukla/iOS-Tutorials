import SwiftUI

struct TimerRingView: View {
    let progress: Double
    let displayTime: String
    let accentColor: Color
    let sessionCount: Int

    var body: some View {
        ZStack {
            RingView(progress: progress, color: accentColor, lineWidth: 20)
                .frame(width: 280, height: 280)

            TimeDisplayView(
                displayTime: displayTime,
                sessionCount: sessionCount,
                color: accentColor
            )
        }
    }
}
