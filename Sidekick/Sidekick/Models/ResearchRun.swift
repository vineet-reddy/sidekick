import Foundation
import SwiftData

enum ResearchRunStage: String, Codable, CaseIterable {
    case plan
    case inspect
    case analyze
    case verify
    case write
    case typeset

    var title: String {
        switch self {
        case .plan:
            return "Planning"
        case .inspect:
            return "Inspecting data"
        case .analyze:
            return "Running analysis"
        case .verify:
            return "Verifying evidence"
        case .write:
            return "Drafting paper"
        case .typeset:
            return "Typesetting PDF"
        }
    }
}

enum ResearchRunStatus: String, Codable {
    case queued
    case running
    case completed
    case failed
}

enum ResearchRunPipelineStepState {
    case pending
    case active
    case completed
    case failed
}

@Model
final class ResearchRun {
    var id: UUID
    var runID: String
    var paperID: UUID
    var title: String
    var theme: String
    var sourceNoteIDsStorage: String
    var datasetIDsStorage: String
    var allowedDomainsStorage: String
    var stageAttemptsStorage: String
    var registryVersion: Int
    var stageRaw: String
    var statusRaw: String
    var activeTaskID: String?
    var lastError: String?
    var latestProgressMessage: String?
    var latestProgressAt: Date?
    var currentStageStartedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        runID: String,
        paperID: UUID,
        title: String,
        theme: String,
        sourceNoteIDs: [UUID],
        datasetIDs: [String],
        allowedDomains: [String],
        registryVersion: Int,
        currentStage: ResearchRunStage = .plan,
        status: ResearchRunStatus = .queued,
        activeTaskID: String? = nil,
        stageAttempts: [String: Int] = [:],
        lastError: String? = nil,
        latestProgressMessage: String? = nil,
        latestProgressAt: Date? = nil,
        currentStageStartedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.runID = runID
        self.paperID = paperID
        self.title = title
        self.theme = theme
        self.sourceNoteIDsStorage = Self.encode(sourceNoteIDs)
        self.datasetIDsStorage = Self.encode(datasetIDs)
        self.allowedDomainsStorage = Self.encode(allowedDomains)
        self.stageAttemptsStorage = Self.encode(stageAttempts)
        self.registryVersion = registryVersion
        self.stageRaw = currentStage.rawValue
        self.statusRaw = status.rawValue
        self.activeTaskID = activeTaskID
        self.lastError = lastError
        self.latestProgressMessage = latestProgressMessage
        self.latestProgressAt = latestProgressAt
        self.currentStageStartedAt = currentStageStartedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var sourceNoteIDs: [UUID] {
        get { Self.decode(sourceNoteIDsStorage, as: [UUID].self) ?? [] }
        set {
            sourceNoteIDsStorage = Self.encode(newValue)
            touch()
        }
    }

    var datasetIDs: [String] {
        get { Self.decode(datasetIDsStorage, as: [String].self) ?? [] }
        set {
            datasetIDsStorage = Self.encode(newValue)
            touch()
        }
    }

    var allowedDomains: [String] {
        get { Self.decode(allowedDomainsStorage, as: [String].self) ?? [] }
        set {
            allowedDomainsStorage = Self.encode(newValue)
            touch()
        }
    }

    var stageAttempts: [String: Int] {
        get { Self.decode(stageAttemptsStorage, as: [String: Int].self) ?? [:] }
        set {
            stageAttemptsStorage = Self.encode(newValue)
            touch()
        }
    }

    var currentStage: ResearchRunStage {
        get { ResearchRunStage(rawValue: stageRaw) ?? .plan }
        set {
            stageRaw = newValue.rawValue
            currentStageStartedAt = .now
            latestProgressMessage = newValue.title
            latestProgressAt = .now
            touch()
        }
    }

    var status: ResearchRunStatus {
        get { ResearchRunStatus(rawValue: statusRaw) ?? .queued }
        set {
            statusRaw = newValue.rawValue
            touch()
        }
    }

    var isTerminal: Bool {
        status == .completed || status == .failed
    }

    var currentStageTitle: String {
        currentStage.title
    }

    var listStatusLabel: String {
        switch status {
        case .queued:
            return "Queued"
        case .running:
            return currentStage.title
        case .completed:
            return "Ready"
        case .failed:
            return "Needs retry"
        }
    }

    func attemptCount(for stage: ResearchRunStage) -> Int {
        stageAttempts[stage.rawValue] ?? 0
    }

