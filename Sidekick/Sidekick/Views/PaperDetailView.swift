import SwiftUI
import WebKit

struct PaperDetailView: View {
    @State private var webView = WKWebView()
    @State private var shareItem: ShareItem?
    @State private var exportError: String?
    @State private var isShowingExportError = false

    let paper: Paper

    var body: some View {
        ZStack {
            SidekickBackground()

            Group {
                switch paper.status {
                case .ready:
                    PaperWebView(html: PaperHTMLBuilder.html(for: paper), webView: $webView)
                        .glassCard(padding: 0)
                        .padding(20)
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
        .toolbar {
            if paper.status == .ready {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Export") {
                        Button("Share PDF") {
                            Task {
                                await sharePDF()
                            }
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

    private func progressCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text(message)
                .foregroundStyle(.secondary)

            if paper.status == .generating {
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
        do {
            let url = try ExportService.exportLaTeX(for: paper)
            shareItem = ShareItem(url: url)
        } catch {
            exportError = error.localizedDescription
            isShowingExportError = true
        }
    }

    private func sharePDF() async {
        do {
            let url = try await ExportService.exportPDF(for: paper, webView: webView)
            shareItem = ShareItem(url: url)
        } catch {
            exportError = error.localizedDescription
            isShowingExportError = true
        }
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PaperWebView: UIViewRepresentable {
    let html: String
    @Binding var webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
