# Tutorial 06 — Exponential Backoff, Retry, and Jitter
## Build: ResilientHTTP — a production-grade retry client
**Time:** 60 min | **Swift 6** | **Topics:** Retry strategies, exponential backoff, jitter, circuit breaker

---

## What you'll build
A retry-capable HTTP client with:
- Configurable retry policy (max attempts, base delay, max delay)
- Exponential backoff: `delay = base * 2^attempt`
- Jitter to prevent thundering herd
- Circuit breaker pattern
- Observable retry state for UI

---

## Why this matters in production

Without retry logic, a single network blip drops a payment:
- User submits payment → server hiccup → 503 → app shows error
- User resubmits → duplicate payment

With retry + idempotency:
- 503 → wait 1s → retry → wait 2s → retry → wait 4s → success

---

## The math

```
Exponential backoff:
delay(attempt) = baseDelay * 2^attempt

attempt 0: 1s * 2^0 = 1s
attempt 1: 1s * 2^1 = 2s
attempt 2: 1s * 2^2 = 4s
attempt 3: 1s * 2^3 = 8s  (capped at maxDelay = 30s)

With full jitter (prevents thundering herd):
jitteredDelay = random(0, delay(attempt))

With decorrelated jitter (AWS recommendation):
jitteredDelay = random(baseDelay, min(maxDelay, prev * 3))
```

---

## Step 1 — Retry policy (~10 min)

```swift
// RetryPolicy.swift
import Foundation

struct RetryPolicy: Sendable {

    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let jitterStrategy: JitterStrategy
    let retryableStatusCodes: Set<Int>

    enum JitterStrategy: Sendable {
        case none              // pure exponential
        case full              // random(0, delay) — most common
        case decorrelated      // AWS recommended
        case equal             // delay/2 + random(0, delay/2)
    }

    // Sensible defaults for API clients
    static let `default` = RetryPolicy(
        maxAttempts: 3,
        baseDelay: 1.0,
        maxDelay: 30.0,
        jitterStrategy: .full,
        retryableStatusCodes: [408, 429, 500, 502, 503, 504]
    )

    // Aggressive for critical operations (payments)
    static let critical = RetryPolicy(
        maxAttempts: 5,
        baseDelay: 0.5,
        maxDelay: 60.0,
        jitterStrategy: .decorrelated,
        retryableStatusCodes: [408, 429, 500, 502, 503, 504]
    )

    // Conservative for non-critical
    static let gentle = RetryPolicy(
        maxAttempts: 2,
        baseDelay: 2.0,
        maxDelay: 10.0,
        jitterStrategy: .equal,
        retryableStatusCodes: [503, 504]
    )

    /// Calculates the delay before attempt `n` (0-indexed)
    func delay(attempt: Int, previousDelay: TimeInterval = 0) -> TimeInterval {
        let exponential = min(maxDelay, baseDelay * pow(2.0, Double(attempt)))

        switch jitterStrategy {
        case .none:
            return exponential

        case .full:
            // random(0, exponential) — lowest average wait, most spread
            return Double.random(in: 0...exponential)

        case .decorrelated:
            // AWS: sleep = random(base, min(cap, prev * 3))
            let prev = max(baseDelay, previousDelay)
            return Double.random(in: baseDelay...min(maxDelay, prev * 3))

        case .equal:
            // delay/2 + random(0, delay/2) — balanced
            return (exponential / 2) + Double.random(in: 0...(exponential / 2))
        }
    }

    func isRetryable(statusCode: Int) -> Bool {
        retryableStatusCodes.contains(statusCode)
    }

    func isRetryable(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut, .networkConnectionLost,
            .notConnectedToInternet, .cannotConnectToHost
        ].contains(urlError.code)
    }
}
```

---

## Step 2 — Circuit breaker (~10 min)

