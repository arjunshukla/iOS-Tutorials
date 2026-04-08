# Tutorial 07 — Caching
## Build: ImageCache — a multi-tier image cache (memory → disk → network)
**Time:** 60 min | **Swift 6** | **Topics:** NSCache, disk cache, cache eviction, TTL, cache stampede prevention

---

## What you'll build
A production image cache with:
- L1: `NSCache` (memory, automatic eviction)
- L2: Disk (file system, manual eviction by TTL)
- L3: Network (`URLSession`)
- Deduplication — one in-flight request per URL
- Cost-based eviction

---

## Cache hierarchy reasoning

```
Request image URL
    ↓
L1: NSCache (in-memory, ~100 images, instant)
    ↓ miss
L2: Disk (files in caches dir, ~1GB, fast)
    ↓ miss
L3: URLSession (network, ~500ms+)
    ↓ success
    → save to L2 disk
    → save to L1 memory
    → return to caller
```

---

## Step 1 — Cache entry model (~5 min)

```swift
// CacheEntry.swift
import Foundation
import UIKit

struct CacheEntry {
    let image: UIImage
    let url: URL
    let size: Int          // bytes — for cost tracking
    let cachedAt: Date
    let ttl: TimeInterval  // time-to-live

    var isExpired: Bool {
        Date.now.timeIntervalSince(cachedAt) > ttl
    }

    // NSCache uses `cost` to decide what to evict under memory pressure
    var cost: Int { size }

    init(image: UIImage, url: URL, ttl: TimeInterval = 300) {
        self.image = image
        self.url = url
        self.cachedAt = .now
        self.ttl = ttl
        // Estimate size: width * height * bytes per pixel
        self.size = Int(image.size.width * image.size.height * image.scale * 4)
    }
}
```

---

## Step 2 — Memory cache (L1) (~5 min)

```swift
// MemoryCache.swift
import UIKit

// NSCache: LRU-ish, cleared on memory warning, thread-safe
final class MemoryCache: @unchecked Sendable {

    private let cache = NSCache<NSString, MemoryEntry>()

    init(countLimit: Int = 100, totalCostLimit: Int = 50 * 1024 * 1024) { // 50MB
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func store(_ entry: CacheEntry) {
        let key = entry.url.absoluteString as NSString
        cache.setObject(MemoryEntry(entry: entry), forKey: key, cost: entry.cost)
    }

    func retrieve(url: URL) -> CacheEntry? {
        let key = url.absoluteString as NSString
        guard let obj = cache.object(forKey: key),
              !obj.entry.isExpired
        else {
            cache.removeObject(forKey: key)
            return nil
        }
        return obj.entry
    }

    func remove(url: URL) {
        cache.removeObject(forKey: url.absoluteString as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    // NSCache requires NSObject values
    private final class MemoryEntry: NSObject {
        let entry: CacheEntry
        init(entry: CacheEntry) { self.entry = entry }
    }
}
```

---

## Step 3 — Disk cache (L2) (~15 min)

```swift
// DiskCache.swift
import UIKit
import Foundation

actor DiskCache {

    private let directory: URL
    private let maxSizeBytes: Int
    private let defaultTTL: TimeInterval

    init(
        directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImageCache", isDirectory: true),
        maxSizeBytes: Int = 200 * 1024 * 1024,  // 200MB
        defaultTTL: TimeInterval = 86400          // 24 hours
    ) {
        self.directory = directory
        self.maxSizeBytes = maxSizeBytes
        self.defaultTTL = defaultTTL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func store(data: Data, for url: URL) throws {
        let path = filePath(for: url)
        try data.write(to: path, options: .atomic)
        // Set modification date — used for TTL check
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now],
            ofItemAtPath: path.path
        )
        // Evict old files if over size limit
        try evictIfNeeded()
    }

    func retrieve(url: URL) throws -> Data? {
        let path = filePath(for: url)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        // TTL check via modification date
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        if let modDate = attrs[.modificationDate] as? Date,
           Date.now.timeIntervalSince(modDate) > defaultTTL {
            try? FileManager.default.removeItem(at: path)
            return nil
        }

        return try Data(contentsOf: path)
    }

    func remove(url: URL) throws {
        try? FileManager.default.removeItem(at: filePath(for: url))
    }

    func removeExpired() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        for file in files {
            let attrs = try file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modDate = attrs.contentModificationDate,
               Date.now.timeIntervalSince(modDate) > defaultTTL {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func currentSizeBytes() throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )
        return try files.reduce(0) { total, file in
            let attrs = try file.resourceValues(forKeys: [.fileSizeKey])
            return total + (attrs.fileSize ?? 0)
        }
    }

    // MARK: - Private

    private func filePath(for url: URL) -> URL {
        // Stable hash of URL → filename
        let key = url.absoluteString.data(using: .utf8)!
            .map { String(format: "%02x", $0) }.joined()
            .prefix(64)  // limit filename length
        return directory.appendingPathComponent(String(key))
    }

    private func evictIfNeeded() throws {
        guard (try? currentSizeBytes() ?? 0) ?? 0 > maxSizeBytes else { return }

        // LRU eviction: delete oldest files first
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let sorted = try files.sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return dateA < dateB
        }
        var freed = 0
        let target = maxSizeBytes / 2  // free down to 50% of limit
        for file in sorted {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: file)
            freed += size
            if freed >= target { break }
        }
    }
}
```

