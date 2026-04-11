# Tutorial 30 — Xcode Instruments: Profiling & Performance
## Profile: PerfKit (from Tutorial 29)
**Time:** 60 min | **Topics:** Time Profiler, Allocations, Leaks, Core Animation / Hangs, SwiftUI View Body, Network, Energy, Signposts

---

## Setup

### Always profile on a real device
Simulator uses the Mac's CPU and memory allocator — measurements are not representative. Every Instruments session should be on a physical iPhone.

### Build for profiling, not debug
```
Product → Profile (⌘I)
```
This compiles with Release optimizations + debug symbols. Debug builds include extra SwiftUI overhead and ARC instrumentation that distorts results.

### Disable Metal Validation for realistic GPU numbers
```
Edit Scheme → Run → Diagnostics → uncheck "Metal API Validation"
```

---

## The five instruments you'll use in every investigation

| Instrument | Answers | Use when |
|---|---|---|
| **Time Profiler** | Where is CPU time going? | Jank, slow screens, sluggish transitions |
| **Allocations** | What's on the heap and when? | High memory, slow launches |
| **Leaks** | What's never freed? | Memory climbing over time |
| **Hangs** | What's blocking the main thread? | UI freezes, non-responsive touches |
| **SwiftUI** | Which views re-render and why? | Unexpected redraws, list thrashing |

---

## Instrument 1 — Time Profiler

**Answers**: what code is consuming CPU cycles.

### How to read it

```
Timeline bar graph — CPU usage over time
    Click a spike → flame chart appears below

Flame chart (Call Tree):
    Widest bars = most time
    Bottom = entry point (main), top = leaf (actual work)

Invert Call Tree (checkbox) → shows leaf functions first
    ↑ This is the setting you almost always want

Hide System Libraries (checkbox) → filters out Apple frameworks
    ↑ Turn this on to see only your code
```

### Workflow

1. Launch the app, start recording
2. Perform the slow action (e.g., scroll the feed, open a screen)
3. Stop recording
4. Enable: **Invert Call Tree** + **Hide System Libraries**
5. Look at the top entries — those are your hotspots

### Common findings and fixes

| Finding | Fix |
|---|---|
| `JSONDecoder.decode` in call stack | Move decoding off `@MainActor` (Tutorial 29 §3) |
| `UIImage(data:)` or `CGImageSource` | Decode images on background thread |
| `String.localizedCaseInsensitiveContains` | Move filtering to a dedicated `actor` |
| Repeated `body` calls on the same view | Reduce `@Observable` scope or add `Equatable` |
| `layout` / `measure` in SwiftUI | Reduce nesting, use `fixedSize()` for static content |

---

## Instrument 2 — Allocations

**Answers**: what objects are being allocated, how large they are, and whether they're being freed.

### Key views

```
Summary → All Allocations
    Sort by "Bytes Used" descending → biggest consumers at top

Generation Analysis (the most powerful feature):
    1. Click "Mark Generation" before an action
    2. Perform the action (e.g., open/close a sheet 10 times)
    3. Click "Mark Generation" again
    4. Look at what grew — those objects weren't freed
```

### Workflow for launch time

1. Record from before launch
2. Stop after the first frame is visible
3. Filter by your module name in the search box
4. Sort by "Bytes Used" — identify large one-time allocations

### Common findings

| Finding | Fix |
|---|---|
| `[Article]` growing unboundedly | Add pagination (Tutorial 08) |
| `UIImage` never freed | Move to `NSCache` with cost limit |
| ViewModel allocated many times | Check for accidental re-init on re-render |
| `Data` objects from network | Process and discard immediately — don't store raw bytes |

---

## Instrument 3 — Leaks

**Answers**: which objects were allocated but can never be freed (retain cycles).

### Workflow

1. Profile with Leaks instrument
2. Interact with the app — open screens, go back, repeat
3. Watch for red marks in the timeline
4. Click a leak → **Cycles & Roots** tab → shows the retain cycle graph

### Reading the cycle graph

```
ViewController → closure → ViewController   (cycle)
         ↑ strong          ↑ strong capture of self

Fix: [weak self] in the closure
```

### Common sources of leaks

```swift
// 1. Delegate pattern — delegate should almost always be weak
class PlayerView: UIView {
    weak var delegate: PlayerViewDelegate?   // ✅ weak
}

// 2. Timer — holds strong reference to target
// ❌
let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    self.tick()   // strong capture
}

// ✅ Invalidate in deinit
deinit { timer.invalidate() }

// 3. NotificationCenter — remove observer in deinit (pre-iOS 14 patterns)
// Modern Swift: use .task {} or Combine — cleaned up automatically

// 4. Closures stored on class instances
final class ViewModel {
    var onComplete: (() -> Void)?

    func setup() {
        onComplete = { self.finish() }  // ❌ cycle: vm → closure → vm
        onComplete = { [weak self] in self?.finish() }  // ✅
    }
}
```

