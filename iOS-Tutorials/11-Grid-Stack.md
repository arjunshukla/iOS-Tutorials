# Tutorial 11 — Grid vs Stack in SwiftUI
## Build: LayoutLab — a visual layout explorer
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** HStack, VStack, LazyHStack, LazyVStack, Grid, LazyVGrid, LazyHGrid, Layout protocol

---

## What you'll build
A layout comparison app showing:
- When to use Stack vs Grid (performance + visual)
- `LazyVGrid` with adaptive columns (like App Store)
- `Grid` for table-like alignment (iOS 16+)
- Custom `Layout` protocol conformance

---

## Decision guide

```
HStack / VStack         → few items, no scroll, exact sizing
LazyHStack / LazyVStack → scrollable list, many items, defer rendering
Grid                    → table-like, rows + columns aligned, iOS 16+
LazyVGrid               → collections, adaptive columns, any count
LazyHGrid               → horizontal carousels, fixed row count
Custom Layout           → algorithm-defined positioning (word clouds, radial)
```

---

## Step 1 — Stack comparison (~10 min)

```swift
// StackComparison.swift
import SwiftUI

// ★ Key insight: HStack/VStack render ALL children immediately
// LazyHStack/LazyVStack render only visible children

struct StackComparison: View {
    var body: some View {
        VStack(spacing: 32) {

            // Regular VStack — all 1000 views created on appear
            // (avoid for large lists — use List or LazyVStack)
            VStack {
                Text("VStack (eager)")
                    .font(.caption.bold())
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<20, id: \.self) { i in
                            EagerRow(index: i)
                        }
                    }
                }
                .frame(height: 120)
                .border(Color.red, width: 1)
            }

            // LazyVStack — rows created on demand as they scroll into view
            VStack {
                Text("LazyVStack (lazy) ✓")
                    .font(.caption.bold())
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<1000, id: \.self) { i in
                            LazyRow(index: i)
                        }
                    }
                }
                .frame(height: 120)
                .border(Color.green, width: 1)
            }
        }
    }
}

struct EagerRow: View {
    let index: Int
    init(index: Int) {
        self.index = index
        // This initializer runs immediately for ALL rows in a VStack
    }
    var body: some View {
        Text("Row \(index)").padding(4)
    }
}

struct LazyRow: View {
    let index: Int
    init(index: Int) {
        self.index = index
        // This initializer ONLY runs when the row is about to appear
    }
    var body: some View {
        Text("Row \(index)").padding(4)
    }
}
```

---

## Step 2 — LazyVGrid with column strategies (~15 min)

```swift
// GridLayouts.swift
import SwiftUI

struct GridLayouts: View {
    @State private var selectedLayout = ColumnLayout.adaptive

    enum ColumnLayout: String, CaseIterable {
        case fixed    = "Fixed (3)"
        case flexible = "Flexible"
        case adaptive = "Adaptive"
    }

    private var columns: [GridItem] {
        switch selectedLayout {
        case .fixed:
            // Exactly 3 columns, each 1/3 of width
            return Array(repeating: GridItem(.fixed(100)), count: 3)

        case .flexible:
            // 2 columns that stretch to fill available width
            return Array(repeating: GridItem(.flexible(minimum: 100)), count: 2)

        case .adaptive:
            // ★ Most useful: as many columns as fit at minimum 80pt each
            // Automatically adapts to device width and orientation
            return [GridItem(.adaptive(minimum: 80, maximum: 120))]
        }
    }

    let items = (1...50).map { "Item \($0)" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Layout", selection: $selectedLayout) {
                ForEach(ColumnLayout.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items, id: \.self) { item in
                        GridCell(label: item)
                    }
                }
                .padding()
                .animation(.spring(duration: 0.4), value: selectedLayout)
            }
        }
    }
}

struct GridCell: View {
    let label: String

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.accentColor.opacity(0.15))
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                Text(label)
                    .font(.caption.bold())
                    .multilineTextAlignment(.center)
            )
    }
}
```

---

## Step 3 — `Grid` for table alignment (iOS 16+) (~10 min)

