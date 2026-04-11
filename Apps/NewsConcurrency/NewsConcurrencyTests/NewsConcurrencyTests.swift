// NewsViewModelTests.swift
import Testing
@testable import NewsConcurrency
import Foundation

// Deterministic mock service
struct MockNewsService: NewsServiceProtocol {
    let results: [String: Result<[NewsArticle], FetchError>]

    func fetchAll() async -> [String: Result<[NewsArticle], FetchError>] { results }
}

@MainActor
@Suite("NewsViewModel")
struct NewsViewModelTests {

    private func article(source: String) -> NewsArticle {
        NewsArticle(
            id: UUID(),
            source: source,
            title: "Test: \(source)",
            publishedAt: .now,
            url: URL(string: "https://example.com")!
        )
    }

    @Test
    func initialPhaseIsIdle() {
        let vm = NewsViewModel(service: MockNewsService(results: [:]))
        #expect(vm.state.phase == .idle)
    }

    @Test
    func refreshSetsLoadingPhase() {
        let vm = NewsViewModel(service: MockNewsService(results: [:]))
        vm.send(.refresh)
        #expect(vm.state.phase == .loading)
    }

    @Test
    func refreshWithSuccessTransitionsToLoaded() async throws {
        let a = article(source: "TechCrunch")
        let service = MockNewsService(results: ["TechCrunch": .success([a])])
        let vm = NewsViewModel(service: service)

        vm.send(.refresh)
        try await Task.sleep(for: .milliseconds(10))

        #expect(vm.state.phase == .loaded)
        #expect(vm.state.articles.count == 1)
    }

    @Test
    func refreshWithAllFailuresShowsPartialError() async throws {
        let service = MockNewsService(results: [
            "TechCrunch": .failure(.networkError("TC", underlying: URLError(.notConnectedToInternet)))
        ])
        let vm = NewsViewModel(service: service)

        vm.send(.refresh)
        try await Task.sleep(for: .milliseconds(10))

        #expect(vm.state.partialError != nil)
    }

    @Test
    func cancelFetchTransitionsToIdleWhenNoArticles() async throws {
        let vm = NewsViewModel(service: MockNewsService(results: [:]))
        vm.send(.refresh)
        vm.send(.cancelFetch)
        #expect(vm.state.phase == .idle)
    }

    @Test
    func selectArticleFiresCallback() async throws {
        let a = article(source: "TechCrunch")
        let service = MockNewsService(results: ["TechCrunch": .success([a])])
        let vm = NewsViewModel(service: service)

        var selectedArticle: NewsArticle?
        vm.onArticleSelected = { selectedArticle = $0 }

        vm.send(.refresh)
        try await Task.sleep(for: .milliseconds(10))
        vm.send(.selectArticle(a))

        #expect(selectedArticle?.id == a.id)
    }
}
