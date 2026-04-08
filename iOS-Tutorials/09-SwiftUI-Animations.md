# Tutorial 09 — SwiftUI Animations
## Build: AnimationKit — an interactive animation playground
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** Implicit/explicit animation, transitions, matchedGeometryEffect, phase animation, keyframes, spring physics

---

## What you'll build
Five animation demos on one screen:
1. Spring physics card flip
2. `matchedGeometryEffect` shared element transition
3. Phase animation (multi-step)
4. Keyframe animation (iOS 17)
5. Custom `Animatable` conformance

---

## Animation mental model

```
Two types:
1. Implicit (.animation modifier)
   - Applies to ALL animatable changes in the subtree
   - Can produce surprising results
   
2. Explicit (withAnimation { })
   - You control exactly what triggers animation
   - Preferred for state-driven animations

Rule: prefer explicit. Use implicit only for continuous values (sliders, progress bars).
```

---

## Step 1 — Spring physics + card flip (~15 min)

```swift
// CardFlipDemo.swift
import SwiftUI

struct CardFlipDemo: View {
    @State private var isFlipped = false
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("Tap to flip")
                .font(.caption)
                .foregroundStyle(.secondary)

            ZStack {
                // Front
                CardFace(color: .blue, label: "Front 🂡")
                    .opacity(isFlipped ? 0 : 1)

                // Back
                CardFace(color: .red, label: "Back 🃏")
                    .opacity(isFlipped ? 1 : 0)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
            .rotation3DEffect(
                .degrees(rotation),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.4
            )
            .onTapGesture {
                // ★ Explicit animation with spring physics
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    rotation += 180
                    isFlipped.toggle()
                }
            }

            // Spring parameter explorer
            VStack(alignment: .leading) {
                Text("Spring physics:").font(.caption.bold())
                Text("• response: how fast (lower = faster)")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("• dampingFraction: bounciness (1.0 = no bounce)")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("• blendDuration: how animations chain")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct CardFace: View {
    let color: Color
    let label: String

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(color.gradient)
            .frame(width: 200, height: 130)
            .overlay(Text(label).font(.title.bold()).foregroundStyle(.white))
            .shadow(radius: 8)
    }
}
```

---

## Step 2 — `matchedGeometryEffect` shared element (~15 min)

```swift
// SharedElementDemo.swift
import SwiftUI

// matchedGeometryEffect: smoothly morphs a view between two positions
// Both views share the same ID + namespace — SwiftUI interpolates between them

struct SharedElementDemo: View {
    @Namespace private var ns
    @State private var isExpanded = false

    let items = ["🎸", "🎹", "🥁", "🎺", "🎻"]
    @State private var selectedItem: String? = nil

    var body: some View {
        ZStack {
            if let selected = selectedItem {
                // Expanded detail view
                VStack {
                    Text(selected)
                        .font(.system(size: 100))
                        .matchedGeometryEffect(id: selected, in: ns)
                        .frame(width: 200, height: 200)
                        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 24))

                    Text("Tap to collapse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        selectedItem = nil
                    }
                }
            } else {
                // Grid of items
                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3)) {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(.system(size: 44))
                            .matchedGeometryEffect(id: item, in: ns)
                            .frame(width: 80, height: 80)
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 16))
                            .onTapGesture {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    selectedItem = item
                                }
                            }
                    }
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: selectedItem)
    }
}
```

---

## Step 3 — Phase animation (multi-step state machine) (~10 min)

```swift
// PhaseAnimationDemo.swift
import SwiftUI

// PhaseAnimator (iOS 17): drive through a sequence of values automatically
// Great for: loading indicators, success/error states, tutorials

struct PhaseAnimationDemo: View {
    @State private var trigger = false

    var body: some View {
        VStack(spacing: 24) {
            // PhaseAnimator sequences through an array of values
            PhaseAnimator([false, true, false], trigger: trigger) { isHighlighted in
                ZStack {
                    Circle()
                        .fill(isHighlighted ? Color.green : Color.gray.opacity(0.2))
                        .frame(width: 80, height: 80)
                    Image(systemName: isHighlighted ? "checkmark" : "circle")
                        .font(.title)
                        .foregroundStyle(isHighlighted ? .white : .secondary)
                        .scaleEffect(isHighlighted ? 1.3 : 1.0)
                }
            } animation: { phase in
                // Each phase can have a different animation curve
                phase ? .spring(duration: 0.3) : .easeOut(duration: 0.5)
            }

            Button("Animate") {
                trigger.toggle()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
```

---

## Step 4 — Keyframe animation (iOS 17) (~10 min)

