import PDFKit
import SwiftUI

struct PaperDetailView: View {
    @State private var shareItem: ShareItem?
    @State private var exportError: String?
    @State private var isShowingExportError = false
    @State private var documentState: DocumentState = .loading

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
                        title: "Sidekick is writing",
                        message: "This paper is still running in the background. The app will notify you when it lands."
                    )
                case .failed:
                    progressCard(
                        title: "The paper stalled",
                        message: "Something went wrong during generation. Sidekick will retry automatically on the next cycle."
                    )
                }
            }
        }
        .navigationTitle(paper.title.isEmpty ? "Paper" : paper.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: paper.updatedAt) {
            await loadDocumentIfNeeded()
        }
        .toolbar {
            if case let .ready(url) = documentState {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Share") {
                        Button("Share PDF") {
                            shareItem = ShareItem(url: url)
                        }

                        Button("Share LaTeX") {
                            shareLaTeX()
                        }
                    }
                }
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
        } catch {
            documentState = .failed(error.localizedDescription)
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
