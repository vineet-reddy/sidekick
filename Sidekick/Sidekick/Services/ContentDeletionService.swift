import Foundation
import SwiftData

@MainActor
enum ContentDeletionService {
    static func deleteNote(_ note: Note, modelContext: ModelContext) throws {
        let papers = try modelContext.fetch(FetchDescriptor<Paper>())
        let runs = try modelContext.fetch(FetchDescriptor<ResearchRun>())

        for paper in papers where paper.sourceNoteIDs.contains(note.id) {
            let remainingNoteIDs = paper.sourceNoteIDs.filter { $0 != note.id }
            paper.sourceNoteIDs = remainingNoteIDs

            if remainingNoteIDs.isEmpty, paper.status == .generating {
                paper.status = .failed
            }
        }

        for run in runs where run.sourceNoteIDs.contains(note.id) {
            let remainingNoteIDs = run.sourceNoteIDs.filter { $0 != note.id }
            run.sourceNoteIDs = remainingNoteIDs

            if remainingNoteIDs.isEmpty {
                run.markFailed(message: "The source notes were deleted from this research run.")
                if let paper = papers.first(where: { $0.id == run.paperID }), paper.status == .generating {
                    paper.status = .failed
                }
            }
        }

        modelContext.delete(note)
        try modelContext.save()
    }

    static func deletePaper(_ paper: Paper, modelContext: ModelContext) throws {
        let runs = try modelContext.fetch(FetchDescriptor<ResearchRun>())
            .filter { $0.paperID == paper.id }

        var artifactKeys = Set<String>()
        artifactKeys.insert(paper.codexTaskID)

        for run in runs {
            artifactKeys.insert(run.runID)
            if let activeTaskID = run.activeTaskID {
                artifactKeys.insert(activeTaskID)
            }

            modelContext.delete(run)
        }

        modelContext.delete(paper)
        try modelContext.save()

        for key in artifactKeys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            PaperArtifactStore.deleteArtifacts(for: trimmed)
        }
    }
}
