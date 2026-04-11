import Observation

// All user intents modeled as an enum
enum NewsAction: Sendable {
    case refresh
    case cancelFetch
    case selectArticle(NewsArticle) // fires coordinator action
}

// All view state in one Equatable struct
struct NewsState: Equatable {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var phase: Phase = .idle
    var articles: [NewsArticle] = []
    var sourceStatuses: [String: SourceStatus] = [:]
    var partialError: String? = nil // some sources failed but others loaded
}

@MainActor
protocol NewsViewModelProtocol: AnyObject {
    var state: NewsState { get }
    func send(_ action: NewsAction)
}


@MainActor
@Observable
final class NewsViewModel: NewsViewModelProtocol {
    private(set) var state = NewsState()
    var onArticleSelected: ((NewsArticle) -> Void)? // Coordinator integration

    private let service: any NewsServiceProtocol
    private var fetchTask: Task<Void, Never>?

    init(service: any NewsServiceProtocol) {
        self.service = service
    }

    init() {
        self.service = NewsService()
    }

    func send(_ action: NewsAction) {
        switch action {
        case .refresh:
            refresh()
        case .cancelFetch:
            cancelFetch()
        case .selectArticle(let newsArticle):
            onArticleSelected?(newsArticle)
        }
    }

    // MARK: Private handlers
    private func refresh() {
        fetchTask?.cancel()

        state.phase = .loading
        state.partialError = nil

        for source in NewsService.sources {
            state.sourceStatuses[source.name] = .loading
        }

        fetchTask = Task {
            let results = await service.fetchAll()
            guard !Task.isCancelled else { return }

            var allArticles: [NewsArticle] = []
            var hadFailure = false

            for (name, result) in results {
                switch result {
                case .success(let fetched):
                    state.sourceStatuses[name] = .loaded(fetched.count)
                    allArticles.append(contentsOf: fetched)
                case .failure(_):
                    state.sourceStatuses[name] = .failed("Failed")
                    hadFailure = true
                }
            }

            state.articles = allArticles
                .sorted { $0.publishedAt > $1.publishedAt }
            state.partialError = hadFailure ? "Some sources failed to load" : nil
            state.phase = .loaded
        }
    }

    private func cancelFetch() {
        fetchTask?.cancel()
        state.phase = state.articles.isEmpty ? .idle : .loaded
    }
}
