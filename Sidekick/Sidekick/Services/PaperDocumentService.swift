import Foundation
import UIKit
import WebKit

@MainActor
enum PaperDocumentService {
    enum DocumentError: LocalizedError {
        case renderFailed
        case missingRequiredFigureAsset

        var errorDescription: String? {
            switch self {
            case .renderFailed:
                return "Sidekick could not render the paper PDF."
            case .missingRequiredFigureAsset:
                return "Sidekick could not recover the required figure assets for this paper."
            }
        }
    }

    private static let renderVersion = 11

    static func ensurePDF(for paper: Paper) async throws -> URL {
        try await ensureRenderedBundle(for: paper).pdfURL
    }

    static func ensureLaTeX(for paper: Paper) async throws -> URL {
        guard let latexURL = try await ensureRenderedBundle(for: paper).latexURL else {
            throw DocumentError.renderFailed
        }

        return latexURL
    }

    static func precomputeIfNeeded(for paper: Paper) async {
        do {
            _ = try await ensureRenderedBundle(for: paper)
            print("[PaperDocs] precompute complete task=\(artifactKey(for: paper))")
        } catch {
            print("[PaperDocs] precompute failed task=\(artifactKey(for: paper)) error=\(error.localizedDescription)")
        }
    }

    private static func ensureRenderedBundle(for paper: Paper) async throws -> PaperArtifactStore.RenderedPaperBundle {
        let taskID = artifactKey(for: paper)
        let plan = PaperArtifactStore.stageArtifact(
            ResearchPlanArtifact.self,
            runID: taskID,
            stage: .plan
        )
        let draft = PaperArtifactStore.stageArtifact(
            ResearchDraftArtifact.self,
            runID: taskID,
            stage: .write
        )
        let analysis = PaperArtifactStore.stageArtifact(
            ResearchAnalysisArtifact.self,
            runID: taskID,
            stage: .analyze
        )
        let figureArtifacts = !(draft?.figures?.isEmpty ?? true) ? (draft?.figures ?? []) : (analysis?.figures ?? [])
        let figureCaptions = figureArtifacts.map(\.caption)
        let normalizedExistingFigures = paper.figureData.compactMap(normalizedSidekickRenderableImageData)

        if normalizedExistingFigures != paper.figureData {
            let droppedFigureCount = paper.figureData.count - normalizedExistingFigures.count
            if droppedFigureCount > 0 {
                print("[PaperDocs] dropped \(droppedFigureCount) invalid figure(s) task=\(taskID)")
            } else {
                print("[PaperDocs] normalized cached figure bytes task=\(taskID)")
            }
            updateFigureDataPreservingTimestamp(normalizedExistingFigures, for: paper)
        }

        if paper.figureData.isEmpty {
            let recoveredFigures = !figureArtifacts.isEmpty ? figureArtifacts.compactMap(\.imageData) : (analysis?.figureData ?? [])
            if !recoveredFigures.isEmpty {
                print("[PaperDocs] recovered \(recoveredFigures.count) figure(s) from staged analysis task=\(taskID)")
                updateFigureDataPreservingTimestamp(recoveredFigures, for: paper)
            }
        }

        if paper.figureData.isEmpty,
           let analysis,
           !analysis.figures.isEmpty,
           paper.status == .ready {
            print("[PaperDocs] staged figures are unavailable; rendering with placeholders task=\(taskID)")
        }

        let fingerprint = artifactFingerprint(for: paper)

        if let existing = PaperArtifactStore.renderedBundle(for: taskID, fingerprint: fingerprint) {
            print("[PaperDocs] using cached bundle task=\(taskID)")
            return existing
        }

        print("[PaperDocs] rendering bundle task=\(taskID)")
        let html = PaperHTMLBuilder.html(
            for: paper,
            figureCaptions: figureCaptions,
            plan: plan,
            analysis: analysis
        )
        if let published = try await publishedManuscript(for: paper) {
            let resolvedPDFData = if let publishedPDFData = published.pdfData {
                publishedPDFData
            } else {
                try await renderPDF(from: html)
            }
            return try PaperArtifactStore.persistRenderedBundle(
                taskID: taskID,
                title: paper.title,
                fingerprint: fingerprint,
                html: html,
                latex: published.latex,
                figures: paper.figureData,
                pdfData: resolvedPDFData
            )
        }

        let latex = ExportService.latexDocument(
            for: paper,
            figureCaptions: figureCaptions,
            plan: plan,
            analysis: analysis
        )
        let pdfData = try await renderPDF(from: html)

        return try PaperArtifactStore.persistRenderedBundle(
            taskID: taskID,
            title: paper.title,
            fingerprint: fingerprint,
            html: html,
            latex: latex,
            figures: paper.figureData,
            pdfData: pdfData
        )
    }