```swift
// AlignedGrid.swift
import SwiftUI

// Grid: every row has the same column widths (alignment guaranteed)
// Unlike LazyVGrid, Grid is eager — use for small tables

struct StatsTable: View {
    struct Row {
        let metric: String
        let value: String
        let change: Double
    }

    let rows: [Row] = [
        Row(metric: "Revenue",      value: "$1.2M",  change:  12.4),
        Row(metric: "Users",        value: "48,320", change:  -2.1),
        Row(metric: "Sessions",     value: "142K",   change:  31.0),
        Row(metric: "Avg. order",   value: "$24.90", change:   5.6),
        Row(metric: "Churn",        value: "1.8%",   change:  -0.3),
    ]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {

            // Header row
            GridRow {
                Text("Metric")   .font(.caption.bold()).foregroundStyle(.secondary)
                Text("Value")    .font(.caption.bold()).foregroundStyle(.secondary)
                Text("Change")   .font(.caption.bold()).foregroundStyle(.secondary)
            }

            Divider()
                .gridCellUnsizedAxes(.horizontal)  // ★ span all columns

            // Data rows
            ForEach(rows, id: \.metric) { row in
                GridRow {
                    Text(row.metric)

                    Text(row.value)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .gridColumnAlignment(.trailing)

                    HStack(spacing: 4) {
                        Image(systemName: row.change >= 0 ? "arrow.up" : "arrow.down")
                        Text(String(format: "%.1f%%", abs(row.change)))
                    }
                    .foregroundStyle(row.change >= 0 ? .green : .red)
                    .font(.caption.monospacedDigit())
                }
            }
        }
        .padding()
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
```

---

## Step 4 — Custom `Layout` protocol (iOS 16+) (~15 min)

```swift
// FlowLayout.swift
import SwiftUI

// Layout protocol: define your own positioning algorithm
// SwiftUI calls you with sizes + proposals → you return frames

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + max(0, CGFloat(rows.count - 1)) * spacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x: CGFloat
            switch alignment {
            case .leading:  x = bounds.minX
            case .center:   x = bounds.midX - row.width / 2
            case .trailing: x = bounds.maxX - row.width
            default:        x = bounds.minX
            }

            for item in row.items {
                let size = item.view.sizeThatFits(proposal)
                item.view.place(at: CGPoint(x: x, y: y), proposal: proposal)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(view: LayoutSubview, size: CGSize)]
        var height: CGFloat { items.map(\.size.height).max() ?? 0 }
        var width: CGFloat {
            let sizes = items.map(\.size.width).reduce(0, +)
            let gaps = CGFloat(max(0, items.count - 1)) * 8
            return sizes + gaps
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var currentRow = Row(items: [])
        var currentWidth: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(proposal)
            let neededWidth = currentWidth == 0 ? size.width : currentWidth + spacing + size.width

            if neededWidth > maxWidth && !currentRow.items.isEmpty {
                rows.append(currentRow)
                currentRow = Row(items: [])
                currentWidth = 0
            }

            currentRow.items.append((view, size))
            currentWidth = currentWidth == 0 ? size.width : currentWidth + spacing + size.width
        }

        if !currentRow.items.isEmpty { rows.append(currentRow) }
        return rows
    }
}

// Demo: Tag cloud using FlowLayout
struct TagCloud: View {
    let tags = ["Swift", "SwiftUI", "iOS", "Xcode", "Concurrency", "Actors",
                "Combine", "MVVM", "Core Data", "SwiftData", "Testing", "CI/CD"]

    var body: some View {
        FlowLayout(spacing: 8, alignment: .center) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.3)))
            }
        }
    }
}
```

---

## ★ Challenge

Build a **Pinterest-style masonry layout** using the `Layout` protocol:
- Two columns
- Items have variable heights
- Each new item goes into the shorter column

```swift
struct MasonryLayout: Layout {
    let columns: Int = 2
    var spacing: CGFloat = 8

    func sizeThatFits(...) -> CGSize { ... }
    func placeSubviews(...) { ... }
    // Hint: track columnHeights: [CGFloat] and place each new item in the shorter column
}
```

---

## Key concepts to remember

**LazyVGrid vs Grid:** `Grid` (eager, alignment-aware, table-like) vs `LazyVGrid` (lazy, adaptive columns, for large collections). For a settings screen with 10 rows: `Grid`. For an image gallery with 1000 items: `LazyVGrid`.

**`.adaptive(minimum:)`** is the App Store layout strategy — pack as many items as possible at the minimum size, grow to fill. It handles all device sizes automatically.

**Custom `Layout` replaces all manual `GeometryReader` hacks** for complex positioning. If you're using `GeometryReader` + `offset` to position children, the `Layout` protocol is almost certainly cleaner.

---

## Follow-up questions

- *When would you use `List` instead of `LazyVStack`?* (List gives you swipe-to-delete, drag reordering, section headers — but less layout flexibility)
- *What's the performance difference between `Grid` and nested `HStack/VStack`?* (Grid does a single layout pass with shared column widths; nested stacks do independent layout which misaligns columns)
- *What's `ViewThatFits` and when would you use it?* (Tries views in order and uses first that fits — great for responsive text that falls back to smaller version)
