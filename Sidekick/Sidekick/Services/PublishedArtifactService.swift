import Foundation

struct PublishedManuscriptBundle {
    let pdfData: Data
    let latex: String
}

enum PublishedArtifactService {
    static func fetchManuscript(
        metadata: PaperArtifactStore.ExportMetadataSnapshot
    ) async throws -> PublishedManuscriptBundle? {
        guard let pdfURL = rawGitHubURL(
            metadata: metadata,
            filename: metadata.manuscriptKind == .memo ? "memo.pdf" : "paper.pdf"
        ),
        let latexURL = rawGitHubURL(
            metadata: metadata,
            filename: metadata.manuscriptKind == .memo ? "memo.tex" : "paper.tex"
        ) else {
            return nil
        }

        async let pdfFetch = URLSession.shared.data(from: pdfURL)
        async let latexFetch = URLSession.shared.data(from: latexURL)
        let ((pdfData, pdfResponse), (latexData, latexResponse)) = try await (pdfFetch, latexFetch)

        guard let pdfHTTP = pdfResponse as? HTTPURLResponse,
              (200 ..< 300).contains(pdfHTTP.statusCode),
              let latexHTTP = latexResponse as? HTTPURLResponse,
              (200 ..< 300).contains(latexHTTP.statusCode),
              let latex = String(data: latexData, encoding: .utf8),
              !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return PublishedManuscriptBundle(pdfData: pdfData, latex: latex)
    }

    static func rawGitHubURL(
        metadata: PaperArtifactStore.ExportMetadataSnapshot,
        filename: String
    ) -> URL? {
        guard let repoURL = metadata.repoURL,
              let repoPath = metadata.repoPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repoPath.isEmpty else {
            return nil
        }

        let components = repoURL.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else {
            return nil
        }

        let owner = components[0]
        let repo = components[1]
        let trimmedCommit = metadata.commitSHA?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ref = trimmedCommit.isEmpty ? "main" : trimmedCommit

        var urlComponents = URLComponents()
        urlComponents.scheme = "https"
        urlComponents.host = "raw.githubusercontent.com"
        urlComponents.path = "/\(owner)/\(repo)/\(ref)/\(repoPath)/\(filename)"
        return urlComponents.url
    }
}
