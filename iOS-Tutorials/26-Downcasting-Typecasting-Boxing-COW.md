# Tutorial 26 — Downcasting, Typecasting, Boxing & Copy-on-Write
## Build: MediaKit — a type-safe heterogeneous media library
**Time:** 45 min | **Swift 6** | **Topics:** `is`, `as?`, `as!`, `as`, protocol existentials, boxing, value/reference semantics, COW

---

## What you'll build

A `MediaLibrary` that stores mixed media items (tracks, videos, podcasts) in a single collection, retrieves them with type-safe downcasting, and wraps expensive value types with Copy-on-Write so mutations stay cheap.

```
[any MediaItem]  →  as? Track       →  TrackPlayerViewModel
                 →  as? Video       →  VideoPlayerViewModel
                 →  as? Podcast     →  PodcastPlayerViewModel
```

---

## Part 1 — Typecasting

### `is` — type check (returns Bool)

```swift
let value: Any = "hello"
value is String    // true
value is Int       // false

// Common use: switch over heterogeneous collections
for item in mixedArray {
    if item is Track { ... }
}
```

### `as?` — conditional downcast (returns Optional)

```swift
// Safe — never crashes
let item: any MediaItem = Track(id: "1", title: "Song", duration: 180)
if let track = item as? Track {
    print(track.title)   // only runs when item IS a Track
}

// Preferred pattern in production code
guard let track = item as? Track else { return }
```

### `as!` — forced downcast (crashes on failure)

```swift
// Only use when you have a GUARANTEE the cast succeeds
// Wrong type at runtime = EXC_BAD_INSTRUCTION
let track = item as! Track   // crash if item is not a Track

// When is it acceptable?
// 1. Right after an `is` check (rare — just use as? instead)
// 2. Dequeuing cells: tableView.dequeueReusableCell(...) as! MyCell
//    — Xcode registers the class so the cast is guaranteed
// 3. NIB/storyboard outlets (the runtime guarantees the type)
```

### `as` — upcasting (always succeeds, no operator needed at runtime)

```swift
// Upcast: concrete type → protocol or superclass
// Compiler handles this — no runtime cost
let track = Track(id: "1", title: "Song", duration: 180)
let item: any MediaItem = track          // implicit upcast
let item2 = track as any MediaItem       // explicit — identical
let item3 = track as AnyObject           // bridge to ObjC existential
```

### `as` for bridging Swift ↔ Foundation

```swift
let swiftString: String = "hello"
let nsString = swiftString as NSString        // Swift → ObjC bridge
let backToSwift = nsString as String          // ObjC → Swift bridge

// Also used to silence ambiguity at call sites
let result = (someValue as NSString).lowercased
```

---

## Part 2 — Existentials & Type Erasure

### Protocol existentials (`any`)

```swift
// `any MediaItem` = a box that can hold ANY type conforming to MediaItem
// The runtime stores: [type metadata pointer | value buffer]
// Accessing a method goes through a "witness table" — slight overhead vs concrete type

var library: [any MediaItem] = []
library.append(Track(...))
library.append(Video(...))   // heterogeneous — this is the point

// Swift 6 requires the `any` keyword explicitly:
// var library: [MediaItem] = []    ← compiler error in Swift 5.7+
```

### `some` vs `any` — the critical distinction

```swift
// `some` = ONE specific concrete type, chosen at compile time
// Used in return positions — enables compiler optimizations
func nowPlaying() -> some MediaItem { ... }

// `any` = runtime existential box — type erased
// Required for heterogeneous storage or late-bound polymorphism
var queue: [any MediaItem] = [track, video, podcast]

// You CANNOT do:
// func nowPlaying() -> some MediaItem { if Bool.random() { return track } else { return video } }
// ↑ compile error — some must return ONE type
// Solution: return `any MediaItem` instead
```

---

## Part 3 — Boxing

Boxing = wrapping a value in a heap-allocated container. Swift does this automatically in two key cases:

### Existential boxing