---

## Instrument 4 — Hangs

**Answers**: when did the main thread block, for how long, and what was it doing.

Xcode 15+ ships a **Hang** instrument that automatically marks hangs (>250 ms unresponsiveness).

### Workflow

1. Profile with the Hang instrument
2. Use the app normally — tap buttons, scroll, navigate
3. Red annotations appear on the timeline at hang locations
4. Click a hang → Time Profiler call stack for that period

### Common causes

```swift
// 1. Synchronous file IO on main thread
let data = try! Data(contentsOf: largeFileURL)   // blocks until done

// Fix: use async/await with FileManager in a Task

// 2. Synchronous database fetch on main thread
let results = try! context.fetch(descriptor)   // SwiftData fetch — fast, but not zero

// Fix: fetch in a Task, publish results to @MainActor

// 3. Image scaling without deferring
let scaled = image.preparingThumbnail(of: CGSize(width: 200, height: 200))
// ↑ Can be slow for large images — call in a Task

// 4. String operations on large sets
let sorted = thousandStrings.sorted()   // O(n log n) on main thread
```

### The 16 ms rule

At 60 Hz, each frame has 16 ms to complete. At 120 Hz (ProMotion), 8 ms. Any synchronous work on the main thread that exceeds this budget drops a frame.

---

## Instrument 5 — SwiftUI (View Body Lifetime)

**Answers**: which views are re-rendering, how often, and why.

### Setup

Instruments → New Trace → Add instrument: **SwiftUI**

Or faster: **Xcode → Debug → SwiftUI → Enable View Body Profiling** (iOS 17+)

### Reading the output

```
View Body Invocations timeline:
    Each bar = one view's body called
    Tall bars = expensive body
    Frequent bars = unnecessary re-renders

Click a bar → shows the view type + which input changed
```

### Workflow

1. Profile with SwiftUI instrument
2. Perform a single action (e.g., type one character in a search field)
3. Count how many view bodies fired
4. Identify views that fired but shouldn't have

### Reducing renders — practical fixes

```swift
// ❌ Fat observable — any property change re-renders all observers
@Observable final class AppModel {
    var query: String = ""
    var articles: [Article] = []
    var selectedTab: Int = 0
}
struct SearchBar: View {
    var model: AppModel   // re-renders when articles change
    ...
}

// ✅ Extract relevant slice
@Observable final class SearchModel { var query: String = "" }
struct SearchBar: View {
    var searchModel: SearchModel   // only re-renders on query change
    ...
}

// ✅ Use Equatable on rows
struct ArticleRow: View, Equatable {
    let article: Article
    // body only called when article actually changes
}
```

---

## Signposts — mark your own events in Instruments

Signposts let you annotate the Instruments timeline with your own events. They appear in the **Points of Interest** track and correlate with other instruments.

```swift
// SignpostLogger.swift
import os

extension Logger {
    static let feed = Logger(subsystem: "com.example.perfkit", category: "Feed")
}

// In your code — mark the boundaries of interesting work
func load() async {
    let signpostID = OSSignpostID(log: .default)

    os_signpost(.begin, log: .default, name: "FeedLoad", signpostID: signpostID)

    let articles = try? await service.fetchArticles()

    os_signpost(.end, log: .default, name: "FeedLoad", signpostID: signpostID)

    state.articles = articles ?? []
}

// Swift 5.9+ (preferred):
func load() async {
    Logger.feed.debug("Feed load started")
    // ... work ...
    Logger.feed.debug("Feed load finished — \(articles.count) articles")
}
```

In Instruments: **Points of Interest** instrument shows your signpost ranges as colored bars. Drag to select a range → all other instruments zoom to that window.

---

## Energy Log — battery usage

**Found in**: Instruments → Energy Log, or **Xcode Organizer → Energy** for shipped apps.

### What drains battery

| Resource | Cost | Mitigation |
|---|---|---|
| Continuous GPS | Very high | Use `significantLocationChanges` not `startUpdatingLocation` |
| Background fetch | Medium | Use `BGAppRefreshTask`, not timers |
| Bluetooth scan | High | Stop scanning when not needed |
| Display at full brightness | High | Respect system brightness, dim inactive UI |
| Network (cellular vs WiFi) | High (cellular) | Batch requests, cache aggressively |
| CPU at 100% | High | Move work off main, reduce background processing |

