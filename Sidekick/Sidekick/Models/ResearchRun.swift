import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

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
            return "Writing paper"
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

enum ResearchExecutionBackend: String, Codable {
    case automatic
    case sidekickHosted = "sidekick_hosted"
    case userAPIKey = "user_api_key"
    case legacyChatGPTOAuth = "chatgpt_oauth"

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .sidekickHosted, .legacyChatGPTOAuth:
            return "Sidekick hosted"
        case .userAPIKey:
            return "API key"
        }
    }
}

enum ResearchRunQueueState: String, Codable {
    case queued
    case waitingForCurrentPaper = "waiting_for_current_paper"
    case nextInLine = "next_in_line"
    case held
}

enum ResearchRunSchedulingDisposition: String, Codable {
    case autoStart = "auto_start"
    case hold
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
    var executionBackendRaw: String?
    var queueStateRaw: String?
    var schedulingDispositionRaw: String?
    var sourceSupportTierRaw: String?
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
        executionBackend: ResearchExecutionBackend = .automatic,
        queueState: ResearchRunQueueState = .queued,
        schedulingDisposition: ResearchRunSchedulingDisposition = .autoStart,
        sourceSupportTier: TrustedDatasetSupportTier = .experimental,
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
        self.executionBackendRaw = executionBackend.rawValue
        self.queueStateRaw = queueState.rawValue
        self.schedulingDispositionRaw = schedulingDisposition.rawValue
        self.sourceSupportTierRaw = sourceSupportTier.rawValue
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

    var executionBackend: ResearchExecutionBackend {
        get {
            if let raw = executionBackendRaw,
               let backend = ResearchExecutionBackend(rawValue: raw) {
                if backend == .legacyChatGPTOAuth {
                    return .sidekickHosted
                }

                return backend
            }

            return status == .queued ? .automatic : .sidekickHosted
        }
        set {
            executionBackendRaw = newValue.rawValue
            touch()
        }
    }

    var queueState: ResearchRunQueueState {
        get { ResearchRunQueueState(rawValue: queueStateRaw ?? "") ?? .queued }
        set {
            queueStateRaw = newValue.rawValue
            touch()
        }
    }

    var schedulingDisposition: ResearchRunSchedulingDisposition {
        get { ResearchRunSchedulingDisposition(rawValue: schedulingDispositionRaw ?? "") ?? .autoStart }
        set {
            schedulingDispositionRaw = newValue.rawValue
            touch()
        }
    }

    var sourceSupportTier: TrustedDatasetSupportTier {
        get { TrustedDatasetSupportTier(rawValue: sourceSupportTierRaw ?? "") ?? .experimental }
        set {
            sourceSupportTierRaw = newValue.rawValue
            touch()
        }
    }

    var isTerminal: Bool {
        status == .completed || status == .failed
    }

    var isSchedulerEligible: Bool {
        status == .queued && schedulingDisposition == .autoStart
    }

    var currentStageTitle: String {
        currentStage.title
    }

    var listStatusLabel: String {
        switch status {
        case .queued:
            switch queueState {
            case .queued:
                return "Queued"
            case .held:
                return "Held"
            case .waitingForCurrentPaper:
                return "Waiting"
            case .nextInLine:
                return "Next in line"
            }
        case .running:
            return currentStage.title
        case .completed:
            return "Ready"
        case .failed:
            return "Needs retry"
        }
    }

    func attemptCount(for stage: ResearchRunStage) -> Int {
        attemptCount(forKey: stage.rawValue)
    }

    func incrementAttempt(for stage: ResearchRunStage) {
        incrementAttempt(forKey: stage.rawValue)
    }

    func decrementAttempt(for stage: ResearchRunStage) {
        decrementAttempt(forKey: stage.rawValue)
    }

    func resetAttemptCount(for stage: ResearchRunStage) {
        resetAttemptCount(forKey: stage.rawValue)
    }

    func attemptCount(forKey key: String) -> Int {
        stageAttempts[key] ?? 0
    }

    func incrementAttempt(forKey key: String) {
        var attempts = stageAttempts
        attempts[key] = (attempts[key] ?? 0) + 1
        stageAttempts = attempts
    }