```swift
// When you store a value type (struct) as a protocol existential,
// Swift may heap-allocate it if it doesn't fit in the inline buffer (3 words).

struct BigMetadata: MediaMetadata {
    var tags: [String]         // array = heap reference
    var description: String    // string = heap reference
    var custom: [String: Any]  // dictionary = heap reference
    // ← exceeds inline buffer → existential box goes to heap
}

struct SmallPoint: Equatable {
    var x: Double
    var y: Double
    // ← fits inline (2 words) → existential box stays on stack
}
```

### Manual boxing with a class wrapper (Reference Semantics on demand)

```swift
// Scenario: two ViewModels need to SHARE the same playback position.
// A struct won't work because copies diverge.
// Solution: wrap shared mutable state in a class.

final class PlaybackContext {
    var position: TimeInterval = 0
    var isPlaying: Bool = false
}

struct TrackPlayerViewModel {
    let track: Track
    let context: PlaybackContext   // shared reference — intentional

    // Both MiniPlayerViewModel and FullPlayerViewModel point to the same context
}
```

### `AnyObject` boxing

```swift
// AnyObject = any class instance (reference type)
// Useful for heterogeneous class collections without a shared base class

var delegates: [any AnyObject] = [coordinator, player, logger]

// Also used in weak collections (structs can't be weak)
var weakObservers: [WeakBox<any AnyObject>] = []

// WeakBox — a common pattern to hold weak references in an array
final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
```

---

## Part 4 — Copy-on-Write (COW)

### Value semantics without COW — the problem

```swift
// Every assignment copies the full buffer
var a = [1, 2, 3, 4, 5]   // heap-allocates buffer
var b = a                  // ← copies the buffer (O(n)) — expensive!
b.append(6)
// a = [1,2,3,4,5]  b = [1,2,3,4,5,6]  — independent, correct, but slow
```

### How COW works in the standard library

Swift's `Array`, `Dictionary`, `Set`, and `String` all use COW:

```swift
var a = [1, 2, 3]
var b = a            // no copy yet — a and b share the same buffer
                     // the buffer's reference count is now 2

b.append(4)          // mutation detected → refcount > 1 → copy NOW
                     // b gets its own buffer; a is unchanged
```

**Rule**: the copy is deferred until the first mutation. If you never mutate, you never pay for the copy.

### Building your own COW type

```swift
// Step 1: store data in a class (so it lives on the heap and can be shared)
private final class MediaBuffer {
    var items: [any MediaItem]
    init(_ items: [any MediaItem] = []) { self.items = items }
}

// Step 2: wrap in a struct with a mutating helper that checks uniqueness
struct MediaLibrary {
    private var buffer = MediaBuffer()

    // COW check — call before every mutation
    private mutating func ensureUniqueBuffer() {
        // isKnownUniquelyReferenced returns true ONLY if this struct
        // holds the sole strong reference to the buffer object.
        if !isKnownUniquelyReferenced(&buffer) {
            buffer = MediaBuffer(buffer.items)   // copy on write
        }
    }

    // Read — no copy, just forward
    var items: [any MediaItem] { buffer.items }
    var count: Int { buffer.items.count }

    // Write — check uniqueness first
    mutating func append(_ item: any MediaItem) {
        ensureUniqueBuffer()
        buffer.items.append(item)
    }

    mutating func remove(id: String) {
        ensureUniqueBuffer()
        buffer.items.removeAll { $0.id == id }
    }

    // Type-safe retrieval via downcast
    func items<T: MediaItem>(of type: T.Type) -> [T] {
        buffer.items.compactMap { $0 as? T }
    }

    func item(id: String) -> (any MediaItem)? {
        buffer.items.first { $0.id == id }
    }
}
```

### Why `isKnownUniquelyReferenced` matters

```swift
var lib1 = MediaLibrary()
lib1.append(Track(id: "1", title: "Song", duration: 180))

var lib2 = lib1        // lib1 and lib2 share the same MediaBuffer
                       // isKnownUniquelyReferenced → false for both

lib2.append(Video(id: "2", title: "Movie", duration: 7200))
// ↑ ensureUniqueBuffer() detects shared → copies buffer → lib2 gets own copy
// lib1.count == 1, lib2.count == 2  ✓
```

