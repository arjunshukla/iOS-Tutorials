# Tutorial 05 — Reachability / Network Monitoring
## Build: NetworkAware — an app that gracefully degrades when offline
**Time:** 60 min | **Swift 6 + SwiftUI** | **Topics:** NWPathMonitor, Network.framework, AsyncStream, offline-first UX

---

## What you'll build
A network-aware app with:
- Real-time connectivity status using `NWPathMonitor`
- Wrapped in a Swift 6 actor for thread safety
- `AsyncStream` bridge for SwiftUI consumption
- Offline banner + cached content fallback

---

## Why not SCNetworkReachability?

`SCNetworkReachability` (old way) has problems:
- Callback-based, not concurrency-friendly
- Doesn't distinguish WiFi from cellular
- Doesn't report VPN/interface details

`NWPathMonitor` (Network.framework, iOS 12+):
- Gives `NWPath` with interface type, expensive status, DNS
- Works with async/await via bridging
- Detects satellite, VPN, constrained paths

---

## Step 1 — Network Monitor actor (~15 min)

```swift
// NetworkMonitor.swift
import Network
import Foundation

// Shared singleton — one monitor for the whole app
// @unchecked Sendable because we manage our own thread safety via the dispatch queue
final class NetworkMonitor: @unchecked Sendable {

    static let shared = NetworkMonitor()

    // Current status — safe to read from any thread after assignment
    private(set) var status: NetworkStatus = .unknown
    private(set) var path: NWPath?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.app.network-monitor", qos: .utility)

    // AsyncStream continuation for broadcasting to multiple observers
    private var continuations: [UUID: AsyncStream<NetworkStatus>.Continuation] = [:]
    private let lock = NSLock()

    private init() { start() }

    // MARK: - Control

    private func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let newStatus = NetworkStatus(path: path)
            self.path = path
            self.status = newStatus
            self.broadcast(newStatus)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    // MARK: - AsyncStream interface

    /// Returns an AsyncStream that emits NetworkStatus changes
    /// Multiple callers each get their own stream
    func statusStream() -> AsyncStream<NetworkStatus> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            // Immediately emit current status
            continuation.yield(status)
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    private func broadcast(_ status: NetworkStatus) {
        lock.lock()
        let conts = continuations.values
        lock.unlock()
        for cont in conts {
            cont.yield(status)
        }
    }
}

// MARK: - NetworkStatus

enum NetworkStatus: Equatable, Sendable {
    case unknown
    case connected(Interface)
    case disconnected
    case constrained   // Low Data Mode

    enum Interface: Equatable, Sendable {
        case wifi
        case cellular
        case wiredEthernet
        case loopback
        case other
    }

    init(path: NWPath) {
        switch path.status {
        case .satisfied:
            if path.usesInterfaceType(.wifi)     { self = .connected(.wifi) }
            else if path.usesInterfaceType(.cellular) { self = .connected(.cellular) }
            else if path.usesInterfaceType(.wiredEthernet) { self = .connected(.wiredEthernet) }
            else { self = .connected(.other) }
        case .unsatisfied:
            self = .disconnected
        case .requiresConnection:
            self = .constrained
        @unknown default:
            self = .unknown
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var icon: String {
        switch self {
        case .connected(.wifi):            return "wifi"
        case .connected(.cellular):       return "cellularbars"
        case .connected(.wiredEthernet):  return "cable.connector"
        case .connected:                  return "network"
        case .disconnected:               return "wifi.slash"
        case .constrained:                return "wifi.exclamationmark"
        case .unknown:                    return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .connected(.wifi):            return "Wi-Fi"
        case .connected(.cellular):       return "Cellular"
        case .connected(.wiredEthernet):  return "Ethernet"
        case .connected:                  return "Connected"
        case .disconnected:               return "No connection"
        case .constrained:                return "Low Data Mode"
        case .unknown:                    return "Checking…"
        }
    }
}
```

---

## Step 2 — State + ViewModel with `send(_:)` (~10 min)