```swift
// KeyframeDemo.swift
import SwiftUI

// KeyframeAnimator: CSS-keyframe style, full control over timing per property
// Unlike spring, you specify exactly what value at what relative time

struct AnimationValues {
    var scale: Double = 1.0
    var verticalOffset: Double = 0
    var rotation: Angle = .zero
}

struct KeyframeDemo: View {
    @State private var trigger = false

    var body: some View {
        VStack(spacing: 24) {
            KeyframeAnimator(initialValue: AnimationValues(), trigger: trigger) { values in
                RocketView()
                    .scaleEffect(values.scale)
                    .offset(y: values.verticalOffset)
                    .rotationEffect(values.rotation)
            } keyframes: { _ in
                KeyframeTrack(\.verticalOffset) {
                    LinearKeyframe(0, duration: 0.1)
                    SpringKeyframe(-20, duration: 0.2, spring: .bouncy)
                    LinearKeyframe(-100, duration: 0.3)
                    LinearKeyframe(0, duration: 0.3)
                }
                KeyframeTrack(\.scale) {
                    LinearKeyframe(1.0, duration: 0.1)
                    SpringKeyframe(1.3, duration: 0.2, spring: .bouncy)
                    LinearKeyframe(0.8, duration: 0.3)
                    SpringKeyframe(1.0, duration: 0.3)
                }
                KeyframeTrack(\.rotation) {
                    LinearKeyframe(.zero, duration: 0.1)
                    LinearKeyframe(.degrees(-15), duration: 0.2)
                    LinearKeyframe(.degrees(15), duration: 0.3)
                    SpringKeyframe(.zero, duration: 0.3)
                }
            }

            Button("Launch 🚀") { trigger.toggle() }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct RocketView: View {
    var body: some View {
        Text("🚀").font(.system(size: 60))
    }
}
```

---

## Step 5 — Custom `Animatable` shape (~10 min)

```swift
// AnimatableShape.swift
import SwiftUI

// Animatable protocol: tell SwiftUI how to interpolate your custom type
// The `animatableData` property is what gets tweened

struct WaveShape: Shape, Animatable {
    var amplitude: Double     // height of waves
    var frequency: Double     // number of waves

    // AnimatablePair lets you animate two values together
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(amplitude, frequency) }
        set { amplitude = newValue.first; frequency = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let midY = height / 2

        path.move(to: CGPoint(x: 0, y: midY))

        for x in stride(from: 0, through: width, by: 1) {
            let angle = (x / width) * frequency * 2 * .pi
            let y = midY + amplitude * sin(angle)
            path.addLine(to: CGPoint(x: x, y: y))
        }

        // Close bottom
        path.addLine(to: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }
}

struct AnimatableShapeDemo: View {
    @State private var amplitude: Double = 20
    @State private var frequency: Double = 3

    var body: some View {
        VStack(spacing: 24) {
            WaveShape(amplitude: amplitude, frequency: frequency)
                .fill(Color.blue.gradient)
                .frame(height: 120)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: amplitude)
                .onAppear { amplitude = 40; frequency = 6 }

            VStack {
                Text("Custom Animatable shape")
                    .font(.caption.bold())
                Text("Amplitude and frequency both animated simultaneously")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

---

## Full content view

```swift
// ContentView.swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Card flip (spring)") { CardFlipDemo() }
                Section("Shared element (matchedGeometryEffect)") { SharedElementDemo() }
                Section("Phase animation (iOS 17)") { PhaseAnimationDemo() }
                Section("Keyframe animation (iOS 17)") { KeyframeDemo() }
                Section("Custom Animatable shape") { AnimatableShapeDemo() }
            }
            .navigationTitle("AnimationKit")
        }
    }
}
```

---

## ★ Challenge

Build a **hero image transition** between a grid of thumbnails and a full-screen detail view, using `matchedGeometryEffect` with a `NavigationStack` push transition. Hint: use `.navigationTransition(.zoom(sourceID:in:))` (iOS 18) or a manual `ZStack` + `matchedGeometryEffect` approach for iOS 17.

---

## Key concepts to remember

**`withAnimation` scope:** Only changes made INSIDE the `withAnimation {}` block are animated. A common bug is mutating state outside it and wondering why nothing animates.

**Transitions vs animations:** `.animation` tweens a view's properties. `.transition` defines how a view enters/exits the hierarchy (insert/remove). They're orthogonal.

**`matchedGeometryEffect` gotcha:** Both the source and destination views must be present simultaneously in the view hierarchy. Use a `ZStack` with conditional visibility if needed.

**Spring response vs duration:** `.spring(response:dampingFraction:)` — `response` is roughly the period (0.3 = snappy, 0.8 = slow). Higher `dampingFraction` = less bounce (1.0 = critically damped, no bounce).

---

## Follow-up questions

- *What's the difference between `.animation(.spring, value:)` and `withAnimation(.spring) {}`?* (Former is implicit — applies to the specific value change; latter is explicit — applies to all state mutations inside the block)
- *How do you animate between two different view types?* (`AnyTransition.asymmetric` or `matchedGeometryEffect`)
- *What is `GeometryEffect`?* (A way to animate view transforms imperatively — more powerful than built-in modifiers but rarely needed)
