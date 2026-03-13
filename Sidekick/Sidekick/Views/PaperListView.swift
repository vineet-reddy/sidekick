import SwiftData
import SwiftUI

struct PaperListView: View {
    @Query(sort: \Paper.createdAt, order: .reverse) private var papers: [Paper]

    var body: some View {
        ZStack {
            SidekickBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeader(
                        eyebrow: "Draft papers",
                        title: "Your ideas condense into manuscripts",
                        subtitle: "Generated drafts appear here with figures, methods, and citations when Sidekick thinks a thread is ready."
                    )

                    if papers.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Nothing published yet")
                                .font(.title3.weight(.semibold))
                            Text("Keep dropping notes. The heartbeat will cluster them and draft papers automatically.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(padding: 24)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(papers) { paper in
                                NavigationLink {
                                    PaperDetailView(paper: paper)
                                } label: {
                                    paperCard(for: paper)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 96)
            }
        }
        .navigationTitle("Papers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func paperCard(for paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(paper.title.isEmpty ? "Untitled paper" : paper.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    Text(paper.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusPill(
                    title: pillTitle(for: paper.status),
                    tint: pillTint(for: paper.status)
                )
            }

            Text(paper.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func pillTitle(for status: PaperStatus) -> String {
        switch status {
        case .generating:
            return "Generating"
        case .ready:
            return "Ready"
        case .failed:
            return "Needs attention"
        }
    }

    private func pillTint(for status: PaperStatus) -> Color {
        switch status {
        case .generating:
            return SidekickTheme.accent
        case .ready:
            return .green
        case .failed:
            return .orange
        }
    }
}
