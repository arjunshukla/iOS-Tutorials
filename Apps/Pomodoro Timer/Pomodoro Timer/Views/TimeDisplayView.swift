import SwiftUI

struct TimeDisplayView: View {
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
