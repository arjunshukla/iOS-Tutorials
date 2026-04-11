import Foundation

// actor = reference type with serial access
// Only one called at a time can enter actor-isolated methods
actor ArticleCache {
    private var articles: [String: [NewsArticle]] = [:] // keyed by source
    private var lastFetch: [String: Date] = [:]

    static let ttl: TimeInterval = 300 // 5 minutes

    func store(_ articles: [NewsArticle], for source: String) {
        self.articles[source] = articles
        self.lastFetch[source] = .now
    }

    func articles(for source: String) -> [NewsArticle]? {
        guard let fetched = lastFetch[source],
              Date.now.timeIntervalSince(fetched) < ArticleCache.ttl else {
            return nil
        }
        return articles[source]
    }

    func allArticles() -> [NewsArticle] {
        articles.values.flatMap { $0 }
            .sorted { $0.publishedAt > $1.publishedAt }
    }

    func invalidate(source: String) {
        articles[source] = nil
        lastFetch[source] = nil
    }
}
