// SourceStatusBadge.swift
import SwiftUI

struct SourceStatusBadge: View {
    let status: SourceStatus

    var body: some View {
        switch status {
        case .idle:           Text("—").foregroundStyle(.tertiary)
        case .loading:        ProgressView().scaleEffect(0.7)
        case .loaded(let n):  Text("\(n)").foregroundStyle(.green)
        case .failed(let e):  Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red).help(e)
        }
    }
}

// SourceStatusSection.swift
struct SourceStatusSection: View {
    let statuses: [String: SourceStatus]
    let sources: [NewsSource]

    var body: some View {
        Section("Sources") {
            ForEach(sources, id: \.name) { source in
                HStack {
                    Text(source.name)
                    Spacer()
                    SourceStatusBadge(status: statuses[source.name] ?? .idle)
                }
            }
        }
    }
}

// ArticleRow.swift
struct ArticleRow: View {
    let article: NewsArticle
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(article.title).font(.headline)
            HStack {
                Text(article.source).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(article.publishedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// ArticlesSection.swift
struct ArticlesSection: View {
    let articles: [NewsArticle]
    let isLoading: Bool
    let onSelect: (NewsArticle) -> Void

    var body: some View {
        Section("Articles (\(articles.count))") {
            if articles.isEmpty && !isLoading {
                Text("Pull to refresh").foregroundStyle(.secondary)
            }
            ForEach(articles) { article in
                ArticleRow(article: article, onSelect: { onSelect(article) })
            }
        }
    }
}

// NewsView.swift — root view
struct NewsView: View {
    @State private var vm = NewsViewModel()

    var body: some View {
        NavigationStack {
            List {
                SourceStatusSection(
                    statuses: vm.state.sourceStatuses,
                    sources: NewsService.sources
                )
                ArticlesSection(
                    articles: vm.state.articles,
                    isLoading: vm.state.phase == .loading,
                    onSelect: { vm.send(.selectArticle($0)) }
                )
            }
            .navigationTitle("News")
            .refreshable { vm.send(.refresh) }
            .toolbar {
                if vm.state.phase == .loading {
                    ToolbarItem {
                        Button("Cancel") { vm.send(.cancelFetch) }
                    }
                }
            }
            .overlay {
                if vm.state.phase == .loading && vm.state.articles.isEmpty {
                    ProgressView("Fetching \(NewsService.sources.count) sources…")
                }
            }
        }
        .task { vm.send(.refresh) }   // ★ .task auto-cancels on view disappear
    }
}