```swift
// CircuitBreaker.swift
import Foundation

// Prevents hammering a known-dead service
// States: closed (normal) → open (failing) → half-open (testing)
actor CircuitBreaker {

    enum State: Equatable {
        case closed                     // normal operation
        case open(until: Date)          // rejecting all requests
        case halfOpen                   // allowing one test request
    }

    private var state: State = .closed
    private var failureCount: Int = 0

    let failureThreshold: Int
    let resetTimeout: TimeInterval
    let successThreshold: Int

    private var successCount: Int = 0

    init(
        failureThreshold: Int = 5,
        resetTimeout: TimeInterval = 60,
        successThreshold: Int = 2
    ) {
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
        self.successThreshold = successThreshold
    }

    var currentState: State { state }
    var isOpen: Bool {
        if case .open(let until) = state, Date.now < until { return true }
        return false
    }

    func canProceed() -> Bool {
        switch state {
        case .closed:
            return true
        case .open(let until):
            if Date.now >= until {
                state = .halfOpen
                return true   // allow one test request
            }
            return false
        case .halfOpen:
            return true
        }
    }

    func recordSuccess() {
        switch state {
        case .halfOpen:
            successCount += 1
            if successCount >= successThreshold {
                state = .closed
                failureCount = 0
                successCount = 0
            }
        case .closed:
            failureCount = 0  // reset on success
        case .open:
            break
        }
    }

    func recordFailure() {
        successCount = 0
        switch state {
        case .closed, .halfOpen:
            failureCount += 1
            if failureCount >= failureThreshold {
                state = .open(until: Date.now.addingTimeInterval(resetTimeout))
            }
        case .open:
            break
        }
    }
}
```

---

## Step 3 — Resilient HTTP client (~15 min)

```swift
// ResilientHTTP.swift
import Foundation

struct HTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
}

enum HTTPError: Error, Sendable {
    case circuitOpen
    case maxRetriesExceeded(attempts: Int, lastError: Error)
    case nonRetryable(statusCode: Int)
    case invalidResponse
}

// Observable retry attempt info for UI
struct RetryAttempt: Sendable {
    let attempt: Int
    let maxAttempts: Int
    let delay: TimeInterval
    let error: Error
}

final class ResilientHTTPClient: Sendable {

    private let session: URLSession
    private let policy: RetryPolicy
    private let breaker: CircuitBreaker
    private let onRetry: (@Sendable (RetryAttempt) -> Void)?

    init(
        policy: RetryPolicy = .default,
        onRetry: (@Sendable (RetryAttempt) -> Void)? = nil
    ) {
        self.policy = policy
        self.breaker = CircuitBreaker()
        self.session = URLSession.shared
        self.onRetry = onRetry
    }

    func request(_ urlRequest: URLRequest) async throws -> HTTPResponse {
        guard await breaker.canProceed() else {
            throw HTTPError.circuitOpen
        }

        var lastError: Error = HTTPError.invalidResponse
        var previousDelay: TimeInterval = 0

        for attempt in 0..<policy.maxAttempts {
            do {
                let response = try await performRequest(urlRequest)

                // Check if status code is retryable
                if policy.isRetryable(statusCode: response.statusCode) {
                    lastError = HTTPError.nonRetryable(statusCode: response.statusCode)

                    // Handle Retry-After header if present
                    let retryAfter = response.headers["Retry-After"].flatMap(Double.init)
                    let delay = retryAfter ?? policy.delay(attempt: attempt, previousDelay: previousDelay)
                    previousDelay = delay

                    onRetry?(RetryAttempt(
                        attempt: attempt + 1,
                        maxAttempts: policy.maxAttempts,
                        delay: delay,
                        error: lastError
                    ))

                    try await Task.sleep(for: .seconds(delay))
                    continue
                }

                await breaker.recordSuccess()
                return response

            } catch {
                lastError = error

                if !policy.isRetryable(error: error) {
                    await breaker.recordFailure()
                    throw error
                }

                if attempt < policy.maxAttempts - 1 {
                    let delay = policy.delay(attempt: attempt, previousDelay: previousDelay)
                    previousDelay = delay

                    onRetry?(RetryAttempt(
                        attempt: attempt + 1,
                        maxAttempts: policy.maxAttempts,
                        delay: delay,
                        error: error
                    ))

                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }

        await breaker.recordFailure()
        throw HTTPError.maxRetriesExceeded(attempts: policy.maxAttempts, lastError: lastError)
    }

    private func performRequest(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }
        let headers = Dictionary(uniqueKeysWithValues:
            http.allHeaderFields.compactMap { k, v -> (String, String)? in
                guard let key = k as? String, let val = v as? String else { return nil }
                return (key, val)
            }
        )
        return HTTPResponse(data: data, statusCode: http.statusCode, headers: headers)
    }
}
```

---

