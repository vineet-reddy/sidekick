import Foundation

enum LocalPaperGenerationService {
    static func supports(datasetIDs _: [String]) -> Bool {
        false
    }

    static func generateIfSupported(
        title _: String,
        theme _: String,
        noteTexts _: [String],
        selectedDatasets _: [TrustedDataset],
        session _: URLSession = .shared
    ) async throws -> PaperArtifacts? {
        nil
    }
}
