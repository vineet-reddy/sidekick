import Foundation

enum PaperArtifactStore {
    private struct PendingSubmission: Codable {
        let taskID: String
        let title: String
        let registryVersion: Int
        let selectedDatasetIDs: [String]
        let allowedDomains: [String]
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

    static func persistPendingSubmission(_ submission: PaperTaskSubmission, title: String) throws {
        let pending = PendingSubmission(
            taskID: submission.taskID,
            title: title,
            registryVersion: submission.registryVersion,
            selectedDatasetIDs: submission.selectedDatasetIDs,
            allowedDomains: submission.allowedDomains,
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

    private static func submissionURL(for taskID: String) -> URL {
        directoryURL(for: taskID).appendingPathComponent("submission.json")
    }

    private static func provenanceURL(for taskID: String) -> URL {
        directoryURL(for: taskID).appendingPathComponent("provenance.json")
    }

    private static func directoryURL(for taskID: String) -> URL {
        let baseURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("PaperArtifacts", isDirectory: true)

        let taskURL = baseURL.appendingPathComponent(taskID, isDirectory: true)
        try? FileManager.default.createDirectory(at: taskURL, withIntermediateDirectories: true)
        return taskURL
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
}