---

## Production models

```swift
// MediaItem.swift
import Foundation

protocol MediaItem: Identifiable, Sendable {
    var id: String { get }
    var title: String { get }
    var duration: TimeInterval { get }  // seconds
    var thumbnailURL: URL? { get }
}

struct Track: MediaItem {
    let id: String
    let title: String
    let duration: TimeInterval
    let artist: String
    let albumArt: URL?
    var thumbnailURL: URL? { albumArt }
}

struct Video: MediaItem {
    let id: String
    let title: String
    let duration: TimeInterval
    let resolution: String          // e.g. "1080p"
    let thumbnailURL: URL?
}

struct Podcast: MediaItem {
    let id: String
    let title: String
    let duration: TimeInterval
    let host: String
    let episodeNumber: Int
    var thumbnailURL: URL? { nil }
}
```

---

## ViewModel

```swift
// MediaLibraryViewModel.swift
import Foundation

// MARK: - Action / State

enum MediaLibraryAction: Sendable {
    case add(any MediaItem)
    case remove(id: String)
    case filter(MediaFilter)
    case select(id: String)
    case clearSelection
}

enum MediaFilter: String, CaseIterable, Sendable {
    case all, tracks, videos, podcasts
}

struct MediaLibraryState: Equatable {
    var filter: MediaFilter = .all
    var displayItems: [MediaRow] = []
    var selectedItem: MediaRow? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.filter == rhs.filter &&
        lhs.displayItems == rhs.displayItems &&
        lhs.selectedItem == rhs.selectedItem
    }
}

struct MediaRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String         // type-specific detail
    let durationLabel: String
    let kind: MediaFilter        // for icon/badge
}

// MARK: - Protocol

@MainActor
protocol MediaLibraryViewModelProtocol: AnyObject, Observable {
    var state: MediaLibraryState { get }
    func send(_ action: MediaLibraryAction)
}

// MARK: - ViewModel

@MainActor
@Observable
final class MediaLibraryViewModel: MediaLibraryViewModelProtocol {

    private(set) var state = MediaLibraryState()
    private var library = MediaLibrary()

    func send(_ action: MediaLibraryAction) {
        switch action {
        case .add(let item):        add(item)
        case .remove(let id):       remove(id: id)
        case .filter(let f):        applyFilter(f)
        case .select(let id):       select(id: id)
        case .clearSelection:       state.selectedItem = nil
        }
    }

    // MARK: - Private

    private func add(_ item: any MediaItem) {
        library.append(item)
        refreshDisplay()
    }

    private func remove(id: String) {
        library.remove(id: id)
        if state.selectedItem?.id == id { state.selectedItem = nil }
        refreshDisplay()
    }

    private func applyFilter(_ filter: MediaFilter) {
        state.filter = filter
        refreshDisplay()
    }

    private func select(id: String) {
        state.selectedItem = state.displayItems.first { $0.id == id }
    }

    private func refreshDisplay() {
        let all = library.items
        let filtered: [any MediaItem] = switch state.filter {
        case .all:      all
        case .tracks:   library.items(of: Track.self)
        case .videos:   library.items(of: Video.self)
        case .podcasts: library.items(of: Podcast.self)
        }
        state.displayItems = filtered.map(toRow)
    }

    // MARK: - Downcast to build display row

    private func toRow(_ item: any MediaItem) -> MediaRow {
        // Downcast to access type-specific fields
        let subtitle: String
        let kind: MediaFilter

        switch item {
        case let track as Track:
            subtitle = track.artist
            kind = .tracks
        case let video as Video:
            subtitle = video.resolution
            kind = .videos
        case let podcast as Podcast:
            subtitle = "Ep. \(podcast.episodeNumber) · \(podcast.host)"
            kind = .podcasts
        default:
            subtitle = ""
            kind = .all
        }

        return MediaRow(
            id: item.id,
            title: item.title,
            subtitle: subtitle,
            durationLabel: formatDuration(item.duration),
            kind: kind
        )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return m >= 60
            ? String(format: "%d:%02d:%02d", m / 60, m % 60, s)
            : String(format: "%d:%02d", m, s)
    }
}
```

