# Tutorial 10 — ZStack & GeometryReader
## Build: OverlayKit — cards, tooltips, and parallax scroll
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** ZStack depth, GeometryReader, coordinate spaces, ScrollView + GeometryReader, ViewThatFits

---

## What you'll build
Three demos:
1. Draggable card stack (ZStack + gesture)
2. Parallax hero header (ScrollView + GeometryReader)
3. Adaptive tooltip that avoids screen edges (GeometryReader coordinate spaces)

---

## ZStack vs overlay

```swift
// ZStack: multiple views share the same layout space
// Child views are centered by default
ZStack {
    Background()    // renders first (bottom)
    Content()       // renders on top
    FloatingButton()// renders on top of both
}

// .overlay: attach a view on top of ANOTHER view
// The base view determines size — overlay doesn't affect layout
RoundedRectangle(cornerRadius: 16)
    .fill(.blue)
    .overlay(alignment: .bottomTrailing) {
        Badge()  // doesn't affect the rect's size
    }

// Rule: use .overlay when the base view owns the size.
// Use ZStack when sizing should be negotiated between layers.
```

---

## GeometryReader gotcha

```swift
// GeometryReader expands to fill ALL available space (greedy)
// It breaks layouts when nested casually

// BAD: GeometryReader inside a VStack makes the VStack full-height
VStack {
    Text("Title")
    GeometryReader { _ in   // this takes ALL remaining height
        Text("Content")
    }
}

// GOOD: use .background GeometryReader to read size without affecting layout
Text("Content")
    .background {
        GeometryReader { proxy in
            Color.clear.onAppear {
                print(proxy.size)  // reads size without changing it
            }
        }
    }
```

---

## Step 1 — Draggable card stack (~15 min)

```swift
// CardStack.swift
import SwiftUI

struct CardData: Identifiable {
    let id = UUID()
    let color: Color
    let title: String
}

struct CardStack: View {
    @State private var cards: [CardData] = [
        CardData(color: .blue,   title: "Card 1"),
        CardData(color: .purple, title: "Card 2"),
        CardData(color: .orange, title: "Card 3"),
        CardData(color: .green,  title: "Card 4"),
    ]
    @State private var topOffset: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        ZStack {
            ForEach(Array(cards.enumerated().reversed()), id: \.element.id) { index, card in
                CardView(card: card)
                    .offset(
                        x: index == 0 ? topOffset.width : 0,
                        y: index == 0 ? topOffset.height : CGFloat(index) * 8
                    )
                    .rotationEffect(
                        index == 0
                            ? .degrees(Double(topOffset.width) / 20)
                            : .degrees(Double(index) * -2)
                    )
                    .scaleEffect(index == 0 ? 1.0 : 1.0 - CGFloat(index) * 0.04)
                    .zIndex(Double(cards.count - index))
                    .gesture(
                        index == 0 ? dragGesture : nil
                    )
                    .animation(.spring(duration: 0.3), value: topOffset)
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                topOffset = value.translation
                isDragging = true
            }
            .onEnded { value in
                let threshold: CGFloat = 120
                let didSwipe = abs(value.translation.width) > threshold ||
                               abs(value.translation.height) > threshold

                withAnimation(.spring(duration: 0.4)) {
                    if didSwipe {
                        // Fling card off screen then recycle to bottom
                        let direction: CGFloat = value.translation.width > 0 ? 1 : -1
                        topOffset = CGSize(width: direction * 500, height: value.translation.height)
                    } else {
                        topOffset = .zero
                    }
                }

                if didSwipe {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let top = cards.removeFirst()
                        cards.append(top)
                        topOffset = .zero
                    }
                }
                isDragging = false
            }
    }
}

struct CardView: View {
    let card: CardData

    var body: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(card.color.gradient)
            .frame(width: 300, height: 180)
            .overlay(
                Text(card.title)
                    .font(.title.bold())
                    .foregroundStyle(.white)
            )
            .shadow(radius: 8)
    }
}
```

---

## Step 2 — Parallax hero header (~15 min)

