import Combine
import Foundation

struct NoteCluster: Codable, Hashable {
    let noteIDs: [UUID]
    let theme: String
    let suggestedTitle: String
    let isReady: Bool
    let datasetIDs: [String]
    let readinessMode: NoteClusterReadinessMode

    var isAutomaticallyRunnable: Bool {
        readinessMode == .trustedReady
    }
}

struct PaperExportMetadata {
    let repoURL: URL?
    let commitSHA: String?
    let repoPath: String?
    let publishedAt: Date?
    let manuscriptKind: PublishedManuscriptKind
}

struct PaperArtifacts {
    let title: String
    let markdown: String
    let latex: String
    let manuscriptKind: PublishedManuscriptKind
    let figureArtifacts: [ResearchFigureArtifact]
    let figures: [Data]
    let provenance: TaskOutputProvenance?
    let plan: ResearchPlanArtifact?
    let inspection: ResearchInspectionArtifact?
    let analysis: ResearchAnalysisArtifact?
    let verification: ResearchVerificationArtifact?
    let draft: ResearchDraftArtifact?
    let exportMetadata: PaperExportMetadata?
}

private struct ClusterResponse: Decodable {
    let clusters: [RawCluster]
}

private struct RawCluster: Decodable {
    let noteIDs: [String]
    let theme: String
    let suggestedTitle: String
    let datasetIDs: [String]?
    let readinessMode: String?
    let isReady: Bool?

    enum CodingKeys: String, CodingKey {
        case noteIDs
        case theme
        case suggestedTitle
        case datasetIDs = "dataset_ids"
        case readinessMode = "readiness_mode"
        case isReady = "is_ready"
    }
}

private struct PaperJobStatusResponse: Decodable {
    struct Metrics: Decodable {
        let model: String?
        let inputTokens: Int
        let outputTokens: Int
        let estimatedCostUSD: Double

        enum CodingKeys: String, CodingKey {
            case model
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case estimatedCostUSD = "estimated_cost_usd"
        }
    }

    let jobID: String
    let status: String
    let stage: String
    let progressMessage: String?
    let errorMessage: String?
    let openAIResponseID: String?
    let repoCommitSHA: String?
    let repoPath: String?
    let createdAt: Date?
    let updatedAt: Date?
    let completedAt: Date?
    let metrics: Metrics?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status
        case stage
        case progressMessage = "progress_message"
        case errorMessage = "error_message"
        case openAIResponseID = "openai_response_id"
        case repoCommitSHA = "repo_commit_sha"
        case repoPath = "repo_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case metrics
    }
}

private struct PaperArtifactsEnvelope: Decodable {
    let bundle: PaperBundlePayload
    let publication: PublicationPayload?
}

private struct PublicationPayload: Decodable {
    let repoURL: URL?
    let commitSHA: String?
    let repoPath: String?
    let publishedAt: Date?
    let manuscriptKind: PublishedManuscriptKind?

    enum CodingKeys: String, CodingKey {
        case repoURL = "repo_url"
        case commitSHA = "commit_sha"
        case repoPath = "repo_path"
        case publishedAt = "published_at"
        case manuscriptKind = "manuscript_kind"
    }
}

private struct AnalysisFilePayload: Decodable {
    let path: String
    let content: String
}

private struct PaperBundlePayload: Decodable {
    let title: String
    let manuscriptKind: PublishedManuscriptKind?
    let sections: ManuscriptSectionsPayload?
    let latex: String?
    let analysisFiles: [AnalysisFilePayload]?
    let figures: [ResearchFigureArtifact]?
    let manifest: [String: JSONValue]?
    let provenance: TaskOutputProvenance?
    let plan: ResearchPlanArtifact?
    let inspection: ResearchInspectionArtifact?
    let analysis: ResearchAnalysisArtifact?
    let verification: ResearchVerificationArtifact?
    let draft: ResearchDraftArtifact?

    enum CodingKeys: String, CodingKey {
        case title
        case manuscriptKind = "manuscript_kind"
        case sections
        case latex
        case analysisFiles = "analysis_files"
        case figures
        case manifest
        case provenance
        case plan
        case inspection
        case analysis
        case verification
        case draft
    }
}

private struct ManuscriptSectionsPayload: Decodable {
    let title: String?
    let abstract: String?
    let introduction: String?
    let methods: String?
    let results: String?
    let discussion: String?
    let limitations: String?
    let references: [String]?