```swift
// ✅ Use BGAppRefreshTask for background work — OS schedules it efficiently
import BackgroundTasks

BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.example.refresh") { task in
    task.expirationHandler = { task.setTaskCompleted(success: false) }
    Task {
        await DataStore.shared.refresh()
        task.setTaskCompleted(success: true)
    }
}
```

---

## Network instrument — request timing

**Found in**: Instruments → Network

Shows: DNS lookup, TCP handshake, TLS, request send, response receive — per request.

### What to look for

```
DNS lookup > 100ms → use URLSession with pre-warmed connections
                     or HTTP/3 (QUIC eliminates handshake latency)

Large response sizes → enable HTTP compression (Accept-Encoding: gzip)
                       or switch to a binary format (Protobuf, MessagePack)

Many small requests → batch or use HTTP/2 multiplexing

Slow first request → warm the connection with a preflight request
```

---

## Xcode Organizer — production data

**Xcode → Window → Organizer → Crashes / Hangs / Disk Writes / Regressions**

This shows anonymized, aggregated data from users who have opted in to share diagnostics. Available after ~24 hours on the App Store.

| Report | Tells you |
|---|---|
| **Crashes** | Top crash signatures — click for symbolicated stack trace |
| **Hangs** | Main thread blockages in production — real device, real conditions |
| **Disk Writes** | Excessive write amplification (SSD wear, battery drain) |
| **Regressions** | Metrics that worsened between versions |

This is the most valuable data you have — it reflects real usage, not your profiling scenarios.

---

## Profiling workflow end-to-end

```
1. Identify the problem
   - User report / Organizer hang or crash
   - Visible symptom: jank, freeze, high memory in Xcode debug navigator

2. Reproduce on a real device
   - Build for Profile (⌘I) on physical iPhone
   - Use Release + debug symbols

3. Choose the right instrument
   - Jank / slow screen → Time Profiler
   - Memory climbing → Allocations (Generation Analysis)
   - Objects never freed → Leaks
   - UI freeze → Hangs
   - Too many view updates → SwiftUI instrument

4. Isolate the hotspot
   - Invert Call Tree + Hide System Libraries (Time Profiler)
   - Filter by your module name (Allocations)
   - Look at Cycles & Roots (Leaks)

5. Fix, profile again, confirm improvement
   - Never guess — measure before and after
   - One change at a time so you know what helped

6. Set a baseline
   - Note: launch time, peak memory, scroll fps before shipping
   - Alert in CI if these regress (use MetricKit or XCTest Performance)
```

---

## MetricKit — production performance monitoring

```swift
// Subscribe to on-device metrics — delivered after each 24h period
import MetricKit

class MetricsSubscriber: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            if let launch = payload.applicationLaunchMetrics {
                let p50 = launch.histogrammedTimeToFirstDraw.bucketEnumerator
                // Log or upload to your analytics
            }
            if let memory = payload.memoryMetrics {
                let peak = memory.peakMemoryUsage
            }
        }
    }
}

// Register on launch:
MXMetricManager.shared.add(subscriber)
```

---

## XCTest performance tests — catch regressions in CI

```swift
// PerfKitPerformanceTests.swift
import XCTest
@testable import PerfKit

final class FeedPerformanceTests: XCTestCase {

    func testFeedFilteringPerformance() {
        let articles = (0..<1000).map {
            Article(id: "\($0)", title: "Article \($0)", source: "Source", publishedAt: Date())
        }
        let engine = FilterEngine()

        measure {
            // XCTest runs this 10 times, reports average + std dev
            Task {
                _ = await engine.filter(articles, query: "Article 5")
            }
        }
    }

    func testJSONDecodingPerformance() throws {
        let data = try JSONEncoder().encode((0..<1000).map {
            Article(id: "\($0)", title: "Title \($0)", source: "S", publishedAt: Date())
        })

        measure {
            _ = try? JSONDecoder().decode([Article].self, from: data)
        }
    }
}
```

Set a baseline with **Edit → Set Baseline** — CI fails if future runs exceed the baseline by more than the allowed deviation.

---

## Interview questions

| Question | Concept |
|---|---|
| "How do you find what's causing jank?" | Time Profiler — Invert Call Tree, Hide System Libraries |
| "What's Generation Analysis in Allocations?" | Mark before/after to see what wasn't freed between actions |
| "How do you find retain cycles?" | Leaks instrument → Cycles & Roots graph |
| "What blocks the main thread?" | Hangs instrument — any >16 ms synchronous work |
| "How do you know which SwiftUI views are over-rendering?" | SwiftUI instrument / View Body Profiling |
| "What are Signposts?" | `os_signpost` annotations — appear in Points of Interest track |
| "How do you track performance in production?" | Xcode Organizer, MetricKit, XCTest baselines |
| "Profile on simulator or device?" | Always real device — simulator uses Mac hardware |