```swift
// ParallaxHeader.swift
import SwiftUI

struct ParallaxHeader: View {
    let title: String
    let imageColor: Color

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                // Hero section with parallax
                Section {
                    // Content rows
                    ForEach(0..<30, id: \.self) { i in
                        HStack {
                            Text("Item \(i + 1)")
                            Spacer()
                            Text("Detail")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        Divider()
                    }
                } header: {
                    // Sticky title
                    Text(title)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.ultraThinMaterial)
                } // end Section
            }
            // Parallax hero image ABOVE the LazyVStack
            .safeAreaInset(edge: .top, spacing: 0) {
                ParallaxHeroImage(color: imageColor)
            }
        }
    }
}

struct ParallaxHeroImage: View {
    let color: Color
    let height: CGFloat = 250

    var body: some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .scrollView).minY
            // As user scrolls down, minY becomes negative
            // Offset the image upward by half that amount → parallax
            let parallaxOffset = minY > 0 ? -minY * 0.5 : 0

            ZStack {
                color.gradient
                    .offset(y: parallaxOffset)
                    // Scale up when pulled down (rubber-band effect)
                    .scaleEffect(minY > 0 ? 1 + minY / height : 1)
                    .clipped()

                VStack {
                    Spacer()
                    Text("Hero Image")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .padding()
                }
            }
            .frame(height: max(height, height + max(0, minY)))
            .offset(y: min(0, -minY))  // prevents gap at top when scrolling up
        }
        .frame(height: height)
    }
}
```

---

## Step 3 — Smart tooltip that avoids edges (~15 min)

```swift
// SmartTooltip.swift
import SwiftUI

// ★ Coordinate spaces: .global = screen, .local = view, .named("X") = custom
// GeometryReader in .background reads the annotated view's frame

struct TooltipModifier: ViewModifier {
    let text: String
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    // Read the anchor view's frame in the GLOBAL coordinate space
                    let frame = proxy.frame(in: .global)
                    Color.clear
                        .overlay(alignment: .top) {
                            if isVisible {
                                Tooltip(text: text, anchorFrame: frame)
                                    .offset(y: -proxy.size.height - 8)
                                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
                            }
                        }
                }
            )
    }
}

struct Tooltip: View {
    let text: String
    let anchorFrame: CGRect

    @State private var tooltipWidth: CGFloat = 200
    private let screenWidth = UIScreen.main.bounds.width
    private let margin: CGFloat = 16

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.label), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(Color(.systemBackground))
            // Measure tooltip width
            .background(GeometryReader { p in
                Color.clear.onAppear { tooltipWidth = p.size.width }
            })
            // Shift horizontally to avoid screen edges
            .offset(x: horizontalOffset)
    }

    private var horizontalOffset: CGFloat {
        let idealCenter = anchorFrame.midX - tooltipWidth / 2
        let maxX = screenWidth - margin - tooltipWidth
        return max(margin - anchorFrame.minX, min(maxX - anchorFrame.minX, 0))
    }
}

extension View {
    func tooltip(_ text: String, isVisible: Bool) -> some View {
        modifier(TooltipModifier(text: text, isVisible: isVisible))
    }
}

// Demo view
struct TooltipDemo: View {
    @State private var showLeft  = false
    @State private var showRight = false
    @State private var showCenter = false

    var body: some View {
        VStack(spacing: 40) {
            HStack {
                Button("Left edge") { showLeft.toggle() }
                    .tooltip("This tooltip avoids the left edge", isVisible: showLeft)
                Spacer()
                Button("Right edge") { showRight.toggle() }
                    .tooltip("This tooltip avoids the right edge", isVisible: showRight)
            }
            .padding(.horizontal, 8)

            Button("Center") { showCenter.toggle() }
                .tooltip("Centered tooltip — no adjustment needed", isVisible: showCenter)
        }
        .animation(.spring(duration: 0.3), value: showLeft)
        .animation(.spring(duration: 0.3), value: showRight)
        .animation(.spring(duration: 0.3), value: showCenter)
    }
}
```

---

## ★ Challenge

Build a **floating action button** that reveals a radial menu when tapped:

```swift
struct RadialMenu: View {
    @State private var isExpanded = false
    let actions: [(icon: String, label: String)] = [
        ("camera.fill", "Camera"),
        ("photo.fill", "Gallery"),
        ("doc.fill", "Document"),
    ]

    // Use ZStack to layer buttons
    // Use GeometryReader to position at bottom-right with safe area respect
    // Animate with offset + opacity when isExpanded changes
}
```

---

## Key concepts to remember

**Coordinate spaces:** `.global` is screen coordinates. `.local` is relative to the view itself. `.named("scroll")` lets you name a container and read frames relative to it. Use `.named` for scroll-relative parallax — it's more reliable than `.global`.

**`GeometryReader` expansion:** It fills its parent. If you put it inside a `VStack`, it takes all remaining space. Use `.background { GeometryReader { } }` to read size without disturbing layout.

**`ZStack` alignment:** Default is `.center`. You can set `ZStack(alignment: .topLeading)` to change where children are placed. Each child can also use `.frame(alignment:)` independently.