    func incrementAttempt(for stage: ResearchRunStage) {
        var attempts = stageAttempts
        attempts[stage.rawValue] = (attempts[stage.rawValue] ?? 0) + 1
        stageAttempts = attempts
    }

    func markRunning(stage: ResearchRunStage, message: String? = nil, activeTaskID: String? = nil) {
        currentStage = stage
        status = .running
        self.activeTaskID = activeTaskID
        lastError = nil
        if let message {
            latestProgressMessage = message
            latestProgressAt = .now
        }
        touch()
    }

    func markCompleted(message: String? = nil) {
        status = .completed
        activeTaskID = nil
        lastError = nil
        if let message {
            latestProgressMessage = message
            latestProgressAt = .now
        }
        touch()
    }

    func markFailed(message: String) {
        status = .failed
        activeTaskID = nil
        lastError = message
        latestProgressMessage = message
        latestProgressAt = .now
        touch()
    }

    func updateProgress(message: String?, at date: Date = .now) {
        guard let message, !message.isEmpty else {
            latestProgressAt = date
            touch()
            return
        }

        latestProgressMessage = message
        latestProgressAt = date
        touch()
    }

    func pipelineState(for stage: ResearchRunStage) -> ResearchRunPipelineStepState {
        let orderedStages = ResearchRunStage.allCases
        guard let currentIndex = orderedStages.firstIndex(of: currentStage),
              let targetIndex = orderedStages.firstIndex(of: stage) else {
            return .pending
        }

        if status == .completed {
            return .completed
        }

        if status == .failed && targetIndex == currentIndex {
            return .failed
        }

        if targetIndex < currentIndex {
            return .completed
        }

        if targetIndex == currentIndex {
            return .active
        }

        return .pending
    }

    private func touch() {
        updatedAt = .now
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }

        return string
    }

    private static func decode<T: Decodable>(_ value: String, as type: T.Type) -> T? {
        guard let data = value.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(type, from: data)
    }
}

nonisolated struct ResearchDatasetNeed: Codable {
    let datasetID: String?
    let role: String
    let variables: [String]
    let rationale: String

    enum CodingKeys: String, CodingKey {
        case datasetID = "dataset_id"
        case role
        case variables
        case rationale
    }
}

nonisolated struct ResearchFigurePlan: Codable {
    let identifier: String
    let title: String
    let purpose: String
}

nonisolated struct ResearchPlanArtifact: Codable {
    let question: String
    let hypotheses: [String]
    let datasetNeeds: [ResearchDatasetNeed]
    let candidateMethods: [String]
    let plannedFigures: [ResearchFigurePlan]
    let risks: [String]
    let executionNotes: String

    enum CodingKeys: String, CodingKey {
        case question
        case hypotheses
        case datasetNeeds = "dataset_needs"
        case candidateMethods = "candidate_methods"
        case plannedFigures = "planned_figures"
        case risks
        case executionNotes = "execution_notes"
    }
}

nonisolated struct ResearchDatasetManifest: Codable {
    let primaryDatasetIDs: [String]
    let dataSources: [String]
    let sampleDescription: String
    let rowCount: Int?
    let selectedVariables: [String]
    let qualityNotes: [String]

    enum CodingKeys: String, CodingKey {
        case primaryDatasetIDs = "primary_dataset_ids"
        case dataSources = "data_sources"
        case sampleDescription = "sample_description"
        case rowCount = "row_count"
        case selectedVariables = "selected_variables"
        case qualityNotes = "quality_notes"
    }
}

nonisolated struct ResearchInspectionArtifact: Codable {
    let datasetManifest: ResearchDatasetManifest
    let accessNotes: String
    let qualityChecks: [String]
    let analysisChecklist: [String]

    enum CodingKeys: String, CodingKey {
        case datasetManifest = "dataset_manifest"
        case accessNotes = "access_notes"
        case qualityChecks = "quality_checks"
        case analysisChecklist = "analysis_checklist"
    }
}

nonisolated struct ResearchFinding: Codable {
    let claim: String
    let estimate: String
    let uncertainty: String
    let evidence: String
    let supportsHypothesis: Bool?

    enum CodingKeys: String, CodingKey {
        case claim
        case estimate
        case uncertainty
        case evidence
        case supportsHypothesis = "supports_hypothesis"
    }
}

nonisolated struct ResearchTableArtifact: Codable {
    let identifier: String
    let title: String
    let columns: [String]
    let rows: [[String]]
    let notes: String?
}