    func markdownPreview(fallbackTitle: String, manuscriptKind: PublishedManuscriptKind) -> String {
        let resolvedTitle = (title ?? fallbackTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = manuscriptKind == .memo ? "Research Memo" : "Paper"
        var blocks = ["# \(resolvedTitle.isEmpty ? fallbackTitle : resolvedTitle)", "_\(heading)_"]
        let orderedSections: [(String, String?)] = [
            ("Abstract", abstract),
            ("Introduction", introduction),
            ("Methods", methods),
            ("Results", results),
            ("Discussion", discussion),
            ("Limitations", limitations),
        ]
        for (label, value) in orderedSections {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            blocks.append("## \(label)\n\n\(trimmed)")
        }
        let trimmedReferences = (references ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if !trimmedReferences.isEmpty {
            let list = trimmedReferences.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            blocks.append("## References\n\n\(list)")
        }
        return blocks.joined(separator: "\n\n")
    }
}

enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

@MainActor
final class OpenAIService: ObservableObject {
    enum ServiceError: LocalizedError {
        case backendNotConfigured
        case missingBackendSession
        case invalidResponse
        case malformedPayload
        case taskFailed(String)

        var errorDescription: String? {
            switch self {
            case .backendNotConfigured:
                return "Sidekick could not find its backend URL."
            case .missingBackendSession:
                return "Sidekick could not create a backend session."
            case .invalidResponse:
                return "The Sidekick backend returned an unexpected response."
            case .malformedPayload:
                return "The paper payload was malformed."
            case let .taskFailed(message):
                return message
            }
        }
    }

    private struct JobCreateResponse: Decodable {
        let jobID: String

        enum CodingKeys: String, CodingKey {
            case jobID = "job_id"
        }
    }

    private let github: GitHubService
    private let session: URLSession
    private let trustedDatasets: TrustedDatasetRegistry
    private let decoder = JSONDecoder()

    init(
        github: GitHubService,
        session: URLSession = .shared,
        trustedDatasets: TrustedDatasetRegistry? = nil
    ) {
        self.github = github
        self.session = session
        self.trustedDatasets = trustedDatasets ?? TrustedDatasetRegistry(session: session, remoteURL: nil)
        decoder.dateDecodingStrategy = .iso8601
    }

    func assessNotes(_ notes: [Note]) async throws -> [NoteCluster] {
        guard !notes.isEmpty else {
            return []
        }

        let response: ClusterResponse = try await performRequest(
            path: "api/notes/assess",
            method: "POST",
            body: [
                "notes": notes.map {
                    [
                        "id": $0.id.uuidString,
                        "title": $0.title,
                        "content": $0.content,
                    ]
                }
            ]
        )

        return response.clusters.compactMap { cluster in
            let noteIDs = cluster.noteIDs.compactMap(UUID.init(uuidString:))
            guard !noteIDs.isEmpty else {
                return nil
            }

            return NoteCluster(
                noteIDs: noteIDs,
                theme: cluster.theme,
                suggestedTitle: cluster.suggestedTitle,
                isReady: cluster.isReady ?? true,
                datasetIDs: cluster.datasetIDs ?? [],
                readinessMode: NoteClusterReadinessMode(rawValue: cluster.readinessMode ?? "") ?? .needsData
            )
        }
    }

    func prepareResearchRun(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String]
    ) async throws -> ResearchRunPreparation {
        _ = try? await github.ensureDeviceSession(forceRefresh: true)
        let combinedDatasetIDs = datasetIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let registryVersion = await trustedDatasets.registryVersion()
        let connected = github.isConnected

        return ResearchRunPreparation(
            selectedDatasetIDs: combinedDatasetIDs,
            allowedDomains: [],
            registryVersion: registryVersion,
            sourceSupportTier: combinedDatasetIDs.isEmpty ? .experimental : .supported,
            schedulingDisposition: connected ? .autoStart : .hold,
            initialStatusMessage: connected
                ? "Research queued on Sidekick-hosted compute."
                : "Connect GitHub to start this paper. Sidekick requires a public user-owned repo for every run.",
            planArtifact: nil,
            inspectionArtifact: nil,
            analysisArtifact: nil,
            verificationArtifact: nil,
            draftArtifact: nil
        )
    }

    func submitPaperTask(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String]
    ) async throws -> PaperTaskSubmission {
        let registryVersion = await trustedDatasets.registryVersion()
        let combinedDatasetIDs = datasetIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let allowedDomains: [String] = []
        let response: JobCreateResponse = try await performRequest(
            path: "api/papers",
            method: "POST",
            body: [
                "title": title,
                "theme": theme,
                "dataset_ids": combinedDatasetIDs,
                "dataset_hints": [],
                "allowed_domains": allowedDomains,
                "notes": notes.map {
                    [
                        "id": $0.id.uuidString,
                        "title": $0.title,
                        "content": $0.content,
                    ]
                }
            ]
        )

        return PaperTaskSubmission(
            taskID: response.jobID,
            selectedDatasetIDs: combinedDatasetIDs,
            allowedDomains: allowedDomains,
            registryVersion: registryVersion
        )
    }