## Step 4 — ViewModel with observable retry state (~10 min)

```swift
// RetryDemoViewModel.swift
import Observation

@MainActor
@Observable
final class RetryDemoViewModel {

    var phase: Phase = .idle
    var retryLog: [String] = []
    var circuitState: String = "Closed (normal)"

    enum Phase {
        case idle
        case requesting
        case retrying(attempt: Int, delay: TimeInterval)
        case success(String)
        case failed(String)
        case circuitOpen
    }

    private lazy var client = ResilientHTTPClient(
        policy: .default,
        onRetry: { [weak self] attempt in
            Task { @MainActor [weak self] in
                self?.phase = .retrying(attempt: attempt.attempt, delay: attempt.delay)
                self?.retryLog.append(
                    "Attempt \(attempt.attempt)/\(attempt.maxAttempts) — waiting \(String(format: "%.1f", attempt.delay))s"
                )
            }
        }
    )

    func makeRequest() async {
        phase = .requesting
        retryLog = []

        let request = URLRequest(url: URL(string: "https://httpbin.org/status/503")!)

        do {
            let response = try await client.request(request)
            phase = .success("Status \(response.statusCode)")
        } catch HTTPError.circuitOpen {
            phase = .circuitOpen
            circuitState = "Open (protecting service)"
        } catch HTTPError.maxRetriesExceeded(let attempts, _) {
            phase = .failed("Failed after \(attempts) attempts")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
```

---

## ★ Challenge

Implement **retry budget**: instead of per-request max attempts, track a total retry budget across all requests for a given time window.

```swift
actor RetryBudget {
    private var remaining: Int
    private var windowStart: Date
    let windowDuration: TimeInterval
    let budget: Int

    init(budget: Int, window: TimeInterval) {
        self.budget = budget
        self.remaining = budget
        self.windowDuration = window
        self.windowStart = .now
    }

    func consume() -> Bool {
        resetIfNeeded()
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }

    private func resetIfNeeded() {
        if Date.now.timeIntervalSince(windowStart) >= windowDuration {
            remaining = budget
            windowStart = .now
        }
    }
}
```

---

## Key concepts to remember

**Jitter is not optional:** Without jitter, all clients backing off from a 503 will all retry at the same time (t=1s, t=2s, t=4s). This creates retry storms that take the server down again. Full jitter distributes retries across the entire delay window.

**Retry-After header:** Servers under load send `Retry-After: 30` — always parse and respect it. Your calculated delay is a floor, not a ceiling.

**Circuit breaker is about the server, not the client:** Open the circuit after 5 consecutive failures. This gives the server time to recover without being hammered by retrying clients.

**Idempotency keys:** Before retrying a POST/PATCH, ensure the server is idempotent. Add `Idempotency-Key: <UUID>` header. Same UUID on retries = server ignores duplicates.

---

## MVVM Integration: `send(_:)` ViewModel wrapper