---

## Views

```swift
// MediaLibraryView.swift
import SwiftUI

struct MediaLibraryView: View {
    @State private var vm: any MediaLibraryViewModelProtocol

    init(vm: any MediaLibraryViewModelProtocol) { self._vm = State(initialValue: vm) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FilterSegmentView(
                    selected: vm.state.filter,
                    onSelect: { vm.send(.filter($0)) }
                )
                MediaRowList(
                    rows: vm.state.displayItems,
                    onSelect: { vm.send(.select(id: $0)) },
                    onDelete: { vm.send(.remove(id: $0)) }
                )
            }
            .navigationTitle("Library")
            .sheet(item: Binding(
                get: { vm.state.selectedItem },
                set: { if $0 == nil { vm.send(.clearSelection) } }
            )) { row in
                MediaDetailSheet(row: row)
            }
        }
    }
}

struct FilterSegmentView: View {
    let selected: MediaFilter
    let onSelect: (MediaFilter) -> Void

    var body: some View {
        Picker("Filter", selection: Binding(get: { selected }, set: onSelect)) {
            ForEach(MediaFilter.allCases, id: \.self) { filter in
                Text(filter.rawValue.capitalized).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding()
    }
}

struct MediaRowList: View {
    let rows: [MediaRow]
    let onSelect: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        List(rows) { row in
            MediaRowView(row: row)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(row.id) }
                .swipeActions { Button("Delete", role: .destructive) { onDelete(row.id) } }
        }
        .listStyle(.plain)
    }
}

struct MediaRowView: View {
    let row: MediaRow

    var body: some View {
        HStack(spacing: 12) {
            MediaKindBadge(kind: row.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.headline)
                Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.durationLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct MediaKindBadge: View {
    let kind: MediaFilter

    var body: some View {
        Image(systemName: icon)
            .frame(width: 32, height: 32)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(color)
    }

    private var icon: String {
        switch kind {
        case .tracks:   "music.note"
        case .videos:   "play.rectangle"
        case .podcasts: "mic"
        case .all:      "square.grid.2x2"
        }
    }

    private var color: Color {
        switch kind {
        case .tracks:   .purple
        case .videos:   .blue
        case .podcasts: .orange
        case .all:      .gray
        }
    }
}

struct MediaDetailSheet: View {
    let row: MediaRow

    var body: some View {
        VStack(spacing: 16) {
            MediaKindBadge(kind: row.kind)
            Text(row.title).font(.title2.bold())
            Text(row.subtitle).foregroundStyle(.secondary)
            Text(row.durationLabel).font(.caption.monospacedDigit())
        }
        .padding()
        .presentationDetents([.medium])
    }
}
```

---

## Tests