---

## Step 4 — The full cache with deduplication (~15 min)

```swift
// ImageCache.swift
import UIKit

// ★ Key: deduplication prevents multiple network requests for same URL
// If 5 views all load the same image, only ONE network request fires
actor ImageCache {

    static let shared = ImageCache()

    private let memory = MemoryCache()
    private let disk = DiskCache()

    // In-flight requests — Task<UIImage, Error> shared across waiters
    private var inflight: [URL: Task<UIImage, Error>] = [:]

    func image(for url: URL) async throws -> UIImage {
        // L1: memory
        if let cached = memory.retrieve(url: url) {
            return cached.image
        }

        // L2: disk
        if let data = try? await disk.retrieve(url: url),
           let image = UIImage(data: data) {
            let entry = CacheEntry(image: image, url: url)
            memory.store(entry)
            return image
        }

        // Deduplication: reuse existing task if one is in-flight
        if let existing = inflight[url] {
            return try await existing.value
        }

        // L3: network
        let task = Task<UIImage, Error> {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else {
                throw CacheError.invalidImageData
            }
            // Populate caches on success
            try? await self.disk.store(data: data, for: url)
            let entry = CacheEntry(image: image, url: url)
            self.memory.store(entry)
            return image
        }

        inflight[url] = task

        defer { inflight[url] = nil }  // remove when done (success or failure)

        return try await task.value
    }

    func prefetch(urls: [URL]) {
        for url in urls {
            Task { try? await image(for: url) }
        }
    }

    func clearMemory() {
        memory.removeAll()
    }

    func clearAll() async throws {
        memory.removeAll()
        try await disk.removeExpired()
    }
}

enum CacheError: Error {
    case invalidImageData
}
```

---

## Step 5 — SwiftUI CachedImage view (~10 min)

```swift
// CachedImage.swift
import SwiftUI

struct CachedImage: View {
    let url: URL?
    let placeholder: Image

    @State private var phase: Phase = .loading

    enum Phase { case loading, loaded(UIImage), failed }

    var body: some View {
        ZStack {
            switch phase {
            case .loading:
                ProgressView()
                    .transition(.opacity)
            case .loaded(let uiImage):
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            case .failed:
                placeholder
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: phase == .loading)
        .task(id: url) {
            guard let url else { phase = .failed; return }
            do {
                let image = try await ImageCache.shared.image(for: url)
                phase = .loaded(image)
            } catch {
                phase = .failed
            }
        }
    }
}

extension CachedImage.Phase: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.failed, .failed): return true
        case (.loaded, .loaded): return true
        default: return false
        }
    }
}
```

---

## ★ Challenge

Implement a **cache stampede prevention** test:
- Create 10 concurrent tasks all requesting the same URL
- Assert only 1 network request was made
- Hint: inject a `requestCounter: Int` into `DiskCache` or mock `URLSession`

---

## Key concepts to remember

**NSCache vs Dictionary:** NSCache evicts automatically under memory pressure — you never hold a strong reference accidentally. Never use a plain `[URL: UIImage]` as an image cache.

**Cost limit:** `NSCache.totalCostLimit` in bytes. Set cost per image to `width × height × 4` (RGBA). This gives semantically meaningful memory management.

**Cache stampede:** 100 concurrent requests for the same uncached image → 100 network requests. Your `inflight` dictionary collapses these to 1. This is a critical correctness issue in feeds.

**Actor isolation:** `inflight` is actor-isolated, so concurrent checks and insertions are serialized. No race condition.

---

## Follow-up questions

- *Why not just use `URLCache`?* (URLCache is HTTP-cache-policy-based and doesn't give you control over memory pressure behavior or custom TTL)
- *What's an LRU eviction policy?* (Least Recently Used — evict the entry that was accessed furthest in the past; NSCache approximates this)
- *How would you handle animated GIFs?* (Store as `Data`, return `UIImage.animatedImage`; or use a separate GIF decoder actor)
