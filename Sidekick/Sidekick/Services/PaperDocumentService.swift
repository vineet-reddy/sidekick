import Foundation
import UIKit

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

    private static let renderVersion = 6

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
        let analysis = PaperArtifactStore.stageArtifact(
            ResearchAnalysisArtifact.self,
            runID: taskID,
            stage: .analyze
        )
        let figureCaptions = analysis?.figures.map(\.caption) ?? []
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

        if paper.figureData.isEmpty, let analysis {
            let recoveredFigures = analysis.figureData
            if !recoveredFigures.isEmpty {
                print("[PaperDocs] recovered \(recoveredFigures.count) figure(s) from staged analysis task=\(taskID)")
                updateFigureDataPreservingTimestamp(recoveredFigures, for: paper)
            }
        }

        if paper.figureData.isEmpty,
           let analysis,
           !analysis.figures.isEmpty,
           paper.status == .ready {
            print("[PaperDocs] required staged figures are unavailable; downgrading paper task=\(taskID)")
            updatePaperStatusPreservingTimestamp(.failed, for: paper)
            throw DocumentError.missingRequiredFigureAsset
        }

        let fingerprint = artifactFingerprint(for: paper)

        if let existing = PaperArtifactStore.renderedBundle(for: taskID, fingerprint: fingerprint) {
            print("[PaperDocs] using cached bundle task=\(taskID)")
            return existing
        }

        print("[PaperDocs] rendering bundle task=\(taskID)")
        let html = PaperHTMLBuilder.html(for: paper, figureCaptions: figureCaptions)
        let latex = ExportService.latexDocument(for: paper, figureCaptions: figureCaptions)
        let pdfData = try renderPDF(from: html)

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

    private static func renderPDF(from html: String) throws -> Data {
        print("[PaperDocs] renderPDF start html_chars=\(html.count)")
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
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
}

private final class PagedPaperRenderer: UIPrintPageRenderer {
    private let resolvedPaperRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private let resolvedPrintableRect = CGRect(x: 36, y: 36, width: 540, height: 720)

    override var paperRect: CGRect {
        resolvedPaperRect
    }

    override var printableRect: CGRect {
        resolvedPrintableRect
    }
}