    private static func publishedManuscript(for paper: Paper) async throws -> PublishedManuscriptBundle? {
        let taskID = artifactKey(for: paper)
        guard let metadata = PaperArtifactStore.exportMetadata(for: taskID) else {
            return nil
        }

        return try await PublishedArtifactService.fetchManuscript(metadata: metadata)
    }

    private static func artifactKey(for paper: Paper) -> String {
        let trimmed = paper.codexTaskID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? paper.id.uuidString : trimmed
    }

    private static func artifactFingerprint(for paper: Paper) -> String {
        let timestamp = Int64(paper.updatedAt.timeIntervalSince1970 * 1_000)
        let figureBytes = paper.figureData.reduce(into: 0) { partial, data in
            partial += data.count
        }

        return [
            "render-v\(renderVersion)",
            String(timestamp),
            paper.title,
            String(paper.markdown.count),
            String(paper.figureData.count),
            String(figureBytes)
        ].joined(separator: "|")
    }

    private static func updateFigureDataPreservingTimestamp(_ figures: [Data], for paper: Paper) {
        let originalUpdatedAt = paper.updatedAt
        paper.figureData = figures
        paper.updatedAt = originalUpdatedAt
    }

    private static func updatePaperStatusPreservingTimestamp(_ status: PaperStatus, for paper: Paper) {
        let originalUpdatedAt = paper.updatedAt
        paper.status = status
        paper.updatedAt = originalUpdatedAt
    }

    private static func renderPDF(from html: String) async throws -> Data {
        print("[PaperDocs] renderPDF start html_chars=\(html.count)")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.scrollView.isScrollEnabled = false

        let navigationDelegate = PaperRenderNavigationDelegate()
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString(html, baseURL: nil)

        do {
            try await navigationDelegate.waitForLoad()
            try await waitForWebContentReady(in: webView)
        } catch {
            print("[PaperDocs] renderPDF web load failed error=\(error.localizedDescription)")
            throw DocumentError.renderFailed
        }

        let formatter = webView.viewPrintFormatter()
        let renderer = PagedPaperRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, renderer.paperRect, nil)

        for pageIndex in 0 ..< renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: pageIndex, in: renderer.paperRect)
        }

        UIGraphicsEndPDFContext()

        guard data.length > 0 else {
            throw DocumentError.renderFailed
        }

        print("[PaperDocs] renderPDF done bytes=\(data.length) pages=\(renderer.numberOfPages)")
        return data as Data
    }

    private static func waitForWebContentReady(in webView: WKWebView) async throws {
        for _ in 0 ..< 60 {
            let readyState = try await webView.evaluateJavaScript("document.readyState") as? String
            let imagesReady = try await webView.evaluateJavaScript(
                "Array.from(document.images || []).every(img => img.complete)"
            ) as? Bool

            if readyState == "complete", imagesReady ?? true {
                return
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw DocumentError.renderFailed
    }
}

private final class PaperRenderNavigationDelegate: NSObject, WKNavigationDelegate {
    private enum LoadState {
        case idle
        case waiting(CheckedContinuation<Void, Error>)
        case finished
    }

    private var state: LoadState = .idle

    func waitForLoad() async throws {
        if case .finished = state {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            state = .waiting(continuation)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard case let .waiting(continuation) = state else {
            state = .finished
            return
        }

        state = .finished
        continuation.resume()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        failLoad(with: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failLoad(with: error)
    }

    private func failLoad(with error: Error) {
        guard case let .waiting(continuation) = state else {
            state = .finished
            return
        }

        state = .finished
        continuation.resume(throwing: error)
    }
}

private final class PagedPaperRenderer: UIPrintPageRenderer {
    private let resolvedPaperRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private let resolvedPrintableRect = CGRect(x: 47, y: 48, width: 518, height: 690)

    override var paperRect: CGRect {
        resolvedPaperRect
    }

    override var printableRect: CGRect {
        resolvedPrintableRect
    }

    override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
        super.drawPage(at: pageIndex, in: printableRect)
        drawMarginWatermark()
        drawPageNumber(pageIndex + 1)
    }

    private func drawMarginWatermark() {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: UIColor(white: 0.42, alpha: 0.6)
        ]
        let text = "Made with Sidekick"
        let size = (text as NSString).size(withAttributes: attributes)

        context.saveGState()
        context.translateBy(x: 16, y: resolvedPaperRect.midY)
        context.rotate(by: -.pi / 2)
        (text as NSString).draw(
            in: CGRect(
                x: -size.width / 2,
                y: 0,
                width: size.width,
                height: size.height
            ),
            withAttributes: attributes
        )
        context.restoreGState()
    }

    private func drawPageNumber(_ pageNumber: Int) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont(name: "TimesNewRomanPSMT", size: 9) ?? UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor(white: 0.18, alpha: 0.85)
        ]
        let text = "\(pageNumber)"
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(
            x: resolvedPaperRect.midX - (size.width / 2),
            y: resolvedPaperRect.maxY - 24,
            width: size.width,
            height: size.height
        )
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}
