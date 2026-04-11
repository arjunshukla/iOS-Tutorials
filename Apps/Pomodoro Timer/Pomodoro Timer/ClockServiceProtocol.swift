import Foundation

// Protocol = swap real sleep for a controllable one in tests
protocol ClockServiceProtocol: Sendable {
    func sleep(for duration: Duration) async throws
}

struct SystemClock: ClockServiceProtocol {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

// Tests use this to advance time without waiting
final class ManualClock: ClockServiceProtocol, @unchecked Sendable {
    var shouldThrow = false

    func sleep(for duration: Duration) async throws {
        if shouldThrow { throw CancellationError() }
        // Returns immediately, no waiting in tests
    }
}
