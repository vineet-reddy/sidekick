import Foundation

nonisolated struct PaperTaskProgressSnapshot: Codable {
    let taskID: String
    let status: String
    let observedAt: Date
    let taskCreatedAt: Date?
    let assistantTurnCreatedAt: Date?
    let latestEventAt: Date?
    let latestEventText: String?
    let outputCharacterCount: Int
    let environmentID: String?
    let environmentLabel: String?
}

nonisolated enum PaperTaskCheckResult {
    case waiting(PaperTaskProgressSnapshot)
    case completed(PaperTaskProgressSnapshot, PaperArtifacts)
    case failed(PaperTaskProgressSnapshot, String)
}
