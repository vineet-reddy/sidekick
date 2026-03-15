import SwiftData
import SwiftUI

struct PaperListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Paper.createdAt, order: .reverse) private var papers: [Paper]
    @Query(sort: \ResearchRun.createdAt, order: .reverse) private var runs: [ResearchRun]
    @State private var path: [UUID] = []
    @State private var hasAutoOpenedLatestReadyPaper = false

    private let shouldAutoOpenLatestReadyPaper = QAFlags.shouldOpenLatestPaper

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                SidekickBackground()

                ScrollView {
                    if papers.isEmpty {
                        Text("Papers will appear here as your notes develop.")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(papers) { paper in
                                NavigationLink(value: paper.id) {
                                    paperCard(for: paper)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        delete(paper)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 96)
                    }
                }
            }
            .navigationTitle("Papers")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("papers.listView")
            .navigationDestination(for: UUID.self) { paperID in
                if let paper = papers.first(where: { $0.id == paperID }) {
                    PaperDetailView(paper: paper)
                } else {
                    missingPaperView
                }
            }
            .task(id: autoOpenTaskKey) {
                autoOpenLatestReadyPaperIfNeeded()
            }
        }
    }

    private var autoOpenTaskKey: String {
        let ids = papers.map(\.id.uuidString).joined(separator: ",")
        return "\(shouldAutoOpenLatestReadyPaper)|\(ids)"
    }

    private var missingPaperView: some View {
        Text("Paper not found.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var runsByPaperID: [UUID: ResearchRun] {
        Dictionary(uniqueKeysWithValues: runs.map { ($0.paperID, $0) })
    }

    private func autoOpenLatestReadyPaperIfNeeded() {
        guard shouldAutoOpenLatestReadyPaper, !hasAutoOpenedLatestReadyPaper else {
            return
        }

        guard let latestReadyPaper = papers.first(where: { $0.status == .ready }) else {
            return
        }

        path = [latestReadyPaper.id]
        hasAutoOpenedLatestReadyPaper = true
    }

    private func paperCard(for paper: Paper) -> some View {
        let run = runsByPaperID[paper.id]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(paper.title.isEmpty ? "Untitled paper" : paper.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer()

                statusPill(for: paper, run: run)
            }

            HStack {
                Text(paper.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()
            }

            if !paper.summary.isEmpty {
                Text(paper.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let run, paper.status != .ready {
                Text(run.latestProgressMessage ?? run.currentStageTitle)
                    .font(.caption)
                    .foregroundStyle(run.status == .failed ? .red : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paper.card.\(paper.id.uuidString)")
    }

    private func delete(_ paper: Paper) {
        try? ContentDeletionService.deletePaper(paper, modelContext: modelContext)
        path.removeAll { $0 == paper.id }
    }

    @ViewBuilder
    private func statusPill(for paper: Paper, run: ResearchRun?) -> some View {
        switch paper.status {
        case .ready:
            EmptyView()
        case .generating:
            if let run {
                StatusPill(title: run.listStatusLabel, tint: SidekickTheme.accent)
            } else {
                StatusPill(title: "Generating...", tint: SidekickTheme.accent)
            }
        case .failed:
            StatusPill(title: "Needs retry", tint: .red)
        }
    }
}