---

## MVVM Integration: `send(_:)` for overlay and tooltip state

Overlay visibility, tooltip anchors, and card selections are state — they belong in the ViewModel:

```swift
// OverlayViewModel.swift
import Observation
import SwiftUI

enum OverlayAction: Sendable {
    case showTooltip(anchor: CGPoint, message: String)
    case hideTooltip
    case selectCard(id: UUID)
    case dismissCard
    case setParallaxOffset(CGFloat)
}

struct OverlayState: Equatable {
    struct TooltipInfo: Equatable {
        var anchor: CGPoint
        var message: String
    }
    var tooltip: TooltipInfo?           = nil
    var selectedCardID: UUID?           = nil
    var parallaxOffset: CGFloat         = 0
    var isTooltipVisible: Bool          { tooltip != nil }
}

@MainActor
@Observable
final class OverlayViewModel {
    private(set) var state = OverlayState()

    func send(_ action: OverlayAction) {
        switch action {
        case .showTooltip(let anchor, let message):
            withAnimation(.easeOut(duration: 0.2)) {
                state.tooltip = OverlayState.TooltipInfo(anchor: anchor, message: message)
            }
        case .hideTooltip:
            withAnimation(.easeIn(duration: 0.15)) { state.tooltip = nil }
        case .selectCard(let id):
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                state.selectedCardID = id
            }
        case .dismissCard:
            withAnimation(.spring) { state.selectedCardID = nil }
        case .setParallaxOffset(let offset):
            // No animation — drives a continuous scroll effect
            state.parallaxOffset = offset
        }
    }
}

// TooltipView.swift — modular, pure display
struct TooltipView: View {
    let info: OverlayState.TooltipInfo

    var body: some View {
        Text(info.message)
            .font(.caption)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 4)
            .position(info.anchor)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

// CardDetailOverlay.swift — modular expanded card
struct CardDetailOverlay: View {
    let cardID: UUID
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)
                .frame(width: 300, height: 400)
                .overlay(
                    Button("Close", action: onDismiss)
                        .padding()
                    , alignment: .topTrailing
                )
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

// MARK: — Swift Testing

import Testing
@testable import OverlayKit

@Suite("OverlayViewModel")
struct OverlayViewModelTests {

    @Test @MainActor
    func initialStateHasNoOverlays() {
        let vm = OverlayViewModel()
        #expect(!vm.state.isTooltipVisible)
        #expect(vm.state.selectedCardID == nil)
        #expect(vm.state.parallaxOffset == 0)
    }

    @Test @MainActor
    func showTooltipSetsInfo() {
        let vm = OverlayViewModel()
        vm.send(.showTooltip(anchor: CGPoint(x: 100, y: 200), message: "Hello"))
        #expect(vm.state.isTooltipVisible)
        #expect(vm.state.tooltip?.message == "Hello")
    }

    @Test @MainActor
    func hideTooltipClearsInfo() {
        let vm = OverlayViewModel()
        vm.send(.showTooltip(anchor: .zero, message: "Test"))
        vm.send(.hideTooltip)
        #expect(!vm.state.isTooltipVisible)
        #expect(vm.state.tooltip == nil)
    }

    @Test @MainActor
    func selectCardSetsID() {
        let vm = OverlayViewModel()
        let id = UUID()
        vm.send(.selectCard(id: id))
        #expect(vm.state.selectedCardID == id)
    }

    @Test @MainActor
    func dismissCardClearsSelection() {
        let vm = OverlayViewModel()
        vm.send(.selectCard(id: UUID()))
        vm.send(.dismissCard)
        #expect(vm.state.selectedCardID == nil)
    }

    @Test @MainActor
    func setParallaxOffsetUpdatesState() {
        let vm = OverlayViewModel()
        vm.send(.setParallaxOffset(42.5))
        #expect(vm.state.parallaxOffset == 42.5)
    }
}
```

---

## Follow-up questions

- *What's the difference between `.overlay` and `ZStack`?* (ZStack participates in layout sizing; overlay uses base view's size)
- *How do you avoid GeometryReader breaking your layout?* (`.background`, `.overlay`, or contain it in a `.frame`)
- *What's `ViewThatFits`?* (Tries each child in order and uses the first one that fits the available space — like CSS `min-content`)
- *Why keep tooltip anchor position in the ViewModel?* (It can be tested without rendering. In a real app it would come from a tap gesture location — the VM is notified, not the view. This also lets you debounce rapid tooltip changes in the VM, not the View.)
