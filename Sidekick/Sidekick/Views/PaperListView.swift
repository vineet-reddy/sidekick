import SwiftData
import SwiftUI

struct PaperListView: View {
    @Query(sort: \Paper.createdAt, order: .reverse) private var papers: [Paper]

    var body: some View {
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
                            NavigationLink {
                                PaperDetailView(paper: paper)
                            } label: {
                                paperCard(for: paper)
                            }
                            .buttonStyle(.plain)
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
    }

    private func paperCard(for paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(paper.title.isEmpty ? "Untitled paper" : paper.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer()

                // Only show a pill for non-ready states
                if paper.status == .generating {
                    StatusPill(title: "Generating...", tint: SidekickTheme.accent)
                }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
    }
}
