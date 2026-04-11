import SwiftUI

struct ModePickerView: View {
    let currentMode: TimerMode
    let onSelect: (TimerMode) -> Void

    var body: some View {
        Picker("Mode", selection: Binding(
            get: { currentMode },
            set: { onSelect($0) }
        )) {
            ForEach(TimerMode.allCases, id: \.self) {
                Text($0.rawValue).tag($0)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }
}