```swift
// ConnectivityViewModel.swift
import Observation
import SwiftUI

// ★ Actions — all user/system intents modeled as enum cases
enum ConnectivityAction: Sendable {
    case startMonitoring
    case stopMonitoring
    case dismissBanner
}

// ★ All view state in one Equatable struct
struct ConnectivityState: Equatable {
    var networkStatus: NetworkStatus      = .unknown
    var isBannerVisible: Bool             = false
    var wasOffline: Bool                  = false

    var isOnWifi: Bool {
        networkStatus == .connected(.wifi) || networkStatus == .connected(.wiredEthernet)
    }
    var isExpensive: Bool { networkStatus == .connected(.cellular) }
}

// ★ Protocol for injectable monitor (testable without real NWPathMonitor)
protocol NetworkMonitorProtocol: Sendable {
    func statusStream() -> AsyncStream<NetworkStatus>
    var status: NetworkStatus { get }
}
extension NetworkMonitor: NetworkMonitorProtocol {}

@MainActor
protocol ConnectivityViewModelProtocol: AnyObject {
    var state: ConnectivityState { get }
    func send(_ action: ConnectivityAction)
}

@MainActor
@Observable
final class ConnectivityViewModel: ConnectivityViewModelProtocol {

    private(set) var state = ConnectivityState()
    private var monitorTask: Task<Void, Never>?
    private let monitor: any NetworkMonitorProtocol

    init(monitor: any NetworkMonitorProtocol = NetworkMonitor.shared) {
        self.monitor = monitor
    }

    // ★ Single dispatch point
    func send(_ action: ConnectivityAction) {
        switch action {
        case .startMonitoring: startMonitoring()
        case .stopMonitoring:  stopMonitoring()
        case .dismissBanner:   state.isBannerVisible = false
        }
    }

    // MARK: - Private handlers

    private func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task {
            for await status in monitor.statusStream() {
                guard !Task.isCancelled else { break }
                apply(status: status)
            }
        }
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func apply(status: NetworkStatus) {
        state.networkStatus = status
        if !status.isConnected {
            state.wasOffline = true
            withAnimation(.spring) { state.isBannerVisible = true }
        } else if state.wasOffline {
            withAnimation(.spring) { state.isBannerVisible = false }
            // Coordinator integration: trigger data refresh here
        }
    }
}
```

---

## Step 3 — Offline-aware data service (~10 min)

```swift
// DataService.swift
import Foundation

// ★ Key pattern: try network, fall back to cache, throw if neither
actor DataService {

    private var cache: [String: Data] = [:]

    func fetch(endpoint: String) async throws -> Data {
        let isOnline = NetworkMonitor.shared.status.isConnected

        if isOnline {
            do {
                let data = try await networkFetch(endpoint: endpoint)
                cache[endpoint] = data  // populate cache
                return data
            } catch {
                // Network failed — try cache
                if let cached = cache[endpoint] {
                    print("Network failed, serving cached data for \(endpoint)")
                    return cached
                }
                throw error
            }
        } else {
            // Offline — serve cache or throw
            if let cached = cache[endpoint] {
                return cached
            }
            throw NetworkError.offline
        }
    }

    private func networkFetch(endpoint: String) async throws -> Data {
        let url = URL(string: endpoint)!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NetworkError.badResponse
        }
        return data
    }
}

enum NetworkError: Error, LocalizedError {
    case offline
    case badResponse

    var errorDescription: String? {
        switch self {
        case .offline:      return "You're offline. Showing cached content."
        case .badResponse:  return "Server returned an unexpected response."
        }
    }
}
```

---

## Step 4 — Modular views + Swift Testing (~15 min)