```swift
// MediaLibraryTests.swift
import Testing
@testable import MediaKit

// MARK: - Fixtures

private let track = Track(id: "t1", title: "Song", duration: 210, artist: "Artist", albumArt: nil)
private let video = Video(id: "v1", title: "Movie", duration: 5400, resolution: "4K", thumbnailURL: nil)
private let podcast = Podcast(id: "p1", title: "Show", duration: 3600, host: "Host", episodeNumber: 42)

// MARK: - Downcast tests

@Suite("Downcast")
struct DowncastTests {

    @Test func asQuestionMarkSucceedsForMatchingType() {
        let item: any MediaItem = track
        let result = item as? Track
        #expect(result != nil)
        #expect(result?.artist == "Artist")
    }

    @Test func asQuestionMarkReturnsNilForWrongType() {
        let item: any MediaItem = track
        #expect(item as? Video == nil)
        #expect(item as? Podcast == nil)
    }

    @Test func isCheckCorrectlyIdentifiesType() {
        let item: any MediaItem = video
        #expect(item is Video)
        #expect(!(item is Track))
    }

    @Test func switchDowncastCoversAllCases() {
        let items: [any MediaItem] = [track, video, podcast]
        var kinds: [String] = []
        for item in items {
            switch item {
            case is Track:   kinds.append("track")
            case is Video:   kinds.append("video")
            case is Podcast: kinds.append("podcast")
            default:         kinds.append("unknown")
            }
        }
        #expect(kinds == ["track", "video", "podcast"])
    }
}

// MARK: - COW tests

@Suite("MediaLibrary COW")
struct MediaLibraryCOWTests {

    @Test func appendAddsItem() {
        var lib = MediaLibrary()
        lib.append(track)
        #expect(lib.count == 1)
    }

    @Test func copyDoesNotShareAfterMutation() {
        var lib1 = MediaLibrary()
        lib1.append(track)

        var lib2 = lib1              // shared buffer at this point
        lib2.append(video)           // triggers COW copy

        #expect(lib1.count == 1)     // lib1 unchanged
        #expect(lib2.count == 2)     // lib2 got its own copy
    }

    @Test func readDoesNotTriggerCopy() {
        var lib1 = MediaLibrary()
        lib1.append(track)
        let lib2 = lib1

        // Both read the same count — no mutation, no copy
        #expect(lib1.count == lib2.count)
    }

    @Test func removeDecreasesCount() {
        var lib = MediaLibrary()
        lib.append(track)
        lib.append(video)
        lib.remove(id: track.id)
        #expect(lib.count == 1)
        #expect(lib.item(id: track.id) == nil)
    }

    @Test func removeNonexistentIDIsNoop() {
        var lib = MediaLibrary()
        lib.append(track)
        lib.remove(id: "does-not-exist")
        #expect(lib.count == 1)
    }

    @Test func typedRetrievalReturnsonlyMatchingType() {
        var lib = MediaLibrary()
        lib.append(track)
        lib.append(video)
        lib.append(podcast)

        #expect(lib.items(of: Track.self).count == 1)
        #expect(lib.items(of: Video.self).count == 1)
        #expect(lib.items(of: Podcast.self).count == 1)
    }

    @Test func typedRetrievalReturnsEmptyWhenNoMatch() {
        var lib = MediaLibrary()
        lib.append(video)
        #expect(lib.items(of: Track.self).isEmpty)
    }
}

// MARK: - ViewModel tests

@Suite("MediaLibraryViewModel")
@MainActor
struct MediaLibraryViewModelTests {

    func makeVM() -> MediaLibraryViewModel { MediaLibraryViewModel() }

    @Test func initialStateIsEmpty() {
        let vm = makeVM()
        #expect(vm.state.displayItems.isEmpty)
        #expect(vm.state.filter == .all)
    }

    @Test func addingItemAppearsInDisplay() {
        let vm = makeVM()
        vm.send(.add(track))
        #expect(vm.state.displayItems.count == 1)
        #expect(vm.state.displayItems[0].title == track.title)
    }

    @Test func removingItemDisappearsFromDisplay() {
        let vm = makeVM()
        vm.send(.add(track))
        vm.send(.remove(id: track.id))
        #expect(vm.state.displayItems.isEmpty)
    }

    @Test func filterTracksShowsOnlyTracks() {
        let vm = makeVM()
        vm.send(.add(track))
        vm.send(.add(video))
        vm.send(.add(podcast))
        vm.send(.filter(.tracks))
        #expect(vm.state.displayItems.count == 1)
        #expect(vm.state.displayItems[0].kind == .tracks)
    }

    @Test func filterAllRestoresFullList() {
        let vm = makeVM()
        vm.send(.add(track))
        vm.send(.add(video))
        vm.send(.filter(.videos))
        vm.send(.filter(.all))
        #expect(vm.state.displayItems.count == 2)
    }

    @Test func selectingItemSetsSelectedState() {
        let vm = makeVM()
        vm.send(.add(track))
        vm.send(.select(id: track.id))
        #expect(vm.state.selectedItem?.id == track.id)
    }

    @Test func clearSelectionNilsSelectedItem() {
        let vm = makeVM()
        vm.send(.add(track))
        vm.send(.select(id: track.id))
        vm.send(.clearSelection)
        #expect(vm.state.selectedItem == nil)
    }

    @Test func removingSelectedItemClearsSelection() {
        let vm = makeVM()
        vm.send(.add(track))
        vm.send(.select(id: track.id))
        vm.send(.remove(id: track.id))
        #expect(vm.state.selectedItem == nil)
    }

    @Test func trackRowSubtitleIsArtist() {
        let vm = makeVM()
        vm.send(.add(track))
        #expect(vm.state.displayItems[0].subtitle == track.artist)
    }

    @Test func videoRowSubtitleIsResolution() {
        let vm = makeVM()
        vm.send(.add(video))
        #expect(vm.state.displayItems[0].subtitle == video.resolution)
    }

    @Test func podcastRowSubtitleContainsEpisodeAndHost() {
        let vm = makeVM()
        vm.send(.add(podcast))
        let subtitle = vm.state.displayItems[0].subtitle
        #expect(subtitle.contains("42"))
        #expect(subtitle.contains("Host"))
    }

    @Test func durationFormatsMinutesAndSeconds() {
        let vm = makeVM()
        vm.send(.add(track))   // 210s = 3:30
        #expect(vm.state.displayItems[0].durationLabel == "3:30")
    }

    @Test func durationFormatsHoursWhenLong() {
        let vm = makeVM()
        vm.send(.add(video))   // 5400s = 1:30:00
        #expect(vm.state.displayItems[0].durationLabel == "1:30:00")
    }
}
```

