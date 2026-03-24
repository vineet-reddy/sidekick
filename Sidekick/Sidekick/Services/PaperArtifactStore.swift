import Foundation

enum PaperArtifactStore {
    struct PendingSubmissionSnapshot {
        let taskID: String
        let title: String
        let theme: String
        let registryVersion: Int
        let selectedDatasetIDs: [String]
        let allowedDomains: [String]
        let attemptCount: Int
        let createdAt: Date
    }

    struct RenderedPaperBundle {
        let directoryURL: URL
        let htmlURL: URL
        let pdfURL: URL
        let latexURL: URL?
    }

    struct ExportMetadataSnapshot {
        let repoURL: URL?
        let commitSHA: String?
        let repoPath: String?
        let publishedAt: Date?
        let manuscriptKind: PublishedManuscriptKind
    }

    private struct PendingSubmission: Codable {
        let taskID: String
        let title: String
        let theme: String
        let registryVersion: Int
        let selectedDatasetIDs: [String]
        let allowedDomains: [String]
        let attemptCount: Int
        let createdAt: Date
    }

    private struct StoredProvenance: Codable {
        let taskID: String
        let title: String
        let registryVersion: Int
        let selectedDatasetIDs: [String]
        let allowedDomains: [String]
        let usedDatasetIDs: [String]
        let accessedDomains: [String]
        let leftTrustedSet: Bool
        let externalSources: [String]
        let notes: String
        let createdAt: Date
        let completedAt: Date
    }

    private struct RenderedPaperManifest: Codable {
        let title: String
        let fingerprint: String
        let renderedAt: Date
        let figureCount: Int
    }

    private struct StoredExportMetadata: Codable {
        let repoURL: URL?
        let commitSHA: String?
        let repoPath: String?
        let publishedAt: Date
        let manuscriptKind: PublishedManuscriptKind?

        enum CodingKeys: String, CodingKey {
            case repoURL = "repo_url"
            case commitSHA = "commit_sha"
            case repoPath = "repo_path"
            case publishedAt = "published_at"
            case manuscriptKind = "manuscript_kind"
        }
    }

    static func persistPendingSubmission(
        _ submission: PaperTaskSubmission,
        title: String,
        theme: String,
        attemptCount: Int = 1
    ) throws {
        let pending = PendingSubmission(
            taskID: submission.taskID,
            title: title,
            theme: theme,
            registryVersion: submission.registryVersion,
            selectedDatasetIDs: submission.selectedDatasetIDs,
            allowedDomains: submission.allowedDomains,
            attemptCount: attemptCount,
            createdAt: .now
        )

        try write(pending, to: submissionURL(for: submission.taskID))
    }

    static func finalizeProvenance(
        taskID: String,
        title: String,
        modelProvenance: TaskOutputProvenance?
    ) throws {
        let pending = load(PendingSubmission.self, from: submissionURL(for: taskID))
        let provenance = StoredProvenance(
            taskID: taskID,
            title: title,
            registryVersion: pending?.registryVersion ?? 0,
            selectedDatasetIDs: pending?.selectedDatasetIDs ?? [],
            allowedDomains: pending?.allowedDomains ?? [],
            usedDatasetIDs: modelProvenance?.usedDatasetIDs ?? [],
            accessedDomains: modelProvenance?.accessedDomains ?? [],
            leftTrustedSet: modelProvenance?.leftTrustedSet ?? false,
            externalSources: modelProvenance?.externalSources ?? [],
            notes: modelProvenance?.notes ?? "The task completed without structured provenance from Codex.",
            createdAt: pending?.createdAt ?? .now,
            completedAt: .now
        )

        try write(provenance, to: provenanceURL(for: taskID))

        let submissionURL = submissionURL(for: taskID)
        if FileManager.default.fileExists(atPath: submissionURL.path) {
            try? FileManager.default.removeItem(at: submissionURL)
        }
    }

    static func pendingSubmission(for taskID: String) -> PendingSubmissionSnapshot? {
        guard let pending = load(PendingSubmission.self, from: submissionURL(for: taskID)) else {
            return nil
        }

        return PendingSubmissionSnapshot(
            taskID: pending.taskID,
            title: pending.title,
            theme: pending.theme,
            registryVersion: pending.registryVersion,
            selectedDatasetIDs: pending.selectedDatasetIDs,
            allowedDomains: pending.allowedDomains,
            attemptCount: pending.attemptCount,
            createdAt: pending.createdAt
        )
    }

    static func recordTaskProgress(_ snapshot: PaperTaskProgressSnapshot) throws {
        try write(snapshot, to: statusURL(for: snapshot.taskID))
    }

    static func taskProgress(for taskID: String) -> PaperTaskProgressSnapshot? {
        load(PaperTaskProgressSnapshot.self, from: statusURL(for: taskID))
    }

    static func persistExportMetadata(
        taskID: String,
        repoURL: URL?,
        commitSHA: String?,
        repoPath: String?,
        manuscriptKind: PublishedManuscriptKind = .paper,
        publishedAt: Date = .now
    ) throws {
        let metadata = StoredExportMetadata(
            repoURL: repoURL,
            commitSHA: commitSHA,
            repoPath: repoPath,
            publishedAt: publishedAt,
            manuscriptKind: manuscriptKind
        )
        try write(metadata, to: exportMetadataURL(for: taskID))
    }