```swift
// StatusRow.swift
import SwiftUI

struct StatusRow: View {
    let status: NetworkStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.icon)
                .foregroundStyle(status.isConnected ? .green : .red).font(.title2)
            VStack(alignment: .leading) {
                Text(status.label).font(.headline)
                Text("Network.framework / NWPathMonitor").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(status.isConnected ? Color.green : Color.red).frame(width: 10, height: 10)
        }
    }
}

// OfflineBanner.swift — pure display, accepts dismiss callback
struct OfflineBanner: View {
    let status: NetworkStatus
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.icon)
            Text(status.label).font(.subheadline.weight(.medium))
            Spacer()
            Button { onDismiss() } label: { Image(systemName: "xmark") }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Capsule().fill(status.isConnected ? Color.green : Color.red.opacity(0.9)))
        .padding(.top, 8).shadow(radius: 8)
    }
}

// ConnectionDetailsSection.swift
struct ConnectionDetailsSection: View {
    let state: ConnectivityState

    var body: some View {
        Section("Connection details") {
            LabeledContent("On Wi-Fi",  value: state.isOnWifi   ? "Yes" : "No")
            LabeledContent("Expensive", value: state.isExpensive ? "Yes (cellular)" : "No")
        }
        Section("What this enables") {
            if state.isOnWifi {
                Label("HD video streaming OK", systemImage: "video.fill").foregroundStyle(.green)
                Label("Background sync OK",    systemImage: "arrow.clockwise").foregroundStyle(.green)
            } else if state.isExpensive {
                Label("Limit video quality",   systemImage: "video.badge.ellipsis").foregroundStyle(.orange)
                Label("Pause heavy syncs",     systemImage: "pause.circle").foregroundStyle(.orange)
            } else {
                Label("Showing cached content only", systemImage: "tray.fill").foregroundStyle(.secondary)
            }
        }
    }
}

// NetworkAwareView.swift — root view
struct NetworkAwareView: View {
    @State private var vm = ConnectivityViewModel()

    var body: some View {
        ZStack(alignment: .top) {
            NavigationStack {
                List {
                    Section("Network status") { StatusRow(status: vm.state.networkStatus) }
                    ConnectionDetailsSection(state: vm.state)
                }
                .navigationTitle("NetworkAware")
            }

            if vm.state.isBannerVisible {
                OfflineBanner(
                    status: vm.state.networkStatus,
                    onDismiss: { vm.send(.dismissBanner) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.spring(duration: 0.4), value: vm.state.isBannerVisible)
        .task { vm.send(.startMonitoring) }
        .onDisappear { vm.send(.stopMonitoring) }
    }
}

// MARK: — Swift Testing

// MockNetworkMonitor — controllable, no real NWPathMonitor
final class MockNetworkMonitor: NetworkMonitorProtocol, @unchecked Sendable {
    var status: NetworkStatus = .unknown
    private let stream: AsyncStream<NetworkStatus>
    private var continuation: AsyncStream<NetworkStatus>.Continuation?

    init() {
        var cont: AsyncStream<NetworkStatus>.Continuation?
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    func statusStream() -> AsyncStream<NetworkStatus> { stream }
    func emit(_ status: NetworkStatus) { self.status = status; continuation?.yield(status) }
}

import Testing
@testable import NetworkAware

@Suite("ConnectivityViewModel")
struct ConnectivityViewModelTests {

    @Test @MainActor
    func initialStateIsUnknown() {
        let vm = ConnectivityViewModel(monitor: MockNetworkMonitor())
        #expect(vm.state.networkStatus == .unknown)
        #expect(!vm.state.isBannerVisible)
    }

    @Test @MainActor
    func goingOfflineShowsBanner() async throws {
        let monitor = MockNetworkMonitor()
        let vm = ConnectivityViewModel(monitor: monitor)
        vm.send(.startMonitoring)
        monitor.emit(.disconnected)
        try await Task.sleep(for: .milliseconds(10))
        #expect(vm.state.isBannerVisible)
        #expect(vm.state.wasOffline)
    }

    @Test @MainActor
    func reconnectingHidesBanner() async throws {
        let monitor = MockNetworkMonitor()
        let vm = ConnectivityViewModel(monitor: monitor)
        vm.send(.startMonitoring)
        monitor.emit(.disconnected)
        try await Task.sleep(for: .milliseconds(10))
        monitor.emit(.connected(.wifi))
        try await Task.sleep(for: .milliseconds(10))
        #expect(!vm.state.isBannerVisible)
    }

    @Test @MainActor
    func dismissBannerHidesItManually() async throws {
        let monitor = MockNetworkMonitor()
        let vm = ConnectivityViewModel(monitor: monitor)
        vm.send(.startMonitoring)
        monitor.emit(.disconnected)
        try await Task.sleep(for: .milliseconds(10))
        vm.send(.dismissBanner)
        #expect(!vm.state.isBannerVisible)
    }

    @Test @MainActor
    func isExpensiveOnCellular() async throws {
        let monitor = MockNetworkMonitor()
        let vm = ConnectivityViewModel(monitor: monitor)
        vm.send(.startMonitoring)
        monitor.emit(.connected(.cellular))
        try await Task.sleep(for: .milliseconds(10))
        #expect(vm.state.isExpensive)
        #expect(!vm.state.isOnWifi)
    }
}
```

---

## ★ Challenge

1. **Expensive path awareness:** When on cellular, reduce image quality by appending `?quality=low` to API calls.

2. **Retry queue:** When offline, queue mutations (POST/PATCH). On reconnect, replay them in order.

```swift
actor RetryQueue {
    private var pending: [(endpoint: String, body: Data)] = []

    func enqueue(endpoint: String, body: Data) {
        pending.append((endpoint, body))
    }

    func flushOnReconnect() async {
        for item in pending {
            // replay...
        }
        pending.removeAll()
    }
}
```

---

## Key concepts to remember

**`NWPath.isExpensive`:** True on cellular — use this to gate video auto-play, background sync, prefetching.

**`NWPath.isConstrained`:** True in iOS Low Data Mode — respect this or Apple may reject your app.

**Don't use Reachability as a gate:** Never block a request saying "I know I'm offline, so I won't try." Network state can change mid-request. Always try, handle failures.

---

## Follow-up questions

- *What's wrong with using `SCNetworkReachability` today?* (Callback-based, not interface-aware, predates Swift concurrency)
- *How would you test offline scenarios without turning off WiFi?* (Network Link Conditioner in Xcode, or mock `NetworkMonitor` behind a protocol)
- *Can `NWPathMonitor` detect DNS failures?* (No — it monitors interface availability, not resolution. A connected path can still fail DNS.)
