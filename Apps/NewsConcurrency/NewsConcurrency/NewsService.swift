import Foundation

protocol NewsServiceProtocol: Sendable {
    func fetchAll() async -> [String: Result<[NewsArticle], FetchError>]
}

final class NewsService: NewsServiceProtocol, Sendable {
    private let cache = ArticleCache()

    static let sources: [NewsSource] = [
        NewsSource(name: "TechCrunch", endpoint: URL(string: "https://api.example.com/tc")!),
        NewsSource(name: "Hacker News", endpoint: URL(string: "https://api.example.com/hn")!),
        NewsSource(name: "Verge",       endpoint: URL(string: "https://api.example.com/vg")!),
        NewsSource(name: "Wired",       endpoint: URL(string: "https://api.example.com/wd")!),
        NewsSource(name: "Ars",         endpoint: URL(string: "https://api.example.com/at")!)
    ]

    // Fetch all sources in parallel, returns partial result on failure
    func fetchAll() async -> [String: Result<[NewsArticle], FetchError>] {
        await withTaskGroup(
            of: (String, Result<[NewsArticle], FetchError>).self) { group in
                for source in Self.sources {
                    group.addTask {
                        // Each task runs concurrently
                        do {
                            let articles = try await self.fetchSource(source)
                            return (source.name, .success(articles))
                        } catch {
                            return (
                                source.name,
                                .failure(
                                    .networkError(source.name, underlying: error)
                                )
                            )
                        }
                    }
                }

            }

        // Collect the results as they complete (order not guaranteed)
        var results: [String: Result<[NewsArticle], FetchError>] = [:]
        return results
    }

    // async let: fire two requets simultaneously, await both
    func fetchWithMetadata(source: NewsSource) async throws -> ([NewsArticle], Int) {
        async let articles = fetchSource(source)
        async let count = fetchCount(source)
        return try await (articles, count)
    }

    private func fetchSource(_ source: NewsSource) async throws -> [NewsArticle] {
        // Check cache first
        if let cached = await cache.articles(for: source.name) {
            return cached
        }

        // Simulate network (replace with real URLSession in prod)
        try await Task.sleep(for: .milliseconds(Int.random(in: 300...1500)))

        // SImulate occasional failure
        if Bool.random() && source.name == "Wired" {
            throw URLError(.timedOut)
        }

        let articles = (1...Int.random(in: 3...8)).map { i in
            NewsArticle(
                id: UUID(),
                source: source.name,
                title: "\(source.name) headline #\(i): Swift concurrency deep dive",
                publishedAt: Date.now.addingTimeInterval(-Double(i) * 3600),
                url: source.endpoint
            )
        }

        await cache.store(articles, for: source.name)
        return articles
    }

    private func fetchCount(_ source: NewsSource) async throws -> Int {
        try await Task.sleep(for: .milliseconds(100))
        return Int.random(in: 50...500)
    }
}
