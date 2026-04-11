import Foundation

// Sendable = safe to send across actor/Task boundries
struct NewsArticle: Identifiable, Sendable, Hashable {
    let id: UUID
    let source: String
    let title: String
    let publishedAt: Date
    let url: URL
}

struct NewsSource: Sendable {
    let name: String
    let endpoint: URL
}

enum FetchError: Error, Sendable {
    case networkError(String, underlying: Error)
    case decodingError(String)
    case timeout(String)
}

// Per-source fetch status for UI
enum SourceStatus: Sendable, Equatable {
    case idle
    case loading
    case loaded(Int) // article count
    case failed(String)
}