    func decrementAttempt(forKey key: String) {
        var attempts = stageAttempts
        let current = attempts[key] ?? 0
        guard current > 0 else {
            return
        }

        if current == 1 {
            attempts.removeValue(forKey: key)
        } else {
            attempts[key] = current - 1
        }

        stageAttempts = attempts
    }

    func resetAttemptCount(forKey key: String) {
        var attempts = stageAttempts
        guard attempts.removeValue(forKey: key) != nil else {
            return
        }
        stageAttempts = attempts
    }

    func markRunning(stage: ResearchRunStage, message: String? = nil, activeTaskID: String? = nil) {
        currentStage = stage
        status = .running
        queueState = .queued
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
        queueState = .queued
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
        queueState = .queued
        activeTaskID = nil
        lastError = message
        latestProgressMessage = message
        latestProgressAt = .now
        touch()
    }

    func markQueued(
        message: String?,
        queueState: ResearchRunQueueState = .queued
    ) {
        status = .queued
        self.queueState = queueState
        activeTaskID = nil
        lastError = nil
        if let message {
            latestProgressMessage = message
            latestProgressAt = .now
        }
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

        if status == .queued {
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

extension Sequence where Element == ResearchRun {
    func latestRunsByPaperID() -> [UUID: ResearchRun] {
        reduce(into: [UUID: ResearchRun]()) { result, run in
            if let existing = result[run.paperID], existing.updatedAt >= run.updatedAt {
                return
            }

            result[run.paperID] = run
        }
    }

    func latestRun(for paperID: UUID) -> ResearchRun? {
        filter { $0.paperID == paperID }
            .max { lhs, rhs in
                lhs.updatedAt < rhs.updatedAt
            }
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryDatasetIDs = try container.decode([String].self, forKey: .primaryDatasetIDs)
        dataSources = try container.decode([String].self, forKey: .dataSources)
        sampleDescription = try container.decode(String.self, forKey: .sampleDescription)
        rowCount = try container.decodeIfPresent(Int.self, forKey: .rowCount)
        selectedVariables = try container.decode([String].self, forKey: .selectedVariables)

        if let notes = try? container.decode([String].self, forKey: .qualityNotes) {
            qualityNotes = notes
        } else if let note = try? container.decode(String.self, forKey: .qualityNotes) {
            qualityNotes = [note]
        } else {
            qualityNotes = []
        }
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        datasetManifest = try container.decode(ResearchDatasetManifest.self, forKey: .datasetManifest)
        accessNotes = try container.decode(String.self, forKey: .accessNotes)

        if let checks = try? container.decode([String].self, forKey: .qualityChecks) {
            qualityChecks = checks
        } else if let check = try? container.decode(String.self, forKey: .qualityChecks) {
            qualityChecks = [check]
        } else {
            qualityChecks = []
        }

        if let checklist = try? container.decode([String].self, forKey: .analysisChecklist) {
            analysisChecklist = checklist
        } else if let checklist = try? container.decode(String.self, forKey: .analysisChecklist) {
            analysisChecklist = [checklist]
        } else {
            analysisChecklist = []
        }
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
        guard let data = decodeSidekickBase64Payload(base64Data) else {
            return nil
        }

        return normalizedSidekickRenderableImageData(data)
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

nonisolated func isSidekickRenderableImageData(_ data: Data) -> Bool {
    normalizedSidekickRenderableImageData(data) != nil
}

nonisolated func normalizedSidekickRenderableImageData(_ data: Data) -> Data? {
    SidekickImageValidator.normalizedPNGData(from: data)
}

nonisolated func decodeSidekickBase64Payload(_ raw: String) -> Data? {
    var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // Long cloud-task messages can inject "... 123 chars truncated ..." into text output.
    guard normalized.range(
        of: #"(?:\d+\s+)?(?:chars|tokens)\s+truncated"#,
        options: [.regularExpression, .caseInsensitive]
    ) == nil else {
        return nil
    }

    if let commaIndex = normalized.firstIndex(of: ","),
       normalized[..<commaIndex].lowercased().contains("base64") {
        normalized = String(normalized[normalized.index(after: commaIndex)...])
    }

    normalized = normalized.replacingOccurrences(of: "\n", with: "")
    normalized = normalized.replacingOccurrences(of: "\r", with: "")
    normalized = normalized.replacingOccurrences(of: "\t", with: "")
    normalized = normalized.replacingOccurrences(of: " ", with: "")
    normalized = normalized.replacingOccurrences(of: "-", with: "+")
    normalized = normalized.replacingOccurrences(of: "_", with: "/")

    let base64Alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    normalized = String(String.UnicodeScalarView(
        normalized.unicodeScalars.filter { base64Alphabet.contains($0) }
    ))
    normalized = normalized.replacingOccurrences(of: "=", with: "")

    guard !normalized.isEmpty else {
        return nil
    }

    let remainder = normalized.count % 4
    if remainder != 0 {
        normalized.append(String(repeating: "=", count: 4 - remainder))
    }

    return Data(base64Encoded: normalized)
}

private enum SidekickImageValidator {
    private nonisolated static let maximumSampleDimension = 96
    private nonisolated static let minimumContrast = 8
    private nonisolated static let minimumForegroundDelta = 12
    private nonisolated static let minimumForegroundPixels = 12
    private nonisolated static let foregroundPixelDivisor = 500
    private nonisolated static let minimumPrintablePixelArea = 300_000
    private nonisolated static let minimumPrintableLongestSide = 900
    private nonisolated static let minimumPrintableShortestSide = 320

    nonisolated static func normalizedPNGData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0,
              hasPrintableResolution(image) else {
            return nil
        }

        // Backend-generated figures are already scoped to this paper bundle. Prefer
        // accepting any decodable print-sized image here rather than rejecting a
        // valid figure because contrast heuristics misclassify it as blank.
        return canonicalPNGData(for: image) ?? data
    }

    private nonisolated static func containsVisibleContent(_ image: CGImage) -> Bool {
        let sampleWidth = max(1, min(maximumSampleDimension, image.width))
        let sampleHeight = max(1, min(maximumSampleDimension, image.height))
        let pixelCount = sampleWidth * sampleHeight
        var pixels = [UInt8](repeating: 0, count: pixelCount)

        let drawSucceeded = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: sampleWidth,
                      height: sampleHeight,
                      bitsPerComponent: 8,
                      bytesPerRow: sampleWidth,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }

            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }

        guard drawSucceeded else {
            return false
        }

        let cornerIndexes = [
            0,
            sampleWidth - 1,
            (sampleHeight - 1) * sampleWidth,
            pixelCount - 1
        ]
        let backgroundValue = cornerIndexes
            .map { Int(pixels[$0]) }
            .reduce(0, +) / cornerIndexes.count

        var minValue = 255
        var maxValue = 0
        var nonBackgroundPixels = 0

        for pixel in pixels {
            let value = Int(pixel)
            minValue = min(minValue, value)
            maxValue = max(maxValue, value)

            if abs(value - backgroundValue) >= minimumForegroundDelta {
                nonBackgroundPixels += 1
            }
        }

        let minimumForeground = max(minimumForegroundPixels, pixelCount / foregroundPixelDivisor)
        return (maxValue - minValue) >= minimumContrast && nonBackgroundPixels >= minimumForeground
    }

    private nonisolated static func hasPrintableResolution(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        let longestSide = max(width, height)
        let shortestSide = min(width, height)
        let pixelArea = width * height

        return shortestSide >= minimumPrintableShortestSide
            && (longestSide >= minimumPrintableLongestSide || pixelArea >= minimumPrintablePixelArea)
    }

    private nonisolated static func canonicalPNGData(for image: CGImage) -> Data? {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return encoded as Data
    }
}

nonisolated struct ResearchDraftArtifact: Codable {
    let title: String
    let markdown: String
}

nonisolated struct ResearchRunPreparation {
    let selectedDatasetIDs: [String]
    let allowedDomains: [String]
    let registryVersion: Int
    let sourceSupportTier: TrustedDatasetSupportTier
    let schedulingDisposition: ResearchRunSchedulingDisposition
    let initialStatusMessage: String
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