    static func exportMetadata(for taskID: String) -> ExportMetadataSnapshot? {
        guard let stored = load(StoredExportMetadata.self, from: exportMetadataURL(for: taskID)) else {
            return nil
        }

        return ExportMetadataSnapshot(
            repoURL: stored.repoURL,
            commitSHA: stored.commitSHA,
            repoPath: stored.repoPath,
            publishedAt: stored.publishedAt,
            manuscriptKind: stored.manuscriptKind ?? .paper
        )
    }

    static func persistStageArtifact<T: Encodable>(
        _ artifact: T,
        runID: String,
        stage: ResearchRunStage
    ) throws {
        try write(artifact, to: stageArtifactURL(for: runID, stage: stage))
    }

    static func stageArtifact<T: Decodable>(
        _ type: T.Type,
        runID: String,
        stage: ResearchRunStage
    ) -> T? {
        load(type, from: stageArtifactURL(for: runID, stage: stage))
    }

    static func stageArtifactModifiedAt(
        runID: String,
        stage: ResearchRunStage
    ) -> Date? {
        let url = stageArtifactURL(for: runID, stage: stage)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    static func renderedBundle(for taskID: String, fingerprint: String) -> RenderedPaperBundle? {
        let manifestURL = renderManifestURL(for: taskID)
        guard let manifest = load(RenderedPaperManifest.self, from: manifestURL),
              manifest.fingerprint == fingerprint else {
            return nil
        }

        let directory = directoryURL(for: taskID)
        let htmlURL = directory.appendingPathComponent("paper.html")
        let pdfURL = directory.appendingPathComponent("paper.pdf")
        let latexURL = directory.appendingPathComponent("paper.tex")

        guard FileManager.default.fileExists(atPath: htmlURL.path),
              FileManager.default.fileExists(atPath: pdfURL.path) else {
            return nil
        }

        return RenderedPaperBundle(
            directoryURL: directory,
            htmlURL: htmlURL,
            pdfURL: pdfURL,
            latexURL: FileManager.default.fileExists(atPath: latexURL.path) ? latexURL : nil
        )
    }

    static func persistRenderedBundle(
        taskID: String,
        title: String,
        fingerprint: String,
        html: String,
        latex: String,
        figures: [Data],
        pdfData: Data
    ) throws -> RenderedPaperBundle {
        let directory = directoryURL(for: taskID)
        let htmlURL = directory.appendingPathComponent("paper.html")
        let pdfURL = directory.appendingPathComponent("paper.pdf")
        let latexURL = directory.appendingPathComponent("paper.tex")

        try removeExistingFigureFiles(in: directory)

        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        try latex.write(to: latexURL, atomically: true, encoding: .utf8)
        try pdfData.write(to: pdfURL, options: .atomic)

        for (index, figureData) in figures.enumerated() {
            let figureURL = directory.appendingPathComponent("figure_\(index + 1).png")
            try figureData.write(to: figureURL, options: .atomic)
        }

        let manifest = RenderedPaperManifest(
            title: title,
            fingerprint: fingerprint,
            renderedAt: .now,
            figureCount: figures.count
        )
        try write(manifest, to: renderManifestURL(for: taskID))

        return RenderedPaperBundle(
            directoryURL: directory,
            htmlURL: htmlURL,
            pdfURL: pdfURL,
            latexURL: latexURL
        )
    }

    static func deleteArtifacts(for taskID: String) {
        let directory = existingDirectoryURL(for: taskID)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }

        try? FileManager.default.removeItem(at: directory)
    }

    private static func submissionURL(for taskID: String) -> URL {
        directoryURL(for: taskID).appendingPathComponent("submission.json")
    }

    private static func provenanceURL(for taskID: String) -> URL {
        directoryURL(for: taskID).appendingPathComponent("provenance.json")
    }

    private static func statusURL(for taskID: String) -> URL {
        directoryURL(for: taskID).appendingPathComponent("status.json")
    }

    private static func renderManifestURL(for taskID: String) -> URL {
        directoryURL(for: taskID).appendingPathComponent("rendered.json")
    }

    private static func exportMetadataURL(for taskID: String) -> URL {
        directoryURL(for: taskID).appendingPathComponent("export.json")
    }

    private static func stageArtifactURL(for runID: String, stage: ResearchRunStage) -> URL {
        directoryURL(for: runID).appendingPathComponent("stage-\(stage.rawValue).json")
    }

    private static func directoryURL(for taskID: String) -> URL {
        let taskURL = existingDirectoryURL(for: taskID)
        try? FileManager.default.createDirectory(at: taskURL, withIntermediateDirectories: true)
        return taskURL
    }

    private static func existingDirectoryURL(for taskID: String) -> URL {
        let baseURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("PaperArtifacts", isDirectory: true)

        let key = storageKey(for: taskID)
        return baseURL.appendingPathComponent(key, isDirectory: true)
    }

    private static func storageKey(for taskID: String) -> String {
        let trimmed = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "paper-artifact" : trimmed
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func removeExistingFigureFiles(in directory: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        for url in contents where url.lastPathComponent.hasPrefix("figure_") && url.pathExtension == "png" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