```swift
// RetryViewModel.swift — wraps ResilientHTTP in the standard send pattern
import Observation

enum RetryAction: Sendable {
    case submitRequest(url: URL)
    case cancel
    case reset
}

struct RetryState: Equatable {
    enum Phase: Equatable {
        case idle
        case loading
        case retrying(attempt: Int, of: Int, delay: TimeInterval)
        case succeeded(statusCode: Int)
        case failed(String)
    }
    var phase: Phase = .idle
}

@MainActor
@Observable
final class RetryViewModel {
    private(set) var state = RetryState()
    private var requestTask: Task<Void, Never>?
    private let client: ResilientHTTP

    init(client: ResilientHTTP = .shared) {
        self.client = client
    }

    func send(_ action: RetryAction) {
        switch action {
        case .submitRequest(let url): submitRequest(url: url)
        case .cancel:                 cancel()
        case .reset:                  state.phase = .idle
        }
    }

    private func submitRequest(url: URL) {
        requestTask?.cancel()
        state.phase = .loading

        requestTask = Task {
            do {
                let response = try await client.request(
                    URLRequest(url: url),
                    onRetry: { [weak self] attempt in
                        await MainActor.run {
                            self?.state.phase = .retrying(
                                attempt: attempt.attempt,
                                of: attempt.maxAttempts,
                                delay: attempt.delay
                            )
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                state.phase = .succeeded(statusCode: response.statusCode)
            } catch {
                guard !Task.isCancelled else { return }
                state.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func cancel() {
        requestTask?.cancel()
        state.phase = .idle
    }
}

// RetryStatusView.swift — modular display of retry state
import SwiftUI

struct RetryStatusView: View {
    let phase: RetryState.Phase
    let onSend: (RetryAction) -> Void

    var body: some View {
        Group {
            switch phase {
            case .idle:
                Button("Send Request") {
                    onSend(.submitRequest(url: URL(string: "https://api.example.com/data")!))
                }
                .buttonStyle(.borderedProminent)

            case .loading:
                HStack {
                    ProgressView()
                    Text("Sending…")
                }

            case .retrying(let attempt, let max, let delay):
                VStack(spacing: 8) {
                    ProgressView().tint(.orange)
                    Text("Retry \(attempt)/\(max) — waiting \(delay, format: .number.precision(.fractionLength(1)))s")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Cancel") { onSend(.cancel) }.buttonStyle(.bordered).tint(.red)
                }

            case .succeeded(let code):
                VStack {
                    Label("Success (\(code))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Reset") { onSend(.reset) }.buttonStyle(.bordered)
                }

            case .failed(let msg):
                VStack {
                    Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    Button("Retry") {
                        onSend(.submitRequest(url: URL(string: "https://api.example.com/data")!))
                    }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
    }
}

// MARK: — Swift Testing

import Testing
@testable import ResilientHTTP

// Controllable HTTP client for testing
actor MockHTTPClient {
    var callCount = 0
    var stubbedResponses: [Result<HTTPResponse, Error>] = []

    func next() async throws -> HTTPResponse {
        callCount += 1
        let response = stubbedResponses.isEmpty
            ? .failure(URLError(.networkConnectionLost))
            : stubbedResponses.removeFirst()
        switch response {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {

    @Test
    func backoffDelayIsExponential() {
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 1.0, maxDelay: 30, jitterStrategy: .none)
        #expect(policy.delay(attempt: 0) == 1.0)
        #expect(policy.delay(attempt: 1) == 2.0)
        #expect(policy.delay(attempt: 2) == 4.0)
        #expect(policy.delay(attempt: 3) == 8.0)
    }

    @Test
    func delayIsCappedAtMaxDelay() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 1.0, maxDelay: 5.0, jitterStrategy: .none)
        #expect(policy.delay(attempt: 10) == 5.0)
    }

    @Test
    func statusCodeRetryability() {
        let policy = RetryPolicy.standard
        #expect(policy.shouldRetry(statusCode: 503))
        #expect(policy.shouldRetry(statusCode: 429))
        #expect(!policy.shouldRetry(statusCode: 400))
        #expect(!policy.shouldRetry(statusCode: 401))
        #expect(!policy.shouldRetry(statusCode: 404))
    }
}

@Suite("CircuitBreaker")
struct CircuitBreakerTests {

    @Test
    func opensAfterFailureThreshold() {
        var breaker = CircuitBreaker(failureThreshold: 3, resetTimeout: 60)
        breaker.recordFailure()
        breaker.recordFailure()
        breaker.recordFailure()
        if case .open = breaker.state { } else { Issue.record("Expected .open state") }
    }

    @Test
    func closedInitially() {
        let breaker = CircuitBreaker(failureThreshold: 3, resetTimeout: 60)
        #expect(breaker.state == .closed)
    }

    @Test
    func recordSuccessResetsFailureCount() {
        var breaker = CircuitBreaker(failureThreshold: 3, resetTimeout: 60)
        breaker.recordFailure()
        breaker.recordFailure()
        breaker.recordSuccess()  // reset
        breaker.recordFailure()
        breaker.recordFailure()
        // Only 2 failures since last success — still closed
        #expect(breaker.state == .closed)
    }
}
```

---

## Follow-up questions

- *What's the thundering herd problem?* (Many clients retry in lockstep, creating periodic spikes that prevent server recovery)
- *When would you NOT retry?* (4xx errors except 408/429; auth errors 401/403; client errors that won't change)
- *How does a circuit breaker differ from rate limiting?* (Rate limiting is server-side; circuit breaker is client-side self-protection)
- *How do you test retry logic without real network calls?* (Inject `MockHTTPClient` via protocol — stub failure responses until the Nth call succeeds, assert `callCount == N`)