    func checkTask(_ taskID: String) async throws -> PaperTaskCheckResult {
        let status: PaperJobStatusResponse = try await performRequest(
            path: "api/papers/\(taskID)",
            method: "GET"
        )
        let snapshot = PaperTaskProgressSnapshot(
            taskID: status.jobID,
            status: status.status,
            backendStage: status.stage,
            observedAt: .now,
            taskCreatedAt: status.createdAt,
            assistantTurnCreatedAt: status.updatedAt,
            latestEventAt: status.updatedAt,
            latestEventText: status.progressMessage,
            outputCharacterCount: 0,
            environmentID: nil,
            environmentLabel: "Sidekick Hosted",
            environmentNetworkMode: "on"
        )

        switch status.status {
        case "queued", "running":
            return .waiting(snapshot)
        case "completed":
            let envelope: PaperArtifactsEnvelope = try await performRequest(
                path: "api/papers/\(taskID)/artifacts",
                method: "GET"
            )
            let bundle = envelope.bundle
            let topLevelFigures = bundle.figures ?? bundle.analysis?.figures ?? []
            let decodedFigures = topLevelFigures.compactMap(\.imageData)
            let figureBytes = decodedFigures.isEmpty ? (bundle.analysis?.figureData ?? []) : decodedFigures
            let manuscriptKind = bundle.manuscriptKind ?? envelope.publication?.manuscriptKind ?? .paper
            let markdown = bundle.draft?.markdown
                ?? bundle.sections?.markdownPreview(
                    fallbackTitle: bundle.title,
                    manuscriptKind: manuscriptKind
                )
                ?? ""
            let artifacts = PaperArtifacts(
                title: bundle.title,
                markdown: markdown,
                latex: bundle.latex ?? "",
                manuscriptKind: manuscriptKind,
                figureArtifacts: topLevelFigures,
                figures: figureBytes,
                provenance: bundle.provenance ?? bundle.analysis?.provenance,
                plan: bundle.plan,
                inspection: bundle.inspection,
                analysis: bundle.analysis,
                verification: bundle.verification,
                draft: bundle.draft,
                exportMetadata: PaperExportMetadata(
                    repoURL: envelope.publication?.repoURL,
                    commitSHA: envelope.publication?.commitSHA ?? status.repoCommitSHA,
                    repoPath: envelope.publication?.repoPath ?? status.repoPath,
                    publishedAt: envelope.publication?.publishedAt,
                    manuscriptKind: manuscriptKind
                )
            )
            return .completed(snapshot, artifacts)
        case "failed":
            return .failed(snapshot, status.errorMessage ?? status.progressMessage ?? "The paper task failed.")
        default:
            return .waiting(snapshot)
        }
    }

    private func performRequest<Response: Decodable>(
        path: String,
        method: String,
        body: [String: Any]? = nil
    ) async throws -> Response {
        do {
            return try await performRequestOnce(path: path, method: method, body: body)
        } catch ServiceError.taskFailed(let message) where message == "invalid_session_token" {
            _ = try await github.ensureDeviceSession(forceRefresh: true)
            return try await performRequestOnce(path: path, method: method, body: body)
        }
    }

    private func performRequestOnce<Response: Decodable>(
        path: String,
        method: String,
        body: [String: Any]? = nil
    ) async throws -> Response {
        _ = try await github.ensureDeviceSession()
        guard let baseURL = backendBaseURL else {
            throw ServiceError.backendNotConfigured
        }
        guard let token = github.backendSession?.sessionToken else {
            throw ServiceError.missingBackendSession
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw decodeError(data: data)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw ServiceError.invalidResponse
        }
    }

    private var backendBaseURL: URL? {
        let environmentValue = ProcessInfo.processInfo.environment["SIDEKICK_BACKEND_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentValue, !environmentValue.isEmpty {
            return URL(string: environmentValue)
        }

        let infoValue = (Bundle.main.object(forInfoDictionaryKey: "SidekickGitHubBootstrapBaseURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let infoValue,
              !infoValue.isEmpty,
              !infoValue.contains("$(") else {
            return nil
        }
        return URL(string: infoValue)
    }

    private func decodeError(data: Data) -> Error {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ServiceError.invalidResponse
        }

        if let message = object["message"] as? String {
            return ServiceError.taskFailed(message)
        }
        if let error = object["error"] as? String {
            return ServiceError.taskFailed(error)
        }
        return ServiceError.invalidResponse
    }
}