nonisolated struct ResearchFigureArtifact: Codable {
    let filename: String
    let caption: String
    let mimeType: String
    let base64Data: String

    enum CodingKeys: String, CodingKey {
        case filename
        case caption
        case mimeType = "mime_type"
        case base64Data = "base64_data"
    }

    var imageData: Data? {
        decodeSidekickBase64Payload(base64Data)
    }
}

nonisolated struct ResearchAnalysisArtifact: Codable {
    let datasetManifest: ResearchDatasetManifest
    let narrativeSummary: String
    let findings: [ResearchFinding]
    let tables: [ResearchTableArtifact]
    let figures: [ResearchFigureArtifact]
    let limitations: [String]
    let provenance: TaskOutputProvenance

    enum CodingKeys: String, CodingKey {
        case datasetManifest = "dataset_manifest"
        case narrativeSummary = "narrative_summary"
        case findings
        case tables
        case figures
        case limitations
        case provenance
    }

    var figureData: [Data] {
        figures.compactMap(\.imageData)
    }
}

nonisolated enum ResearchVerificationDecision: String, Codable {
    case proceed
    case reviseAnalysis = "revise_analysis"
    case blocked

    var allowsWriting: Bool {
        self == .proceed
    }
}

nonisolated struct ResearchFigureSanityCheck: Codable {
    let filename: String
    let status: String
    let issue: String
}

nonisolated struct ResearchVerificationArtifact: Codable {
    let decision: ResearchVerificationDecision
    let summary: String
    let supportedClaims: [String]
    let weakOrUnsupportedClaims: [String]
    let figureSanityChecks: [ResearchFigureSanityCheck]
    let modelWarnings: [String]
    let sampleWarnings: [String]
    let requiredRevisions: [String]

    enum CodingKeys: String, CodingKey {
        case decision
        case summary
        case supportedClaims = "supported_claims"
        case weakOrUnsupportedClaims = "weak_or_unsupported_claims"
        case figureSanityChecks = "figure_sanity_checks"
        case modelWarnings = "model_warnings"
        case sampleWarnings = "sample_warnings"
        case requiredRevisions = "required_revisions"
    }

    var allowsWriting: Bool {
        decision.allowsWriting
    }

    var blockingMessage: String {
        let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryText.isEmpty {
            return summaryText
        }

        if let revision = requiredRevisions.first, !revision.isEmpty {
            return revision
        }

        if let weakClaim = weakOrUnsupportedClaims.first, !weakClaim.isEmpty {
            return weakClaim
        }

        return "Verification did not approve paper drafting from the current artifacts."
    }
}

nonisolated func decodeSidekickBase64Payload(_ raw: String) -> Data? {
    var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    if let commaIndex = normalized.firstIndex(of: ","),
       normalized[..<commaIndex].lowercased().contains("base64") {
        normalized = String(normalized[normalized.index(after: commaIndex)...])
    }

    normalized = normalized.replacingOccurrences(of: "\n", with: "")
    normalized = normalized.replacingOccurrences(of: "\r", with: "")
    normalized = normalized.replacingOccurrences(of: " ", with: "")

    guard !normalized.isEmpty else {
        return nil
    }

    let remainder = normalized.count % 4
    if remainder != 0 {
        normalized.append(String(repeating: "=", count: 4 - remainder))
    }

    return Data(base64Encoded: normalized)
}

nonisolated struct ResearchDraftArtifact: Codable {
    let title: String
    let markdown: String
}

nonisolated struct ResearchRunPreparation {
    let selectedDatasetIDs: [String]
    let allowedDomains: [String]
    let registryVersion: Int
    let planArtifact: ResearchPlanArtifact?
    let inspectionArtifact: ResearchInspectionArtifact?
    let analysisArtifact: ResearchAnalysisArtifact?
    let verificationArtifact: ResearchVerificationArtifact?
    let draftArtifact: ResearchDraftArtifact?
}

nonisolated enum ResearchInspectionTaskCheckResult {
    case waiting(PaperTaskProgressSnapshot)
    case completed(PaperTaskProgressSnapshot, ResearchInspectionArtifact)
    case failed(PaperTaskProgressSnapshot, String)
}

nonisolated enum ResearchAnalysisTaskCheckResult {
    case waiting(PaperTaskProgressSnapshot)
    case completed(PaperTaskProgressSnapshot, ResearchAnalysisArtifact)
    case failed(PaperTaskProgressSnapshot, String)
}