---

## Cheat sheet

### Casting operators

| Operator | Returns | Crashes? | Use when |
|---|---|---|---|
| `is` | `Bool` | Never | Type check only |
| `as?` | `Optional<T>` | Never | Safe downcast — prefer this |
| `as!` | `T` | Yes, on failure | Guaranteed cast (cell dequeue, outlets) |
| `as` | `T` | Never | Upcast or bridge (compiler verifies) |

### Boxing

| Kind | What's boxed | Where | Use when |
|---|---|---|---|
| Existential (`any P`) | Value + type metadata | Stack (small) / Heap (large) | Heterogeneous collections |
| Class wrapper | Shared mutable state | Heap | Multiple owners need the same reference |
| `AnyObject` | Any class instance | Heap | Weak references, ObjC interop |

### COW rules

```
1. Store mutable data in a private class (heap-allocated buffer)
2. All reads go through the class — no copy
3. Call isKnownUniquelyReferenced(&buffer) before every mutation
4. If NOT unique → copy the buffer, then mutate
5. Never expose the buffer class publicly — callers see only the struct
```

### Common mistakes

```swift
// ❌ Force-downcasting a protocol existential without a guarantee
let item: any MediaItem = podcast
let track = item as! Track   // crash

// ✅ Always guard with as?
guard let track = item as? Track else { return }

// ❌ Forgetting isKnownUniquelyReferenced — defeats the whole point
mutating func append(_ item: any MediaItem) {
    buffer.items.append(item)   // no COW check — shared buffer mutated!
}

// ✅ Check first
mutating func append(_ item: any MediaItem) {
    ensureUniqueBuffer()
    buffer.items.append(item)
}

// ❌ Using `any` where `some` is enough (unnecessary existential overhead)
func currentItem() -> any MediaItem { ... }   // if only ever returning one concrete type

// ✅ Use `some` for single-type opaque returns
func currentItem() -> some MediaItem { ... }
```

---

## Interview questions this covers

| Question | Concept |
|---|---|
| "What's the difference between `as?` and `as!`?" | Optional vs forced downcast |
| "When would you use `as!` safely?" | Cell dequeue, NIB outlets — guaranteed by runtime |
| "What is an existential type?" | `any P` — runtime box storing value + witness table |
| "What's the difference between `some` and `any`?" | Compile-time opaque vs runtime existential |
| "What is Copy-on-Write and how do you implement it?" | `isKnownUniquelyReferenced` + private class buffer |
| "Why does Swift Array copying not always allocate?" | COW — copy deferred until first mutation |
| "What is boxing in Swift?" | Heap-wrapping a value for shared reference semantics |
| "How do you safely store heterogeneous types in an array?" | Protocol existential `[any Protocol]` + `as?` on retrieval |
