import PDFKit
import SwiftData
import SwiftUI

struct PaperDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ResearchRun.updatedAt, order: .reverse) private var runs: [ResearchRun]
    @State private var shareItem: ShareItem?
    @State private var exportError: String?
    @State private var isShowingExportError = false
    @State private var isShowingDeleteConfirmation = false
    @State private var documentState: DocumentState = .loading
    @State private var hasAutoPresentedShareSheet = false

    let paper: Paper

    var body: some View {
        ZStack {
            SidekickBackground()

            Group {
                switch paper.status {
                case .ready:
                    readyPaperView
                case .generating:
                    progressCard(
                        title: researchRun?.currentStageTitle ?? "Sidekick is working",
                        message: researchRun?.latestProgressMessage
                            ?? "This paper is still running in the background. The app will notify you when it lands."
                    )
                case .failed:
                    progressCard(
                        title: "The paper stalled",
                        message: researchRun?.lastError
                            ?? "Something went wrong during generation. Sidekick will retry automatically on the next cycle."
                    )
                }
            }
        }
        .navigationTitle(paper.title.isEmpty ? "Paper" : paper.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: paper.updatedAt) {
            await loadDocumentIfNeeded()
        }
        .toolbar {
            if case let .ready(url) = documentState {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Share PDF") {
                            shareItem = ShareItem(url: url)
                        }

                        Button("Share LaTeX") {
                            shareLaTeX()
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete paper")
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("Export Error", isPresented: $isShowingExportError, actions: {
            Button("OK") {
                exportError = nil
                isShowingExportError = false
            }
        }, message: {
            Text(exportError ?? "")
        })
        .confirmationDialog(
            "Delete this paper?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Paper", role: .destructive) {
                deletePaper()
            }
        } message: {
            Text("This removes the paper, its cached PDF bundle, and any persisted staged artifacts for this run.")
        }
    }

    @ViewBuilder
    private var readyPaperView: some View {
        switch documentState {
        case .loading:
            progressCard(
                title: "Preparing PDF",
                message: "Sidekick is typesetting the final paper PDF."
            )
        case let .ready(url):
            PaperPDFView(url: url)
                .glassCard(padding: 0)
                .padding(14)
        case let .failed(message):
            progressCard(
                title: "PDF unavailable",
                message: message
            )
        }
    }

    private var researchRun: ResearchRun? {
        runs.latestRun(for: paper.id)
    }

    private func progressCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text(message)
                .foregroundStyle(.secondary)

            if paper.status == .generating || documentState == .loading {
                ProgressView()
                    .tint(SidekickTheme.accent)
            }

            if let run = researchRun {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ResearchRunStage.allCases, id: \.self) { stage in
                        pipelineRow(stage: stage, state: run.pipelineState(for: stage))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .glassCard(padding: 24)
        .padding(20)
    }

    private func shareLaTeX() {
        Task {
            do {
                let url = try await ExportService.exportLaTeX(for: paper)
                shareItem = ShareItem(url: url)
            } catch {
                exportError = error.localizedDescription
                isShowingExportError = true
            }
        }
    }

    private func loadDocumentIfNeeded() async {
        guard paper.status == .ready else {
            return
        }

        documentState = .loading

        do {
            let url = try await ExportService.exportPDF(for: paper)
            documentState = .ready(url)
            presentQAShareSheetIfNeeded(for: url)
        } catch {
            documentState = .failed(error.localizedDescription)
        }
    }

    private func deletePaper() {
        try? ContentDeletionService.deletePaper(paper, modelContext: modelContext)
        dismiss()
    }

    private func presentQAShareSheetIfNeeded(for url: URL) {
        guard QAFlags.shouldAutoShareLatestPaper, !hasAutoPresentedShareSheet else {
            return
        }

        shareItem = ShareItem(url: url)
        hasAutoPresentedShareSheet = true
        print("[QA] Auto-presenting share sheet for task=\(paper.codexTaskID)")
    }

    private func pipelineRow(stage: ResearchRunStage, state: ResearchRunPipelineStepState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName(for: state))
                .foregroundStyle(color(for: state))
                .font(.system(size: 12, weight: .semibold))

            Text(stage.title)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer()

            Text(label(for: state))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func symbolName(for state: ResearchRunPipelineStepState) -> String {
        switch state {
        case .pending:
            return "circle"
        case .active:
            return "clock"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private func color(for state: ResearchRunPipelineStepState) -> Color {
        switch state {
        case .pending:
            return .secondary.opacity(0.5)
        case .active:
            return SidekickTheme.accent
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private func label(for state: ResearchRunPipelineStepState) -> String {
        switch state {
        case .pending:
            return "Pending"
        case .active:
            return "Active"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        }
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private enum DocumentState: Equatable {
    case loading
    case ready(URL)
    case failed(String)
}

private struct PaperPDFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayDirection = .vertical
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .clear
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        guard pdfView.document?.documentURL != url else {
            return
        }

        pdfView.document = PDFDocument(url: url)
    }
}
