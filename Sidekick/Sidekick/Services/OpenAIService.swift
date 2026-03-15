import Combine
import Foundation
import zlib

struct NoteCluster: Codable, Hashable {
    let noteIDs: [UUID]
    let theme: String
    let suggestedTitle: String
    let isReady: Bool
    let datasetIDs: [String]
    let readinessMode: NoteClusterReadinessMode

    var isAutomaticallyRunnable: Bool {
        readinessMode == .trustedReady && !datasetIDs.isEmpty
    }
}

struct PaperArtifacts {
    let title: String
    let markdown: String
    let figures: [Data]
    let provenance: TaskOutputProvenance?
}

final class OpenAIService: ObservableObject {
    enum ServiceError: LocalizedError {
        case invalidResponse
        case missingTaskID
        case taskFailed(String)
        case malformedPayload

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "OpenAI returned an unexpected response."
            case .missingTaskID:
                return "Sidekick could not start the paper task."
            case let .taskFailed(message):
                return message
            case .malformedPayload:
                return "The paper payload was malformed."
            }
        }
    }

    private let auth: AuthService
    private let session: URLSession
    private let backendBaseURL = URL(string: "https://chatgpt.com/backend-api")!
    private let apiBaseURL = URL(string: "https://api.openai.com/v1")!
    private let originator = "codex_cli_rs"
    private let modelRouter = OpenAIModelRouter()
    private let environmentRouter = OpenAIEnvironmentRouter()
    private let researchStageFallbackRouter = OpenAIResearchStageFallbackRouter()
    private let trustedDatasets: TrustedDatasetRegistry
    private let stageFallback: ResearchStageFallbackService

    init(
        auth: AuthService,
        session: URLSession = .shared,
        trustedDatasets: TrustedDatasetRegistry? = nil
    ) {
        self.auth = auth
        self.session = session
        let registry = trustedDatasets ?? TrustedDatasetRegistry(session: session)
        self.trustedDatasets = registry
        stageFallback = ResearchStageFallbackService(session: session)

        Task {
            await registry.refreshIfNeeded()
        }
    }

    func assessNotes(_ notes: [Note]) async throws -> [NoteCluster] {
        guard !notes.isEmpty else {
            return []
        }

        log("assessNotes starting. notes=\(notes.count)")

        let notesPayload = notes.map { note in
            [
                "id": note.id.uuidString,
                "content": note.content,
                "createdAt": ISO8601DateFormatter().string(from: note.createdAt)
            ]
        }
        let shortlistedDatasets = await trustedDatasets.assessmentShortlist(
            noteTexts: notes.map(\.content),
            limit: 10
        )
        let datasetGuide = shortlistedDatasets.isEmpty
            ? "- No trusted dataset cards are currently loaded."
            : shortlistedDatasets.map { $0.assessmentLine() }.joined(separator: "\n")

        let systemInstructions = """
        You are a research assistant. Group these notes into thematic clusters.
        Be eager with clustering, but conservative about automatic paper generation.

        Readiness modes:
        - trusted_ready: at least one trusted dataset card clearly fits; set is_ready to true
        - trusted_partial: trusted data exists but the paper would be weak or incomplete; set is_ready to false
        - exploratory_ready: the idea likely needs unvetted external data; set is_ready to false

        Use only dataset_ids from the trusted dataset cards below. Prefer at most 3 dataset_ids per cluster.

        Return strict JSON only with this shape:
        {
          "clusters": [
            {
              "noteIDs": ["UUID"],
              "theme": "string",
              "suggestedTitle": "string",
              "dataset_ids": ["trusted-dataset-id"],
              "readiness_mode": "trusted_ready",
              "is_ready": true
            }
          ]
        }
        """

        let userInput = """
        Trusted dataset cards:
        \(datasetGuide)

        Notes:
        \(stringify(notesPayload))
        """

        log("assessNotes creating /codex/responses request")
        let response = try await createResponse(
            for: .noteAssessment,
            tools: [],
            instructions: systemInstructions,
            input: userInput
        )

        let text = response.outputText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        log("assessNotes response completed. status=\(response.status) id=\(response.id ?? "<none>") output_chars=\(text.count)")
        log("assessNotes output preview: \(preview(text, limit: 320))")

        guard let data = normalizedJSONData(from: text) else {
            log("assessNotes normalizedJSONData returned nil")
            throw ServiceError.malformedPayload
        }

        do {
            let decoded = try JSONDecoder().decode(ClusterResponse.self, from: data)
            log("assessNotes decoded clusters successfully. cluster_count=\(decoded.clusters.count)")
            return decoded.clusters.compactMap { rawCluster in
                let ids = rawCluster.noteIDs.compactMap(UUID.init(uuidString:))
                guard !ids.isEmpty else {
                    return nil
                }

                let readinessMode = NoteClusterReadinessMode(rawValue: rawCluster.readinessMode ?? "")
                    ?? ((rawCluster.isReady ?? false) ? .trustedReady : .exploratoryReady)
                let datasetIDs = rawCluster.datasetIDs ?? []
                let isReady = rawCluster.isReady ?? (readinessMode == .trustedReady)

                return NoteCluster(
                    noteIDs: ids,
                    theme: rawCluster.theme,
                    suggestedTitle: rawCluster.suggestedTitle,
                    isReady: isReady,
                    datasetIDs: datasetIDs,
                    readinessMode: readinessMode
                )
            }
        } catch {
            log("assessNotes failed to decode ClusterResponse: \(String(describing: error))")
            log("assessNotes normalized JSON preview: \(preview(String(data: data, encoding: .utf8) ?? "<non-utf8>", limit: 320))")
            throw error
        }
    }

    func prepareResearchRun(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String]
    ) async throws -> ResearchRunPreparation {
        let noteTexts = notes.map(\.content)
        let selectedDatasets = await trustedDatasets.taskDatasetSelection(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            limit: 4
        )
        let allowedDomains = TrustedDatasetRegistry.allowedDomains(for: selectedDatasets)
        let registryVersion = await trustedDatasets.registryVersion()

        if let localArtifacts = try await LocalPaperGenerationService.generateIfSupported(
            title: title,
            theme: theme,
            noteTexts: noteTexts,
            selectedDatasets: selectedDatasets,
            session: session
        ) {
            return ResearchRunPreparation(
                selectedDatasetIDs: selectedDatasets.map(\.id),
                allowedDomains: allowedDomains,
                registryVersion: registryVersion,
                planArtifact: localPlanArtifact(
                    title: title,
                    theme: theme,
                    selectedDatasets: selectedDatasets
                ),
                inspectionArtifact: localInspectionArtifact(
                    selectedDatasets: selectedDatasets,
                    artifacts: localArtifacts
                ),
                analysisArtifact: localAnalysisArtifact(
                    selectedDatasets: selectedDatasets,
                    artifacts: localArtifacts
                ),
                verificationArtifact: localVerificationArtifact(
                    selectedDatasets: selectedDatasets,
                    artifacts: localArtifacts
                ),
                draftArtifact: ResearchDraftArtifact(
                    title: localArtifacts.title,
                    markdown: localArtifacts.markdown
                )
            )
        }

        return ResearchRunPreparation(
            selectedDatasetIDs: selectedDatasets.map(\.id),
            allowedDomains: allowedDomains,
            registryVersion: registryVersion,
            planArtifact: nil,
            inspectionArtifact: nil,
            analysisArtifact: nil,
            verificationArtifact: nil,
            draftArtifact: nil
        )
    }

    func createResearchPlan(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String]
    ) async throws -> ResearchPlanArtifact {
        let selectedDatasets = await trustedDatasets.taskDatasetSelection(
            datasetIDs: datasetIDs,
            noteTexts: notes.map(\.content),
            limit: 4
        )
        let datasetCards = selectedDatasets.isEmpty
            ? "- No trusted dataset cards were resolved for this run."
            : selectedDatasets.map { $0.taskLine() }.joined(separator: "\n")
        let notesBody = notes.map { note in
            [
                "id": note.id.uuidString,
                "content": note.content
            ]
        }

        let instructions = """
        You are planning a scientific research run.
        Return strict JSON only with this exact shape:
        {
          "question": "string",
          "hypotheses": ["string"],
          "dataset_needs": [
            {
              "dataset_id": "trusted-dataset-id or null",
              "role": "primary or supporting",
              "variables": ["string"],
              "rationale": "string"
            }
          ],
          "candidate_methods": ["string"],
          "planned_figures": [
            {
              "identifier": "figure_1",
              "title": "string",
              "purpose": "string"
            }
          ],
          "risks": ["string"],
          "execution_notes": "string"
        }

        Requirements:
        - Use only the provided notes and trusted dataset cards.
        - Keep the plan concise, empirical, and executable.
        - Do not write the paper yet.
        """

        let input = """
        Suggested title: \(title)
        Theme: \(theme)

        Trusted dataset cards:
        \(datasetCards)

        Notes:
        \(stringify(notesBody))
        """

        let response = try await createResponse(
            for: .paperGeneration,
            tools: [],
            instructions: instructions,
            input: input
        )

        return try decodeStructuredPayload(ResearchPlanArtifact.self, from: response.outputText)
    }

    func startResearchAnalysisTask(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String],
        allowedDomains: [String],
        plan: ResearchPlanArtifact,
        inspection: ResearchInspectionArtifact,
        revisionRequest: ResearchVerificationArtifact? = nil
    ) async throws -> String {
        let selectedDatasets = await trustedDatasets.taskDatasetSelection(
            datasetIDs: datasetIDs,
            noteTexts: notes.map(\.content),
            limit: 4
        )
        let datasetCards = selectedDatasets.isEmpty
            ? "- No trusted dataset cards were resolved for this run."
            : selectedDatasets.map { $0.taskLine() }.joined(separator: "\n")
        let datasetGuidance = datasetExecutionGuidance(for: selectedDatasets, stage: .analyze)
        let allowedDomainText = allowedDomains.isEmpty ? "none" : allowedDomains.joined(separator: ", ")
        let notesBody = notes.map { note in
            "- [\(note.id.uuidString)] \(note.content)"
        }.joined(separator: "\n\n")

        let prompt = """
        You are a research scientist using Code Interpreter.
        Run the empirical analysis only. The dataset inspection checkpoint has already happened. Do not write the paper yet.

        Requirements:
        1. Prefer the vetted dataset cards below and the inspected manifest before using anything else.
        2. Keep internet usage inside the approved domains unless those sources are blocked or insufficient.
        3. Stay aligned with the inspected dataset slice unless inspection clearly missed a blocker.
        4. Access real data, run the analysis, and produce real figures when warranted.
        5. Return strict JSON only with this exact shape:
           {
             "dataset_manifest": {
               "primary_dataset_ids": ["trusted-dataset-id"],
               "data_sources": ["string"],
               "sample_description": "string",
               "row_count": 123,
               "selected_variables": ["string"],
               "quality_notes": ["string"]
             },
             "narrative_summary": "string",
             "findings": [
               {
                 "claim": "string",
                 "estimate": "string",
                 "uncertainty": "string",
                 "evidence": "string",
                 "supports_hypothesis": true
               }
             ],
             "tables": [
               {
                 "identifier": "table_1",
                 "title": "string",
                 "columns": ["string"],
                 "rows": [["string"]],
                 "notes": "string"
               }
             ],
             "figures": [
               {
                 "filename": "figure_1.png",
                 "caption": "string",
                 "mime_type": "image/png",
                 "base64_data": "base64 png bytes"
               }
             ],
             "limitations": ["string"],
             "provenance": {
               "used_dataset_ids": ["trusted-dataset-id"],
               "accessed_domains": ["domain"],
               "left_trusted_set": false,
               "external_sources": ["optional domain or source name"],
               "notes": "short summary of data access and limits"
             }
           }
        6. Include concrete estimates, diagnostics, sample sizes, and uncertainty whenever the data support them.
        7. If the analysis cannot be completed, maximize the structured evidence you can deliver instead of returning a memo.
        8. Name the exact public cohort, project, study, collection, archive table, or mission slice you analyzed in `dataset_manifest`.
        9. Keep the run inside one public dataset slice unless a hard blocker forces a narrow adjacent fallback.
        10. `findings[].evidence` must cite concrete observed counts, variables, subgroup definitions, or figure/table identifiers from this run.
        11. If a full inferential model is not supportable, return the strongest trustworthy descriptive cohort analysis you can instead of stalling.
        12. The final assistant message must contain only the JSON object and nothing before or after it.
        13. If verification guidance is supplied below, address every required revision directly in the returned findings, tables, or limitations.
        14. Report sex distributions or explicitly explain why the supplied bundle cannot support them.

        Suggested title: \(title)
        Theme: \(theme)
        Approved domains: \(allowedDomainText)

        Trusted dataset cards:
        \(datasetCards)

        Dataset-specific execution guardrails:
        \(datasetGuidance)

        Notes:
        \(notesBody)

        Research plan JSON:
        \(prettyJSONString(plan))

        Research inspection JSON:
        \(stringify(inspectionPromptPayload(from: inspection)))
        \(revisionRequest.map { """

        Verification revision JSON:
        \(stringify(verificationPromptPayload(from: $0)))
        """ } ?? "")
        """

        return try await createTask(prompt: prompt)
    }

    func quarantineSelfContainedBundleEnvironment(_ environmentID: String?) async {
        guard let environmentID,
              !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        await environmentRouter.quarantine(environmentID, for: .selfContainedBundle)
    }

    func supportsBundledResearchFallback(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) async -> Bool {
        await stageFallback.supportsFallback(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            theme: theme
        )
    }

    func runResearchInspectionFallback(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String],
        plan: ResearchPlanArtifact
    ) async throws -> ResearchInspectionArtifact {
        let noteTexts = notes.map(\.content)
        guard let fallback = try await stageFallback.inspectionInput(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            theme: theme
        ) else {
            throw ServiceError.taskFailed("No staged responses fallback is available for this dataset slice yet.")
        }

        let selectedDatasets = await trustedDatasets.taskDatasetSelection(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            limit: 4
        )
        let datasetCards = selectedDatasets.isEmpty
            ? "- No trusted dataset cards were resolved for this run."
            : selectedDatasets.map { $0.taskLine() }.joined(separator: "\n")
        let datasetGuidance = datasetExecutionGuidance(for: selectedDatasets, stage: .inspect)
        let notesBody = notes.map { note in
            "- [\(note.id.uuidString)] \(note.content)"
        }.joined(separator: "\n\n")

        let instructions = """
        You are a research scientist using Code Interpreter.
        A thin local orchestrator has already fetched a narrow public cohort slice from a trusted source.
        Inspect only that supplied bundle. Do not widen the cohort, do not switch studies, and do not run the final analysis yet.

        Return strict JSON only with this exact shape:
        {
          "dataset_manifest": {
            "primary_dataset_ids": ["trusted-dataset-id"],
            "data_sources": ["string"],
            "sample_description": "string",
            "row_count": 123,
            "selected_variables": ["string"],
            "quality_notes": ["string"]
          },
          "access_notes": "string",
          "quality_checks": ["string"],
          "analysis_checklist": ["string"]
        }

        Requirements:
        - Use Code Interpreter to validate and summarize the supplied bundle only.
        - Keep the manifest anchored to the exact study ID, coverage counts, and variables present in the bundle.
        - Prefer the strongest honest reachable slice over the broader original ambition.
        - If MGMT is only available as continuous methylation values, state that explicitly rather than inventing a binary promoter annotation.
        - `selected_variables` must contain exact field names from the supplied bundle.
        - The final assistant message must contain only the JSON object and nothing before or after it.
        """

        let input = """
        Suggested title: \(title)
        Theme: \(theme)

        Trusted dataset cards:
        \(datasetCards)

        Dataset-specific execution guardrails:
        \(datasetGuidance)

        Notes:
        \(notesBody)

        Research plan JSON:
        \(prettyJSONString(plan))

        Resolved public cohort bundle (\(fallback.providerLabel)) JSON:
        \(fallback.promptJSON)
        """

        let response = try await createResearchStageFallbackResponse(
            instructions: instructions,
            input: input
        )

        return try decodeStructuredPayload(ResearchInspectionArtifact.self, from: response.outputText)
    }

    func startBundledResearchInspectionTask(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String],
        plan: ResearchPlanArtifact
    ) async throws -> String {
        let noteTexts = notes.map(\.content)
        guard let fallback = try await stageFallback.inspectionInput(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            theme: theme
        ) else {
            throw ServiceError.taskFailed("No staged remote fallback is available for this inspection slice yet.")
        }

        let selectedDatasets = await trustedDatasets.taskDatasetSelection(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            limit: 4
        )
        let datasetCards = selectedDatasets.isEmpty
            ? "- No trusted dataset cards were resolved for this run."
            : selectedDatasets.map { $0.taskLine() }.joined(separator: "\n")
        let datasetGuidance = datasetExecutionGuidance(for: selectedDatasets, stage: .inspect)
        let notesBody = notes.map { note in
            "- [\(note.id.uuidString)] \(note.content)"
        }.joined(separator: "\n\n")

        let prompt = """
        You are a research scientist working inside a Codex task with Python available.
        A thin local coordinator already fetched a narrow trusted public cohort bundle. Use only that supplied bundle.
        Treat network access as unavailable for this task even if the environment technically exposes it.

        Requirements:
        1. Do not rely on repository files or repository context; the repo is irrelevant to this task.
        2. Do not make network requests, browse for external data, or hit live APIs. The supplied bundle is authoritative for this task.
        3. Do not widen the cohort, switch studies, or browse for replacement data unless the supplied bundle is malformed.
        4. Inspect the supplied bundle only and return strict JSON only with this exact shape:
           {
             "dataset_manifest": {
               "primary_dataset_ids": ["trusted-dataset-id"],
               "data_sources": ["string"],
               "sample_description": "string",
               "row_count": 123,
               "selected_variables": ["string"],
               "quality_notes": ["string"]
             },
             "access_notes": "string",
             "quality_checks": ["string"],
             "analysis_checklist": ["string"]
           }
        5. If MGMT is only available as continuous methylation values, say that explicitly instead of inventing a binary promoter status field.
        6. If the supplied bundle lacks something you wanted to inspect, record that limitation in `quality_checks` instead of trying to fetch replacement data.
        7. The final assistant message must contain only the JSON object and nothing before or after it.

        Suggested title: \(title)
        Theme: \(theme)

        Trusted dataset cards:
        \(datasetCards)

        Dataset-specific execution guardrails:
        \(datasetGuidance)

        Notes:
        \(notesBody)

        Research plan JSON:
        \(prettyJSONString(plan))

        Resolved public cohort bundle (\(fallback.providerLabel)) JSON:
        \(fallback.promptJSON)
        """

        return try await createTask(prompt: prompt, preference: .selfContainedBundle)
    }

    func startResearchInspectionTask(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String],
        allowedDomains: [String],
        plan: ResearchPlanArtifact
    ) async throws -> String {
        let selectedDatasets = await trustedDatasets.taskDatasetSelection(
            datasetIDs: datasetIDs,
            noteTexts: notes.map(\.content),
            limit: 4
        )
        let datasetCards = selectedDatasets.isEmpty
            ? "- No trusted dataset cards were resolved for this run."
            : selectedDatasets.map { $0.taskLine() }.joined(separator: "\n")
        let datasetGuidance = datasetExecutionGuidance(for: selectedDatasets, stage: .inspect)
        let allowedDomainText = allowedDomains.isEmpty ? "none" : allowedDomains.joined(separator: ", ")
        let notesBody = notes.map { note in
            "- [\(note.id.uuidString)] \(note.content)"
        }.joined(separator: "\n\n")

        let prompt = """
        You are a research scientist using Code Interpreter.
        Resolve the best reachable dataset slice and inspect it only. Do not run the final analysis yet.

        Requirements:
        1. Prefer the vetted dataset cards below before using anything else.
        2. Keep internet usage inside the approved domains unless those sources are blocked or insufficient.
        3. Resolve a concrete dataset slice, inspect the schema or metadata, and report what is actually usable for analysis.
        4. Return strict JSON only with this exact shape:
           {
             "dataset_manifest": {
               "primary_dataset_ids": ["trusted-dataset-id"],
               "data_sources": ["string"],
               "sample_description": "string",
               "row_count": 123,
               "selected_variables": ["string"],
               "quality_notes": ["string"]
             },
             "access_notes": "string",
             "quality_checks": ["string"],
             "analysis_checklist": ["string"]
           }
        5. Prefer a small, concrete, trustworthy slice over a broad speculative one.
        6. Capture any blockers or limitations you uncovered during inspection in `quality_checks`.
        7. Return exact dataset slice identifiers, study IDs, project IDs, collection IDs, or table names whenever the source exposes them.
        8. `selected_variables` must name real fields, endpoints, or metadata keys that were actually inspected.
        9. If the preferred source is only partially reachable, keep the strongest narrow slice from that source instead of switching domains silently.
        10. The final assistant message must contain only the JSON object and nothing before or after it.

        Suggested title: \(title)
        Theme: \(theme)
        Approved domains: \(allowedDomainText)

        Trusted dataset cards:
        \(datasetCards)

        Dataset-specific execution guardrails:
        \(datasetGuidance)

        Notes:
        \(notesBody)

        Research plan JSON:
        \(prettyJSONString(plan))
        """

        return try await createTask(prompt: prompt)
    }

    func checkResearchInspectionTask(_ taskID: String) async throws -> ResearchInspectionTaskCheckResult {
        let task = try await fetchTask(taskID: taskID)
        let snapshot = task.progressSnapshot(taskID: taskID)
        persistDebugPayload(Data(task.outputText.utf8), named: "inspection-task-output-\(taskID).txt")

        switch task.normalizedStatus {
        case "queued", "in_progress", "incomplete":
            return .waiting(snapshot)
        case "completed":
            break
        case "failed", "cancelled":
            return .failed(snapshot, task.errorMessage ?? "The dataset inspection task failed.")
        default:
            return .waiting(snapshot)
        }

        let artifact = try decodeStructuredPayload(ResearchInspectionArtifact.self, from: task.outputText)
        return .completed(snapshot, artifact)
    }

    func checkResearchAnalysisTask(_ taskID: String) async throws -> ResearchAnalysisTaskCheckResult {
        let task = try await fetchTask(taskID: taskID)
        let snapshot = task.progressSnapshot(taskID: taskID)
        persistDebugPayload(Data(task.outputText.utf8), named: "analysis-task-output-\(taskID).txt")

        switch task.normalizedStatus {
        case "queued", "in_progress", "incomplete":
            return .waiting(snapshot)
        case "completed":
            break
        case "failed", "cancelled":
            return .failed(snapshot, task.errorMessage ?? "The analysis task failed.")
        default:
            return .waiting(snapshot)
        }

        let artifact = try decodeStructuredPayload(ResearchAnalysisArtifact.self, from: task.outputText)
        return .completed(snapshot, try normalizedResearchAnalysisArtifact(artifact, task: task))
    }

    func runResearchAnalysisFallback(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String],
        plan: ResearchPlanArtifact,
        inspection: ResearchInspectionArtifact,
        revisionRequest: ResearchVerificationArtifact? = nil
    ) async throws -> ResearchAnalysisArtifact {
        let noteTexts = notes.map(\.content)
        guard let fallback = try await stageFallback.bundledAnalysisInput(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            theme: theme
        ) else {
            throw ServiceError.taskFailed("No staged responses fallback is available for this analysis slice yet.")
        }

        let selectedDatasets = await trustedDatasets.taskDatasetSelection(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            limit: 4
        )
        let datasetCards = selectedDatasets.isEmpty
            ? "- No trusted dataset cards were resolved for this run."
            : selectedDatasets.map { $0.taskLine() }.joined(separator: "\n")
        let datasetGuidance = datasetExecutionGuidance(for: selectedDatasets, stage: .analyze)
        let notesBody = notes.map { note in
            "- [\(note.id.uuidString)] \(note.content)"
        }.joined(separator: "\n\n")

        let instructions = """
        You are a research scientist using Code Interpreter.
        A thin local orchestrator has already fetched a narrow trusted public cohort slice and checkpointed the inspection artifact.
        Analyze only the supplied cohort bundle. Do not widen the dataset, do not invent extra variables, do not make network requests, and do not write the paper yet.

        Return strict JSON only with this exact shape:
        {
          "dataset_manifest": {
            "primary_dataset_ids": ["trusted-dataset-id"],
            "data_sources": ["string"],
            "sample_description": "string",
            "row_count": 123,
            "selected_variables": ["string"],
            "quality_notes": ["string"]
          },
          "narrative_summary": "string",
          "findings": [
            {
              "claim": "string",
              "estimate": "string",
              "uncertainty": "string",
              "evidence": "string",
              "supports_hypothesis": true
            }
          ],
          "tables": [
            {
              "identifier": "table_1",
              "title": "string",
              "columns": ["string"],
              "rows": [["string"]],
              "notes": "string"
            }
          ],
          "figures": [
            {
              "filename": "figure_1.png",
              "caption": "string",
              "mime_type": "image/png",
              "base64_data": "base64 png bytes"
            }
          ],
          "limitations": ["string"],
          "provenance": {
            "used_dataset_ids": ["trusted-dataset-id"],
            "accessed_domains": ["domain"],
            "left_trusted_set": false,
            "external_sources": ["optional domain or source name"],
            "notes": "short summary of data access and limits"
          }
        }

        Requirements:
        - Use Code Interpreter to decode and analyze only the supplied bundle and generate any figure bytes included in the final JSON.
        - Do not contact GDC, cBioPortal, or any other external service. The supplied bundle is authoritative for this analysis pass.
        - Prefer one concrete public cohort analysis over speculative multi-source synthesis.
        - Treat MGMT measurements exactly as represented in the bundle; do not relabel continuous methylation values as binary promoter status unless the data justify it.
        - If survival time and event fields are present, generate a real Kaplan-Meier survival figure as `figure_1.png` with the corresponding risk table rendered beneath each requested panel when the cohort supports it; do not substitute a bar chart or median-only graphic.
        - Keep each figure compact and optimized for transport on the first try: roughly 420-600 px wide, indexed or otherwise compressed PNG, and concise captions so the final JSON stays small enough to transmit the full image bytes.
        - The caption for `figure_1.png` must explicitly name the plotted stratifications and state whether the saved figure includes the risk table, so downstream verification can confirm the requirement from the checkpointed artifact.
        - Do not emit placeholder, solid-color, or empty image files. Keep working until you have a real plot or explain precisely why the supplied bundle cannot support one.
        - Also write each generated figure PNG into the task workspace using the same filename and leave it in place so the final task diff or snapshot contains the real binary asset.
        - If survival time, event, and the requested covariates are available with enough complete cases, fit the requested multivariable Cox model and report hazard ratios with confidence intervals.
        - If age and sex fields are present, report their distributions and include at least one age- or sex-aware survival comparison or subgroup summary.
        - If multiple assay fields represent one biological variable, document the exact merge rule in `dataset_manifest.quality_notes` and any relevant table notes.
        - If the strongest trustworthy result is descriptive or limited to one or two subgroup comparisons, return that instead of stalling.
        - `findings[].evidence` must cite exact counts, field names, subgroup definitions, or figure/table identifiers from this run.
        - If verification guidance is supplied below, every required revision is mandatory unless the supplied bundle truly lacks the needed fields; in that case explain the blocker precisely in `limitations` and `quality_notes`.
        - Report sex distributions or state explicitly why the supplied fields cannot support them.
        - The final assistant message must contain only the JSON object and nothing before or after it.
        """

        let input = """
        Suggested title: \(title)
        Theme: \(theme)

        Trusted dataset cards:
        \(datasetCards)

        Dataset-specific execution guardrails:
        \(datasetGuidance)

        Notes:
        \(notesBody)

        Research plan JSON:
        \(prettyJSONString(plan))

        Research inspection JSON:
        \(stringify(inspectionPromptPayload(from: inspection)))
        \(revisionRequest.map { """

        Verification revision JSON:
        \(stringify(verificationPromptPayload(from: $0)))
        """ } ?? "")

        Resolved public cohort bundle (\(fallback.providerLabel)) JSON:
        \(fallback.promptJSON)
        """

        let response = try await createResearchStageFallbackResponse(
            instructions: instructions,
            input: input
        )

        let artifact = try decodeStructuredPayload(ResearchAnalysisArtifact.self, from: response.outputText)
        return try normalizedResearchAnalysisArtifact(artifact)
    }

    func startBundledResearchAnalysisTask(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String],
        plan: ResearchPlanArtifact,
        inspection: ResearchInspectionArtifact,
        revisionRequest: ResearchVerificationArtifact? = nil
    ) async throws -> String {
        let noteTexts = notes.map(\.content)
        guard let fallback = try await stageFallback.bundledAnalysisInput(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            theme: theme
        ) else {
            throw ServiceError.taskFailed("No staged remote fallback is available for this analysis slice yet.")
        }

        let compactHypotheses = plan.hypotheses.prefix(2).joined(separator: " | ")
        let compactChecklist = inspection.analysisChecklist.prefix(4).joined(separator: " | ")

        let prompt = """
        You are a research scientist working inside a Codex task with Python available.
        A thin local coordinator already fetched a narrow trusted public cohort bundle and checkpointed the inspection artifact. Analyze only that supplied bundle.
        Treat network access as unavailable for this task even if the environment technically exposes it.

        Requirements:
        1. Do not rely on repository files or repository context; the repo is irrelevant to this task.
        2. Do not make network requests, browse for external data, or hit live APIs. Do not contact GDC, cBioPortal, or any other external domain.
        3. Do not widen the cohort, switch studies, or browse for replacement data unless the supplied bundle is malformed.
        4. Use Python or equivalent computation inside the task to decode the supplied base64+zlib CSV payload and analyze that cohort only.
        5. Return strict JSON only with this exact shape:
           {
             "dataset_manifest": {
               "primary_dataset_ids": ["trusted-dataset-id"],
               "data_sources": ["string"],
               "sample_description": "string",
               "row_count": 123,
               "selected_variables": ["string"],
               "quality_notes": ["string"]
             },
             "narrative_summary": "string",
             "findings": [
               {
                 "claim": "string",
                 "estimate": "string",
                 "uncertainty": "string",
                 "evidence": "string",
                 "supports_hypothesis": true
               }
             ],
             "tables": [
               {
                 "identifier": "table_1",
                 "title": "string",
                 "columns": ["string"],
                 "rows": [["string"]],
                 "notes": "string"
               }
             ],
             "figures": [
               {
                 "filename": "figure_1.png",
                 "caption": "string",
                 "mime_type": "image/png",
                 "base64_data": "base64 png bytes"
               }
             ],
             "limitations": ["string"],
             "provenance": {
               "used_dataset_ids": ["trusted-dataset-id"],
               "accessed_domains": ["domain"],
               "left_trusted_set": false,
               "external_sources": ["optional domain or source name"],
               "notes": "short summary of data access and limits"
             }
           }
        6. Treat MGMT measurements exactly as represented in the supplied bundle. Do not relabel continuous methylation values as a binary promoter status unless the data justify it.
        7. If survival time and event fields are present, generate a real Kaplan-Meier survival figure as `figure_1.png` with the corresponding risk table rendered beneath each requested panel when the cohort supports it; do not substitute a bar chart or median-only graphic.
        8. Keep each figure compact and optimized for transport on the first try: roughly 420-600 px wide, indexed or otherwise compressed PNG, and concise captions so the final JSON stays small enough to transmit the full image bytes.
        9. The caption for `figure_1.png` must explicitly name the plotted stratifications and state whether the saved figure includes the risk table, so downstream verification can confirm the requirement from the checkpointed artifact.
        10. Do not emit placeholder, solid-color, or empty image files. Keep working until you have a real plot or explain precisely why the supplied bundle cannot support one.
        11. Also write each generated figure PNG into the task workspace using the same filename and leave it in place so the final task diff or snapshot contains the real binary asset.
        12. If survival time, event, and the requested covariates are available with enough complete cases, fit the requested multivariable Cox model and report hazard ratios with confidence intervals.
        13. If age and sex fields are present, report their distributions and include at least one age- or sex-aware survival comparison or subgroup summary.
        14. If multiple assay fields represent one biological variable, document the exact merge rule in `dataset_manifest.quality_notes` and any relevant table notes.
        15. If the strongest trustworthy analysis is descriptive or limited to one or two subgroup comparisons, return that instead of stalling.
        16. If verification guidance is supplied below, every required revision is mandatory unless the supplied bundle truly lacks the needed fields; in that case explain the blocker precisely in `limitations` and `quality_notes`.
        17. Report sex distributions or explicitly explain why the supplied fields cannot support them.
        18. If a desired claim cannot be supported from the supplied bundle, say so in `limitations` or `quality_notes` instead of trying to fetch replacement data.
        19. Set `provenance.accessed_domains` to an empty list unless you actually accessed an external domain, which you must not do in this task.
        20. Set `provenance.external_sources` to an empty list unless you truly used one, which you must not do in this task.
        21. The final assistant message must contain only the JSON object and nothing before or after it.

        Suggested title: \(title)
        Theme: \(theme)
        Study question: \(plan.question)
        Key hypotheses: \(compactHypotheses)
        Inspection checklist: \(compactChecklist)
        \(revisionRequest.map { """

        Verification revision JSON:
        \(stringify(verificationPromptPayload(from: $0)))
        """ } ?? "")

        Resolved public cohort bundle (\(fallback.providerLabel)):
        \(fallback.promptJSON)
        """

        log("startBundledResearchAnalysisTask prompt chars=\(prompt.count)")
        return try await createTask(prompt: prompt, preference: .selfContainedBundle)
    }

    func verifyResearchAnalysis(
        notes: [Note],
        title: String,
        theme: String,
        plan: ResearchPlanArtifact,
        inspection: ResearchInspectionArtifact,
        analysis: ResearchAnalysisArtifact
    ) async throws -> ResearchVerificationArtifact {
        let noteSummaries = notes.map { note in
            [
                "id": note.id.uuidString,
                "content": note.content
            ]
        }

        let instructions = """
        You are verifying whether a scientific paper can be drafted from checkpointed empirical artifacts.
        Use only the supplied notes, plan, inspection artifact, and analysis artifact. Do not invent new results or new data access.

        Return strict JSON only with this exact shape:
        {
          "decision": "proceed or revise_analysis or blocked",
          "summary": "string",
          "supported_claims": ["string"],
          "weak_or_unsupported_claims": ["string"],
          "figure_sanity_checks": [
            {
              "filename": "figure_1.png",
              "status": "ok or warning or missing",
              "issue": "string"
            }
          ],
          "model_warnings": ["string"],
          "sample_warnings": ["string"],
          "required_revisions": ["string"]
        }

        Requirements:
        - Set `decision` to `proceed` only when the analysis artifact is sufficient for a concise honest paper.
        - Set `decision` to `revise_analysis` when the question is still viable but the analysis is missing key sample sizes, uncertainty, figure integrity, cohort definition, or claim support.
        - Set `decision` to `blocked` when the inspected dataset slice does not support the intended paper.
        - If any figure entry below has `asset_status` other than `ok`, treat that as missing figure integrity and require `revise_analysis` unless the paper can honestly proceed without that figure.
        - When the requested Kaplan-Meier output requires a risk table, do not approve `proceed` unless the saved figure caption or supporting evidence explicitly confirms that the risk table is included.
        - Put any claim that must not appear in Results into `weak_or_unsupported_claims`.
        - Use `required_revisions` for concrete stage-local corrections only.
        - Keep the verification terse, specific, and scientifically conservative.
        """

        let input = """
        Suggested title: \(title)
        Theme: \(theme)

        Notes:
        \(stringify(noteSummaries))

        Research plan JSON:
        \(prettyJSONString(plan))

        Research inspection JSON:
        \(stringify(inspectionPromptPayload(from: inspection)))

        Research analysis JSON:
        \(stringify(analysisPromptPayload(from: analysis)))
        """

        let response = try await createResponse(
            for: .paperGeneration,
            tools: [],
            instructions: instructions,
            input: input
        )

        return try decodeStructuredPayload(ResearchVerificationArtifact.self, from: response.outputText)
    }

    func writeResearchPaper(
        notes: [Note],
        title: String,
        theme: String,
        plan: ResearchPlanArtifact,
        analysis: ResearchAnalysisArtifact,
        verification: ResearchVerificationArtifact
    ) async throws -> ResearchDraftArtifact {
        let noteSummaries = notes.map { note in
            [
                "id": note.id.uuidString,
                "content": note.content
            ]
        }

        let instructions = """
        You are writing a concise professional paper from verified research artifacts.
        Use the supplied plan, analysis, and verification only. Do not invent new results.

        Return strict JSON only with this exact shape:
        {
          "title": "string",
          "markdown": "clean academic markdown only, with references to bare figure_1.png style filenames"
        }

        Requirements:
        - Write a compact empirical paper, not a planning memo.
        - Prefer standard sections such as Abstract, Introduction, Data, Methods, Results, Discussion, and References when they fit.
        - When referencing figures, use bare filenames like `figure_1.png`.
        - Only state empirical results that are supported by `supported_claims`.
        - Treat `weak_or_unsupported_claims`, `model_warnings`, and `sample_warnings` as limitations, caveats, or omissions rather than results.
        - Do not include tool traces, logs, reproducibility checklists, repo paths, or app-meta commentary.
        """

        let input = """
        Suggested title: \(title)
        Theme: \(theme)

        Notes:
        \(stringify(noteSummaries))

        Research plan JSON:
        \(prettyJSONString(plan))

        Analysis JSON:
        \(stringify(analysisPromptPayload(from: analysis)))

        Verification JSON:
        \(stringify(verificationPromptPayload(from: verification)))
        """

        let response = try await createResponse(
            for: .paperGeneration,
            tools: [],
            instructions: instructions,
            input: input
        )

        return try decodeStructuredPayload(ResearchDraftArtifact.self, from: response.outputText)
    }

    func submitPaperTask(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String]
    ) async throws -> PaperTaskSubmission {
        let notesBody = notes.map { note in
            "- [\(note.id.uuidString)] \(note.content)"
        }.joined(separator: "\n\n")
        let selectedDatasets = await trustedDatasets.taskDatasetSelection(
            datasetIDs: datasetIDs,
            noteTexts: notes.map(\.content),
            limit: 4
        )
        let datasetCards = selectedDatasets.isEmpty
            ? "- No trusted dataset cards were resolved for this task."
            : selectedDatasets.map { $0.taskLine() }.joined(separator: "\n")
        let allowedDomains = TrustedDatasetRegistry.allowedDomains(for: selectedDatasets)
        let registryVersion = await trustedDatasets.registryVersion()
        let allowedDomainText = allowedDomains.isEmpty ? "none" : allowedDomains.joined(separator: ", ")

        if let localArtifacts = try await LocalPaperGenerationService.generateIfSupported(
            title: title,
            theme: theme,
            noteTexts: notes.map(\.content),
            selectedDatasets: selectedDatasets,
            session: session
        ) {
            return PaperTaskSubmission(
                taskID: "local-\(UUID().uuidString)",
                selectedDatasetIDs: selectedDatasets.map(\.id),
                allowedDomains: allowedDomains,
                registryVersion: registryVersion,
                precomputedArtifacts: localArtifacts
            )
        }

        let systemInstructions = """
        You are a research scientist using Code Interpreter.
        Create a real research paper from the notes below.

        Requirements:
        1. Prefer the vetted dataset cards below before using anything else.
        2. Keep internet usage inside the approved domains unless those sources are blocked or insufficient.
        3. Prefer focused API queries and small subsets over bulk downloads.
        4. If a vetted dataset is reachable, run the real analysis now. Do not stop at a methods memo, access report, or future-work outline when usable data are available.
        5. Report concrete estimates, sample sizes, uncertainty, and model outputs when you have them. Do not fabricate results.
        6. Generate publication-quality charts as PNG files when they add value, and include them in the final JSON as base64 PNG payloads.
        7. Cite every source actually used in the paper.
        8. Return strict JSON only in your final message:
           {
             "title": "string",
             "markdown": "clean academic markdown only, with references to bare figure_1.png style filenames",
             "figures": [
               {
                 "filename": "figure_1.png",
                 "caption": "string",
                 "mime_type": "image/png",
                 "base64_data": "base64 png bytes"
               }
             ],
             "provenance": {
               "used_dataset_ids": ["trusted-dataset-id"],
               "accessed_domains": ["domain"],
               "left_trusted_set": false,
               "external_sources": ["optional domain or source name"],
               "notes": "short summary of data access and limits"
             }
           }
        9. The markdown must read like a serious paper suitable for an arXiv-style PDF, not a planning memo. Prefer standard sections such as Abstract, Introduction, Data, Methods, Results, Discussion, and References when they fit.
        10. When you reference figures in markdown, use bare filenames like `figure_1.png` only. Do not use repo paths such as `research/figures/figure_1.png`.
        11. If you generate figure files during the run, you must also include the same PNG bytes in `figures[].base64_data`. Do not rely on repo snapshots or diffs as the only transport for figures.
        12. Do not include repo citations, line markers, path citations, tool traces, execution logs, reproducibility checklists, PR notes, or literal escape sequences.
        13. Avoid “draft”, “future work”, and “next steps” language unless blocked data access genuinely prevents the core analysis.
        14. If the approved sources are blocked, pivot to the strongest reachable public data source and complete the best empirical analysis you can. Record that decision in provenance instead of stopping at an access report.
        15. If analysis is still partial after trying reasonable alternatives, state the limitations clearly while maximizing the amount of real evidence, tables, and figures.
        16. The final assistant message must contain only the JSON object and nothing before or after it.
        """

        let userInput = """
        Suggested title: \(title)
        Theme: \(theme)
        Approved domains: \(allowedDomainText)

        Vetted dataset cards:
        \(datasetCards)

        Notes:
        \(notesBody)
        """

        let prompt = """
        \(systemInstructions)

        User request:
        \(userInput)
        """

        log("submitPaperTask creating remote task. title=\(title)")
        let taskID = try await createTask(prompt: prompt)
        return PaperTaskSubmission(
            taskID: taskID,
            selectedDatasetIDs: selectedDatasets.map(\.id),
            allowedDomains: allowedDomains,
            registryVersion: registryVersion,
            precomputedArtifacts: nil
        )
    }

    func generateLocalPaperIfSupported(
        title: String,
        theme: String,
        noteTexts: [String],
        datasetIDs: [String]
    ) async throws -> PaperArtifacts? {
        let selectedDatasets = await trustedDatasets.taskDatasetSelection(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            limit: 4
        )

        return try await LocalPaperGenerationService.generateIfSupported(
            title: title,
            theme: theme,
            noteTexts: noteTexts,
            selectedDatasets: selectedDatasets,
            session: session
        )
    }

    func checkTask(_ taskID: String) async throws -> PaperTaskCheckResult {
        log("checkTask polling. task_id=\(taskID)")
        let task = try await fetchTask(taskID: taskID)
        let snapshot = task.progressSnapshot(taskID: taskID)
        let latestEventText = snapshot.latestEventText ?? "<none>"
        let latestEventAge = snapshot.latestEventAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        log(
            "checkTask status=\(task.normalizedStatus) output_chars=\(task.outputText.count) " +
            "latest_event_age_s=\(latestEventAge) latest_event=\"\(latestEventText)\""
        )
        persistDebugPayload(Data(task.outputText.utf8), named: "task-output-\(taskID).txt")

        switch task.normalizedStatus {
        case "queued", "in_progress", "incomplete":
            return .waiting(snapshot)
        case "completed":
            break
        case "failed", "cancelled":
            return .failed(snapshot, task.errorMessage ?? "The paper task failed.")
        default:
            return .waiting(snapshot)
        }

        guard let data = normalizedJSONData(from: task.outputText) else {
            let payload = try decodePaperResponse(from: task.outputText)
            let markdown = normalizedPaperMarkdown(payload.markdown)
            let figures = recoveredFigureData(from: task, payloadFigures: payload.figures, markdown: markdown)
            return .completed(
                snapshot,
                PaperArtifacts(
                    title: payload.title,
                    markdown: markdown,
                    figures: figures,
                    provenance: payload.provenance
                )
            )
        }

        let payload: PaperResponse
        do {
            payload = try JSONDecoder().decode(PaperResponse.self, from: data)
        } catch {
            payload = try decodePaperResponse(from: task.outputText)
        }

        let markdown = normalizedPaperMarkdown(payload.markdown)
        let figures = recoveredFigureData(from: task, payloadFigures: payload.figures, markdown: markdown)

        return .completed(
            snapshot,
            PaperArtifacts(
                title: payload.title,
                markdown: markdown,
                figures: figures,
                provenance: payload.provenance
            )
        )
    }

    private func decodePaperResponse(from raw: String) throws -> PaperResponse {
        if let data = normalizedJSONData(from: raw),
           let payload = try? JSONDecoder().decode(PaperResponse.self, from: data) {
            return payload
        }

        let pattern = #"""
        (?s)"title"\s*:\s*"((?:\\.|[^"\\])*)"\s*,\s*"markdown"\s*:\s*"(.*)"\s*(?:,\s*"provenance"\s*:\s*(\{.*\}))?\s*\}\s*$
        """#

        guard let match = firstRegexMatch(pattern: pattern, in: raw),
              let title = captureGroup(1, from: match, in: raw).flatMap(decodeJSONStringFragment),
              let encodedMarkdown = captureGroup(2, from: match, in: raw) else {
            throw ServiceError.malformedPayload
        }

        let markdown = decodeJSONStringFragment(encodedMarkdown) ?? encodedMarkdown

        let provenance: TaskOutputProvenance? = captureGroup(3, from: match, in: raw).flatMap { json in
            guard let data = json.data(using: .utf8) else {
                return nil
            }

            return try? JSONDecoder().decode(TaskOutputProvenance.self, from: data)
        }

        return PaperResponse(
            title: title,
            markdown: markdown.trimmingCharacters(in: .whitespacesAndNewlines),
            figures: nil,
            provenance: provenance
        )
    }

    private func decodedFigureData(from figures: [PaperResponseFigure]?) -> [Data] {
        guard let figures else {
            return []
        }

        return figures.compactMap { figure in
            guard let data = decodeSidekickBase64Payload(figure.base64Data),
                  let normalized = normalizedSidekickRenderableImageData(data) else {
                return nil
            }

            return normalized
        }
    }

    private func recoveredFigureData(
        from task: CloudTaskDetails,
        payloadFigures: [PaperResponseFigure]?,
        markdown: String
    ) -> [Data] {
        let decoded = decodedFigureData(from: payloadFigures)
        guard decoded.isEmpty else {
            return decoded
        }

        return GitBinaryPatchFigureExtractor.extractFigureData(
            from: task.outputDiffText,
            referencedBy: markdown
        )
    }

    private func normalizedResearchAnalysisArtifact(
        _ artifact: ResearchAnalysisArtifact,
        task: CloudTaskDetails? = nil
    ) throws -> ResearchAnalysisArtifact {
        guard !artifact.figures.isEmpty else {
            return artifact
        }

        let repairedFigures = repairedAnalysisFigures(from: artifact, task: task)
        guard repairedFigures.count == artifact.figures.count else {
            let reason: String
            if let task, outputContainsTruncationMarker(task.outputText) {
                reason = "The analysis task output was truncated before all figure bytes arrived."
            } else {
                reason = "The analysis task returned figure metadata without a usable figure asset."
            }

            throw ServiceError.taskFailed(reason)
        }

        return ResearchAnalysisArtifact(
            datasetManifest: artifact.datasetManifest,
            narrativeSummary: artifact.narrativeSummary,
            findings: artifact.findings,
            tables: artifact.tables,
            figures: repairedFigures,
            limitations: artifact.limitations,
            provenance: artifact.provenance
        )
    }

    private func repairedAnalysisFigures(
        from artifact: ResearchAnalysisArtifact,
        task: CloudTaskDetails?
    ) -> [ResearchFigureArtifact] {
        let recoveredDiffFigures: [Data]
        if let task {
            let referencedFigures = artifact.figures
                .map { "![\($0.caption)](\($0.filename))" }
                .joined(separator: "\n")
            recoveredDiffFigures = GitBinaryPatchFigureExtractor.extractFigureData(
                from: task.outputDiffText,
                referencedBy: referencedFigures
            )
        } else {
            recoveredDiffFigures = []
        }

        return artifact.figures.enumerated().compactMap { index, figure in
            let fallbackData = recoveredDiffFigures.indices.contains(index)
                ? recoveredDiffFigures[index]
                : nil
            return normalizedResearchFigure(figure, fallbackData: fallbackData)
        }
    }

    private func outputContainsTruncationMarker(_ text: String) -> Bool {
        text.range(
            of: #"(?:\d+\s+)?(?:chars|tokens)\s+truncated"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func createResponse(
        for workload: OpenAIWorkload,
        tools: [[String: Any]],
        toolChoice: String = "auto",
        responseBaseURL: URL? = nil,
        instructions: String,
        input: String
    ) async throws -> ResponseEnvelope {
        let candidates = await modelRouter.candidates(for: workload)
        var unsupportedMessages: [String] = []

        for model in candidates {
            log("createResponse starting. workload=\(workload.description) model=\(model) tool_count=\(tools.count)")
            let body: [String: Any] = [
                "model": model,
                "instructions": instructions,
                "store": false,
                "stream": true,
                "tools": tools,
                "tool_choice": toolChoice,
                "parallel_tool_calls": false,
                "include": [],
                "input": [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "input_text",
                                "text": input
                            ]
                        ]
                    ]
                ]
            ]

            do {
                let response = try await sendJSONRequest(
                    baseURL: responseBaseURL ?? codexBaseURL,
                    pathComponents: ["responses"],
                    method: "POST",
                    body: body,
                    responseMode: .completed
                )
                log("createResponse succeeded. workload=\(workload.description) model=\(model) status=\(response.status)")
                await modelRouter.remember(model: model, for: workload)
                return response
            } catch {
                log("createResponse failed. workload=\(workload.description) model=\(model) error=\(String(describing: error))")
                guard let retryMessage = retryableModelSelectionMessage(from: error) else {
                    throw error
                }

                unsupportedMessages.append("\(model): \(retryMessage)")
            }
        }

        let details = unsupportedMessages.joined(separator: " | ")
        throw ServiceError.taskFailed(
            "OpenAI did not accept any recommended \(workload.description) model. Tried \(candidates.joined(separator: ", ")). \(details)"
        )
    }

    private func createResearchStageFallbackResponse(
        instructions: String,
        input: String
    ) async throws -> ResponseEnvelope {
        if let unavailableReason = await researchStageFallbackRouter.cachedUnavailabilityReason() {
            log(
                "createResearchStageFallbackResponse skipping direct responses fallback " +
                    "due to cached unavailability: \(unavailableReason)"
            )
            throw ServiceError.taskFailed(unavailableReason)
        }

        do {
            let response = try await createResponse(
                for: .researchStageFallback,
                tools: codeInterpreterTools(),
                toolChoice: "required",
                responseBaseURL: apiBaseURL,
                instructions: instructions,
                input: input
            )
            await researchStageFallbackRouter.clear()
            return response
        } catch {
            guard shouldRetryResearchStageFallbackResponse(after: error) else {
                throw error
            }

            log(
                "createResearchStageFallbackResponse retrying via ChatGPT backend /codex/responses " +
                    "after api failure: \(String(describing: error))"
            )

            do {
                let response = try await createResponse(
                    for: .researchStageFallback,
                    tools: codeInterpreterTools(),
                    toolChoice: "required",
                    responseBaseURL: codexBaseURL,
                    instructions: instructions,
                    input: input
                )
                await researchStageFallbackRouter.clear()
                return response
            } catch {
                if shouldRetryResearchStageFallbackResponse(after: error) {
                    await researchStageFallbackRouter.remember(error.localizedDescription)
                }
                throw error
            }
        }
    }

    private func createTask(
        prompt: String,
        preference: CloudTaskEnvironmentPreference = .repositoryBound
    ) async throws -> String {
        let environments = try await candidateEnvironments(for: preference)
        let branch = resolvedTaskBranch()
        var lastError: Error?
        var skippedLabels: [String] = []

        for environment in environments {
            log("createTask using environment id=\(environment.id) label=\(environment.label ?? "<none>") branch=\(branch)")
            let body: [String: Any] = [
                "new_task": [
                    "environment_id": environment.id,
                    "branch": branch,
                    "run_environment_in_qa_mode": false
                ],
                "input_items": [
                    [
                        "type": "message",
                        "role": "user",
                        "content": [
                            [
                                "content_type": "text",
                                "text": prompt
                            ]
                        ]
                    ]
                ]
            ]

            do {
                let data = try await sendBackendRequest(
                    pathComponents: ["wham", "tasks"],
                    method: "POST",
                    body: body
                )
                persistDebugPayload(data, named: "create-task-response.json")
                log("createTask response bytes=\(data.count)")

                let taskID = try decodeTaskID(from: data)
                await environmentRouter.remember(environment, for: preference)
                return taskID
            } catch let error as BackendRequestFailure
                where error.detailType == "repo_not_accessible" {
                    let label = environment.label ?? environment.id
                    skippedLabels.append(label)
                    lastError = error
                    await environmentRouter.quarantine(environment.id, for: preference)
                    log("createTask skipping environment \(label) due to repo_not_accessible")
                    continue
                } catch {
                    lastError = error
                    break
                }
        }

        if !skippedLabels.isEmpty {
            throw ServiceError.taskFailed(
                "No usable Codex cloud environment could accept the task. Skipped: \(skippedLabels.joined(separator: ", "))"
            )
        }

        throw lastError ?? ServiceError.missingTaskID
    }

    private func fetchTask(taskID: String) async throws -> CloudTaskDetails {
        let data = try await sendBackendRequest(
            pathComponents: ["wham", "tasks", taskID],
            method: "GET",
            body: nil
        )
        persistDebugPayload(data, named: "task-\(taskID).json")
        log("fetchTask response bytes=\(data.count) task_id=\(taskID)")

        return try JSONDecoder().decode(CloudTaskDetails.self, from: data)
    }

    private func fetchEnvironments() async throws -> [CloudTaskEnvironment] {
        let data = try await sendBackendRequest(
            pathComponents: ["wham", "environments"],
            method: "GET",
            body: nil
        )
        persistDebugPayload(data, named: "environments.json")

        let environments = try JSONDecoder().decode([CloudTaskEnvironment].self, from: data)
        log("selectEnvironment fetched environments count=\(environments.count)")
        guard !environments.isEmpty else {
            throw ServiceError.taskFailed("No Codex cloud environments are available for this ChatGPT workspace.")
        }

        return environments
    }

    private func candidateEnvironments(
        for preference: CloudTaskEnvironmentPreference
    ) async throws -> [CloudTaskEnvironment] {
        let environments = try await fetchEnvironments()
        let quarantinedIDs = await environmentRouter.quarantinedIDs(for: preference)
        let viableEnvironments =
            quarantinedIDs.isEmpty
            ? environments
            : environments.filter { !quarantinedIDs.contains($0.id) }
        let environmentPool = viableEnvironments.isEmpty ? environments : viableEnvironments
        let candidates: [CloudTaskEnvironment]

        switch preference {
        case .repositoryBound:
            let networkEnabled = environmentPool.filter { $0.agentNetworkAccess?.mode?.lowercased() != "off" }
            var prioritized = (networkEnabled.isEmpty ? environmentPool : networkEnabled)
                .sorted { environmentPriority($0, for: preference) > environmentPriority($1, for: preference) }

            if let remembered = await environmentRouter.cached(for: preference),
               let index = prioritized.firstIndex(where: { $0.id == remembered.id }) {
                let cached = prioritized.remove(at: index)
                prioritized.insert(cached, at: 0)
            }

            candidates = prioritized

        case .selfContainedBundle:
            var prioritized = environmentPool
                .sorted { environmentPriority($0, for: preference) > environmentPriority($1, for: preference) }

            if let remembered = await environmentRouter.cached(for: preference),
               let index = prioritized.firstIndex(where: { $0.id == remembered.id }) {
                let cached = prioritized.remove(at: index)
                prioritized.insert(cached, at: 0)
            }

            candidates = prioritized
        }

        return candidates
    }

    private func decodeTaskID(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("createTask failed to decode top-level task response JSON")
            throw ServiceError.invalidResponse
        }

        if let task = object["task"] as? [String: Any],
           let id = task["id"] as? String,
           !id.isEmpty {
            return id
        }

        if let id = object["id"] as? String, !id.isEmpty {
            return id
        }

        throw ServiceError.missingTaskID
    }

    private func resolvedTaskBranch() -> String {
        if let override = ProcessInfo.processInfo.environment["SIDEKICK_CODEX_BRANCH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }

        return "main"
    }

    private func environmentPriority(
        _ environment: CloudTaskEnvironment,
        for preference: CloudTaskEnvironmentPreference
    ) -> Int {
        var score = 0

        if environment.isPinned == true {
            score += 10_000
        }

        let mode = environment.agentNetworkAccess?.mode?.lowercased()
        let preset = environment.agentNetworkAccess?.presetAllowlist?.lowercased()
        let label = environment.label ?? ""

        if preference == .repositoryBound {
            if mode == "on" {
                score += 1_000
            }
            if preset == "all" {
                score += 100
            } else if preset == "codex" {
                score += 10
            }
        } else {
            if environment.hasPythonRuntime {
                score += 5_000
            } else {
                score -= 5_000
            }

            if mode == "off" {
                score += 6_000
            } else if mode == "on" {
                score += 500
            }

            if preset == "all" {
                score += 150
            } else if preset == "codex" {
                score += 75
            }

            if label.contains("/") {
                score -= 100
            } else {
                score += 25
            }
        }

        // Prefer less-loaded environments when the coarse capabilities are otherwise similar.
        score -= environment.taskCount ?? 0

        return score
    }

    private func sendJSONRequest(
        baseURL: URL,
        pathComponents: [String],
        method: String,
        body: [String: Any]?,
        responseMode: ResponseStreamMode = .completed
    ) async throws -> ResponseEnvelope {
        let token = try await auth.validToken()
        var request = URLRequest(url: endpoint(baseURL: baseURL, path: pathComponents))
        request.httpMethod = method
        applyAuthHeaders(to: &request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        log("sendJSONRequest \(method) \(request.url?.absoluteString ?? "<nil>")")

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        if method == "POST", body != nil {
            return try await sendStreamingRequest(request: request, responseMode: responseMode)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = responseErrorMessage(from: data)
            throw ServiceError.taskFailed(message)
        }

        return try JSONDecoder().decode(ResponseEnvelope.self, from: data)
    }

    private func sendBackendRequest(
        pathComponents: [String],
        method: String,
        body: [String: Any]?
    ) async throws -> Data {
        let token = try await auth.validToken()
        var request = URLRequest(url: endpoint(baseURL: backendBaseURL, path: pathComponents))
        request.httpMethod = method
        applyAuthHeaders(to: &request, token: token)
        log("sendBackendRequest \(method) \(request.url?.absoluteString ?? "<nil>")")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            persistDebugPayload(
                data,
                named: "backend-error-\(httpResponse.statusCode)-\(pathComponents.joined(separator: "_")).json"
            )
            throw backendRequestFailure(statusCode: httpResponse.statusCode, data: data)
        }

        return data
    }

    private func sendStreamingRequest(
        request: URLRequest,
        responseMode: ResponseStreamMode
    ) async throws -> ResponseEnvelope {
        var request = request
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        log("sendStreamingRequest opening stream \(request.url?.absoluteString ?? "<nil>")")

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let data = try await collectData(from: bytes)
            let message = responseErrorMessage(from: data)
            throw ServiceError.taskFailed(message)
        }

        var eventDataLines: [String] = []
        var createdResponse: ResponseEnvelope?
        var outputItems: [ResponseOutputItem] = []
        var outputTextDeltas: [String] = []

        for try await line in bytes.lines {
            if line.isEmpty {
                if let response = try processStreamedEvent(
                    dataLines: eventDataLines,
                    responseMode: responseMode,
                    createdResponse: &createdResponse,
                    outputItems: &outputItems,
                    outputTextDeltas: &outputTextDeltas
                ) {
                    return response
                }
                eventDataLines.removeAll(keepingCapacity: true)
                continue
            }

            if line.hasPrefix(":") {
                continue
            }

            guard line.hasPrefix("data:") else {
                continue
            }

            let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            eventDataLines.append(value)
        }

        if let response = try processStreamedEvent(
            dataLines: eventDataLines,
            responseMode: responseMode,
            createdResponse: &createdResponse,
            outputItems: &outputItems,
            outputTextDeltas: &outputTextDeltas
        ) {
            return response
        }

        if responseMode == .created,
           let createdResponse,
           let id = createdResponse.id,
           !id.isEmpty {
            return ResponseEnvelope(
                id: id,
                status: createdResponse.status.isEmpty ? "in_progress" : createdResponse.status,
                output: nil,
                error: createdResponse.error
            )
        }

        throw ServiceError.taskFailed("OpenAI stream closed before the response completed.")
    }

    private func processStreamedEvent(
        dataLines: [String],
        responseMode: ResponseStreamMode,
        createdResponse: inout ResponseEnvelope?,
        outputItems: inout [ResponseOutputItem],
        outputTextDeltas: inout [String]
    ) throws -> ResponseEnvelope? {
        guard !dataLines.isEmpty else {
            return nil
        }

        let payload = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != "[DONE]" else {
            return nil
        }

        let events = try decodeStreamedEvents(from: dataLines, joinedPayload: payload)

        for event in events {
            if event.type == "response.output_text.delta" {
                log("stream event=response.output_text.delta chars=\(event.delta?.count ?? 0)")
            } else {
                log("stream event=\(event.type)")
            }

            switch event.type {
            case "response.created":
                if let response = event.response {
                    createdResponse = response

                    if responseMode == .created,
                       let id = response.id,
                       !id.isEmpty {
                        return ResponseEnvelope(
                            id: id,
                            status: response.status.isEmpty ? "in_progress" : response.status,
                            output: nil,
                            error: response.error
                        )
                    }
                }
            case "response.output_item.done":
                if let item = event.item {
                    outputItems.append(item)
                }
            case "response.output_text.delta":
                if let delta = event.delta, !delta.isEmpty {
                    outputTextDeltas.append(delta)
                }
            case "response.completed":
                let response = event.response ?? createdResponse ?? ResponseEnvelope(
                    id: nil,
                    status: "completed",
                    output: nil,
                    error: nil
                )

                let finalOutput = response.output.flatMap { $0.isEmpty ? nil : $0 }
                    ?? accumulatedOutput(from: outputItems, outputTextDeltas: outputTextDeltas)

                return ResponseEnvelope(
                    id: response.id ?? createdResponse?.id,
                    status: response.status.isEmpty ? "completed" : response.status,
                    output: finalOutput,
                    error: response.error ?? createdResponse?.error
                )
            case "response.failed", "error":
                let message = event.response?.error?.message
                    ?? event.error?.message
                    ?? "OpenAI request failed."
                throw ServiceError.taskFailed(message)
            case "response.incomplete":
                throw ServiceError.taskFailed("OpenAI response was incomplete.")
            default:
                break
            }
        }

        return nil
    }

    private func decodeStreamedEvents(
        from dataLines: [String],
        joinedPayload: String
    ) throws -> [StreamedResponseEvent] {
        do {
            return [try decodeSingleStreamedEvent(from: joinedPayload)]
        } catch {
            guard dataLines.count > 1 else {
                throw error
            }

            log("processStreamedEvent retrying batched SSE payload line-by-line. line_count=\(dataLines.count)")

            var events: [StreamedResponseEvent] = []
            events.reserveCapacity(dataLines.count)

            for line in dataLines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != "[DONE]" else {
                    continue
                }

                events.append(try decodeSingleStreamedEvent(from: trimmed))
            }

            return events
        }
    }

    private func decodeSingleStreamedEvent(from payload: String) throws -> StreamedResponseEvent {
        let data = Data(payload.utf8)

        do {
            return try JSONDecoder().decode(StreamedResponseEvent.self, from: data)
        } catch {
            log("processStreamedEvent failed to decode SSE event: \(String(describing: error))")
            log("processStreamedEvent payload preview: \(preview(payload, limit: 500))")
            throw error
        }
    }

    private func accumulatedOutput(
        from items: [ResponseOutputItem],
        outputTextDeltas: [String]
    ) -> [ResponseOutputItem]? {
        if !items.isEmpty {
            return items
        }

        let text = outputTextDeltas.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            return nil
        }

        return [.assistantMessage(text: text)]
    }

    private func collectData(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private func applyAuthHeaders(to request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(originator, forHTTPHeaderField: "originator")

        if let accountID = extractChatGPTAccountID(from: token) {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
    }

    private func extractChatGPTAccountID(from token: String) -> String? {
        guard let payload = decodedJWTPayload(from: token),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String,
              !accountID.isEmpty else {
            return nil
        }

        return accountID
    }

    private func decodedJWTPayload(from token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else {
            return nil
        }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        while payload.count % 4 != 0 {
            payload.append("=")
        }

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return object
    }

    private func log(_ message: String) {
        print("[OpenAI] \(message)")
    }

    private func backendRequestFailure(statusCode: Int, data: Data) -> BackendRequestFailure {
        if let payload = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data),
           let detail = payload.detail {
            let message = detail.message ?? responseErrorMessage(from: data)
            return BackendRequestFailure(
                statusCode: statusCode,
                detailType: detail.type,
                message: message,
                rawBody: String(data: data, encoding: .utf8) ?? ""
            )
        }

        return BackendRequestFailure(
            statusCode: statusCode,
            detailType: nil,
            message: responseErrorMessage(from: data),
            rawBody: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private func preview(_ value: String, limit: Int) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        guard flattened.count > limit else {
            return flattened
        }

        return "\(flattened.prefix(limit))..."
    }

    private func stringify(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return string
    }

    private func prettyJSONString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }

    private func codeInterpreterTools() -> [[String: Any]] {
        [
            [
                "type": "code_interpreter",
                "container": [
                    "type": "auto"
                ]
            ]
        ]
    }

    private func decodeStructuredPayload<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        guard let data = normalizedJSONData(from: raw) else {
            throw ServiceError.malformedPayload
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            log("decodeStructuredPayload failed for \(String(describing: type)): \(String(describing: error))")
            log("decodeStructuredPayload preview: \(preview(String(data: data, encoding: .utf8) ?? "<non-utf8>", limit: 400))")
            throw error
        }
    }

    private func localPlanArtifact(
        title: String,
        theme: String,
        selectedDatasets: [TrustedDataset]
    ) -> ResearchPlanArtifact {
        let datasetNeeds = selectedDatasets.map { dataset in
            ResearchDatasetNeed(
                datasetID: dataset.id,
                role: "primary",
                variables: ["Diabetes_012", "HighBP", "BMI", "PhysActivity", "GenHlth"],
                rationale: "The BRFSS validation slice uses this trusted dataset for diabetes prevalence summaries and logistic regression."
            )
        }

        return ResearchPlanArtifact(
            question: theme.isEmpty ? title : theme,
            hypotheses: [
                "The note cluster can be evaluated with a BRFSS-based empirical wedge.",
                "Cardiometabolic and self-reported health measures should explain meaningful variation in diagnosed diabetes."
            ],
            datasetNeeds: datasetNeeds,
            candidateMethods: [
                "Cross-sectional prevalence summaries.",
                "Logistic regression for diagnosed diabetes using hypertension, BMI, physical activity, and general health."
            ],
            plannedFigures: [
                ResearchFigurePlan(
                    identifier: "figure_1",
                    title: "Diabetes prevalence by BMI category",
                    purpose: "Show the cross-sectional relationship between BMI strata and diagnosed diabetes."
                ),
                ResearchFigurePlan(
                    identifier: "figure_2",
                    title: "Adjusted odds ratios from logistic regression",
                    purpose: "Summarize the multivariable regression estimates."
                )
            ],
            risks: [
                "The local BRFSS slice is a validation wedge, not the intended general-purpose architecture."
            ],
            executionNotes: "Used the trusted BRFSS slice to preserve the working empirical loop while staged remote runs are introduced."
        )
    }

    private func localInspectionArtifact(
        selectedDatasets: [TrustedDataset],
        artifacts: PaperArtifacts
    ) -> ResearchInspectionArtifact {
        let analysis = localAnalysisArtifact(selectedDatasets: selectedDatasets, artifacts: artifacts)

        return ResearchInspectionArtifact(
            datasetManifest: analysis.datasetManifest,
            accessNotes: artifacts.provenance?.notes ?? "The trusted BRFSS mirror was resolved locally and inspected before the validation analysis.",
            qualityChecks: [
                "The local validation wedge resolved one trusted public-health dataset and a compact predictor set.",
                "This manifest is synthesized from the local BRFSS path so the staged pipeline keeps a consistent checkpoint shape."
            ],
            analysisChecklist: [
                "Quantify sample size and prevalence across the selected outcome and predictor strata.",
                "Fit the planned regression model and carry the finished figures into the final paper bundle."
            ]
        )
    }

    private func localAnalysisArtifact(
        selectedDatasets: [TrustedDataset],
        artifacts: PaperArtifacts
    ) -> ResearchAnalysisArtifact {
        let figures = artifacts.figures.enumerated().map { index, figureData in
            ResearchFigureArtifact(
                filename: "figure_\(index + 1).png",
                caption: "Local BRFSS validation figure \(index + 1)",
                mimeType: "image/png",
                base64Data: figureData.base64EncodedString()
            )
        }

        return ResearchAnalysisArtifact(
            datasetManifest: ResearchDatasetManifest(
                primaryDatasetIDs: selectedDatasets.map(\.id),
                dataSources: selectedDatasets.map(\.title),
                sampleDescription: artifacts.provenance?.notes ?? "Local BRFSS validation slice executed successfully.",
                rowCount: nil,
                selectedVariables: ["Diabetes_012", "HighBP", "BMI", "PhysActivity", "GenHlth"],
                qualityNotes: [
                    "The local BRFSS wedge stores the finished figures and paper artifact first; typed coefficient tables can be expanded later."
                ]
            ),
            narrativeSummary: "A trusted BRFSS dataset was analyzed locally to preserve the working empirical slice while the staged remote architecture is introduced.",
            findings: [
                ResearchFinding(
                    claim: "The BRFSS validation wedge completed successfully.",
                    estimate: "See the finalized paper body for computed estimates.",
                    uncertainty: "The finished paper reports the uncertainty directly.",
                    evidence: "The local fallback generated a ready paper and figures from trusted data.",
                    supportsHypothesis: nil
                )
            ],
            tables: [],
            figures: figures,
            limitations: [
                "The local fallback remains BRFSS-specific and should not become the primary architecture.",
                "This first staged version persists the finished local artifact bundle before exposing richer typed local tables."
            ],
            provenance: artifacts.provenance ?? TaskOutputProvenance(
                usedDatasetIDs: selectedDatasets.map(\.id),
                accessedDomains: TrustedDatasetRegistry.allowedDomains(for: selectedDatasets),
                leftTrustedSet: false,
                externalSources: [],
                notes: "Local BRFSS validation slice."
            )
        )
    }

    private func localVerificationArtifact(
        selectedDatasets: [TrustedDataset],
        artifacts: PaperArtifacts
    ) -> ResearchVerificationArtifact {
        let figureChecks = artifacts.figures.enumerated().map { index, _ in
            ResearchFigureSanityCheck(
                filename: "figure_\(index + 1).png",
                status: "ok",
                issue: "The local BRFSS validation path produced this figure successfully."
            )
        }

        return ResearchVerificationArtifact(
            decision: .proceed,
            summary: "The BRFSS validation wedge produced a coherent dataset manifest, completed analysis artifact, and reusable figures, so drafting can proceed.",
            supportedClaims: [
                "The BRFSS validation wedge completed an empirical analysis using a trusted public dataset.",
                "The finalized paper may report prevalence and regression outputs that are already grounded in the stored BRFSS artifacts."
            ],
            weakOrUnsupportedClaims: [
                "This local validation path should not be generalized as the long-term architecture for non-BRFSS datasets."
            ],
            figureSanityChecks: figureChecks,
            modelWarnings: [
                "The local BRFSS wedge remains a validation slice and does not replace staged remote dataset execution."
            ],
            sampleWarnings: [],
            requiredRevisions: []
        )
    }

    private func inspectionPromptPayload(from inspection: ResearchInspectionArtifact) -> [String: Any] {
        [
            "dataset_manifest": [
                "primary_dataset_ids": inspection.datasetManifest.primaryDatasetIDs,
                "data_sources": inspection.datasetManifest.dataSources,
                "sample_description": inspection.datasetManifest.sampleDescription,
                "row_count": inspection.datasetManifest.rowCount.map { NSNumber(value: $0) } ?? NSNull(),
                "selected_variables": inspection.datasetManifest.selectedVariables,
                "quality_notes": inspection.datasetManifest.qualityNotes
            ],
            "access_notes": inspection.accessNotes,
            "quality_checks": inspection.qualityChecks,
            "analysis_checklist": inspection.analysisChecklist
        ]
    }

    private func analysisPromptPayload(from analysis: ResearchAnalysisArtifact) -> [String: Any] {
        [
            "dataset_manifest": [
                "primary_dataset_ids": analysis.datasetManifest.primaryDatasetIDs,
                "data_sources": analysis.datasetManifest.dataSources,
                "sample_description": analysis.datasetManifest.sampleDescription,
                "row_count": analysis.datasetManifest.rowCount.map { NSNumber(value: $0) } ?? NSNull(),
                "selected_variables": analysis.datasetManifest.selectedVariables,
                "quality_notes": analysis.datasetManifest.qualityNotes
            ],
            "narrative_summary": analysis.narrativeSummary,
            "findings": analysis.findings.map { finding in
                [
                    "claim": finding.claim,
                    "estimate": finding.estimate,
                    "uncertainty": finding.uncertainty,
                    "evidence": finding.evidence,
                    "supports_hypothesis": finding.supportsHypothesis.map { NSNumber(value: $0) } as Any? ?? NSNull()
                ]
            },
            "tables": analysis.tables.map { table in
                [
                    "identifier": table.identifier,
                    "title": table.title,
                    "columns": table.columns,
                    "rows": table.rows,
                    "notes": table.notes ?? NSNull()
                ]
            },
            "figures": analysis.figures.map { figure in
                let imageData = figure.imageData
                [
                    "filename": figure.filename,
                    "caption": figure.caption,
                    "asset_status": imageData == nil ? "missing_or_unusable" : "ok",
                    "image_bytes": imageData.map { NSNumber(value: $0.count) } ?? NSNull()
                ]
            },
            "limitations": analysis.limitations,
            "provenance": [
                "used_dataset_ids": analysis.provenance.usedDatasetIDs,
                "accessed_domains": analysis.provenance.accessedDomains,
                "left_trusted_set": analysis.provenance.leftTrustedSet,
                "external_sources": analysis.provenance.externalSources,
                "notes": analysis.provenance.notes
            ]
        ]
    }

    private func normalizedResearchFigure(
        _ figure: ResearchFigureArtifact,
        fallbackData: Data?
    ) -> ResearchFigureArtifact? {
        if let payloadData = decodeSidekickBase64Payload(figure.base64Data),
           let normalizedPayload = normalizedSidekickRenderableImageData(payloadData) {
            return ResearchFigureArtifact(
                filename: figure.filename,
                caption: figure.caption,
                mimeType: figure.mimeType,
                base64Data: normalizedPayload.base64EncodedString()
            )
        }

        if let fallbackData,
           let normalizedFallback = normalizedSidekickRenderableImageData(fallbackData) {
            return ResearchFigureArtifact(
                filename: figure.filename,
                caption: figure.caption,
                mimeType: figure.mimeType,
                base64Data: normalizedFallback.base64EncodedString()
            )
        }

        return nil
    }

    private func verificationPromptPayload(from verification: ResearchVerificationArtifact) -> [String: Any] {
        [
            "decision": verification.decision.rawValue,
            "summary": verification.summary,
            "supported_claims": verification.supportedClaims,
            "weak_or_unsupported_claims": verification.weakOrUnsupportedClaims,
            "figure_sanity_checks": verification.figureSanityChecks.map { check in
                [
                    "filename": check.filename,
                    "status": check.status,
                    "issue": check.issue
                ]
            },
            "model_warnings": verification.modelWarnings,
            "sample_warnings": verification.sampleWarnings,
            "required_revisions": verification.requiredRevisions
        ]
    }

    private func datasetExecutionGuidance(
        for selectedDatasets: [TrustedDataset],
        stage: DatasetExecutionStage
    ) -> String {
        var lines: [String] = []
        let datasetIDs = Set(selectedDatasets.map(\.id))

        if !datasetIDs.isDisjoint(with: ["nci-gdc-api", "cbioportal-public"]) {
            switch stage {
            case .inspect:
                lines.append("- For neuro-oncology or glioblastoma notes, prefer one public cohort only: TCGA-GBM in GDC or one public GBM study in cBioPortal.")
                lines.append("- Return the exact project ID or study ID you inspected, plus the clinical, mutation, expression, or survival fields that were actually reachable.")
                lines.append("- Avoid controlled-access files, raw sequencing workflows, and broad pan-cancer sweeps.")
            case .analyze:
                lines.append("- Keep the analysis inside the exact GDC project or cBioPortal study resolved during inspection.")
                lines.append("- Prefer trustworthy cohort-level survival summaries, mutation frequencies, and clinical subgroup comparisons with exact sample counts.")
                lines.append("- If inferential modeling is thin, fall back to descriptive cohort comparisons rather than broad mechanistic or pan-cancer claims.")
            }
        }

        if !datasetIDs.isDisjoint(with: ["dandi-api", "allen-brain-atlas-api", "neuromorpho-api", "cellxgene-discover"]) {
            switch stage {
            case .inspect:
                lines.append("- Choose one dandiset, atlas, morphology slice, or single-cell collection and return the exact collection identifier or atlas family you inspected.")
                lines.append("- Inspect only manageable metadata or study-level fields first; do not imply that large raw NWB matrices or image volumes were downloaded.")
            case .analyze:
                lines.append("- Keep neuroscience analyses at the study, cohort, cell-type, brain-region, or collection level unless the inspected slice clearly supports more.")
                lines.append("- Report concrete counts such as donors, cells, reconstructions, sessions, or assets before making functional claims.")
            }
        }

        if !datasetIDs.isDisjoint(with: ["mast-observations", "nasa-exoplanet-archive"]) {
            switch stage {
            case .inspect:
                lines.append("- Resolve one archive table, mission, target set, or observation slice and return its exact name in the manifest.")
                lines.append("- Keep the inspection to catalog metadata, observation summaries, or mission-linked tables rather than broad archive crawling.")
            case .analyze:
                lines.append("- Favor mission-scoped catalog summaries, transit/host-star comparisons, or observation-count analyses with explicit row counts.")
                lines.append("- Avoid implying custom raw-image or pixel-level reduction pipelines unless the inspected slice explicitly supported them.")
            }
        }

        if lines.isEmpty {
            return "- Stay narrow, name the exact public dataset slice, and prefer conservative empirical claims over broad speculative ones."
        }

        return lines.joined(separator: "\n")
    }

    private func normalizedJSONData(from raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let cleaned = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates = [
            trimmed,
            cleaned,
            extractFirstJSONObject(from: cleaned)
        ].compactMap { $0 }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else {
                continue
            }

            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                return data
            }
        }

        return nil
    }

    private func extractFirstJSONObject(from raw: String) -> String? {
        var startIndex: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaping = false

        for index in raw.indices {
            let character = raw[index]

            if isEscaping {
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                continue
            }

            if character == "\"" {
                isInsideString.toggle()
                continue
            }

            if isInsideString {
                continue
            }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
                continue
            }

            if character == "}" {
                guard depth > 0 else {
                    continue
                }

                depth -= 1
                if depth == 0, let startIndex {
                    return String(raw[startIndex ... index])
                }
            }
        }

        return nil
    }

    private func retryableModelSelectionMessage(from error: Error) -> String? {
        guard case let ServiceError.taskFailed(message) = error else {
            return nil
        }

        let normalized = message.lowercased()
        let retryableIndicators = [
            "model is not supported",
            "unsupported model",
            "unknown model",
            "unrecognized model",
            "does not exist",
            "not available",
            "invalid model",
            "tool is not supported",
            "tools are not supported"
        ]

        return retryableIndicators.contains(where: normalized.contains) ? message : nil
    }

    private func shouldRetryResearchStageFallbackResponse(after error: Error) -> Bool {
        guard case let ServiceError.taskFailed(message) = error else {
            return false
        }

        let normalized = message.lowercased()
        let indicators = [
            "unsupported tool type: code_interpreter",
            "missing scopes: api.responses.write",
            "insufficient permissions",
            "not found"
        ]

        return indicators.contains(where: normalized.contains)
    }

    private func responseErrorMessage(from data: Data) -> String {
        guard !data.isEmpty else {
            return "OpenAI request failed."
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? String, !detail.isEmpty {
                return detail
            }

            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }

            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.isEmpty {
                return message
            }
        }

        return String(data: data, encoding: .utf8) ?? "OpenAI request failed."
    }

    private func firstRegexMatch(pattern: String, in raw: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return regex.firstMatch(in: raw, options: [], range: range)
    }

    private func captureGroup(_ index: Int, from match: NSTextCheckingResult, in raw: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: raw) else {
            return nil
        }

        return String(raw[swiftRange])
    }

    private func decodeJSONStringFragment(_ fragment: String) -> String? {
        let wrapped = "\"\(fragment)\""
        guard let data = wrapped.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(String.self, from: data)
    }

    private func normalizedPaperMarkdown(_ markdown: String) -> String {
        PaperContentNormalizer.normalize(markdown: markdown)
    }

    private func replacingRegex(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private func persistDebugPayload(_ data: Data, named filename: String) {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let debugDirectory = baseURL.appendingPathComponent("DebugPayloads", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
            let destination = debugDirectory.appendingPathComponent(filename)
            try data.write(to: destination, options: .atomic)
        } catch {
            print("[OpenAI] Failed to persist debug payload \(filename): \(error.localizedDescription)")
        }
    }

    private var codexBaseURL: URL {
        backendBaseURL.appendingPathComponent("codex")
    }

    private func endpoint(baseURL: URL, path: [String]) -> URL {
        path.reduce(baseURL) { url, component in
            url.appendingPathComponent(component)
        }
    }
}

private enum DatasetExecutionStage {
    case inspect
    case analyze
}

private enum ResponseStreamMode {
    case created
    case completed
}

private enum OpenAIWorkload {
    case noteAssessment
    case paperGeneration
    case researchStageFallback

    nonisolated var description: String {
        switch self {
        case .noteAssessment:
            return "note assessment"
        case .paperGeneration:
            return "paper generation"
        case .researchStageFallback:
            return "research stage fallback"
        }
    }

    nonisolated var storageKey: String {
        switch self {
        case .noteAssessment:
            return "noteAssessment"
        case .paperGeneration:
            return "paperGeneration"
        case .researchStageFallback:
            return "researchStageFallback"
        }
    }

    nonisolated var preferredModels: [String] {
        switch self {
        case .noteAssessment:
            return [
                "gpt-5.4",
                "gpt-5.1",
                "gpt-5",
                "gpt-5-mini"
            ]
        case .paperGeneration:
            return [
                "gpt-5-codex",
                "gpt-5.3-codex",
                "gpt-5.2-codex",
                "gpt-5.1-codex-max",
                "gpt-5.1-codex",
                "gpt-5.4"
            ]
        case .researchStageFallback:
            return [
                "gpt-5.4",
                "gpt-5.1",
                "gpt-5",
                "gpt-5-mini"
            ]
        }
    }
}

private enum CloudTaskEnvironmentPreference {
    case repositoryBound
    case selfContainedBundle
}

private struct BackendRequestFailure: LocalizedError {
    let statusCode: Int
    let detailType: String?
    let message: String
    let rawBody: String

    var errorDescription: String? {
        "HTTP \(statusCode): \(message)"
    }
}

private struct BackendErrorEnvelope: Decodable {
    let detail: BackendErrorDetail?
}

private struct BackendErrorDetail: Decodable {
    let type: String?
    let message: String?
}

private actor OpenAIModelRouter {
    private var rememberedModels: [String: String] = [:]

    func candidates(for workload: OpenAIWorkload) -> [String] {
        if let remembered = rememberedModels[workload.storageKey] {
            return [remembered] + workload.preferredModels.filter { $0 != remembered }
        }

        return workload.preferredModels
    }

    func remember(model: String, for workload: OpenAIWorkload) {
        rememberedModels[workload.storageKey] = model
    }
}

private actor OpenAIEnvironmentRouter {
    private var repositoryBoundEnvironment: CloudTaskEnvironment?
    private var selfContainedBundleEnvironment: CloudTaskEnvironment?
    private var repositoryBoundQuarantine: [String: Date] = [:]
    private var selfContainedBundleQuarantine: [String: Date] = [:]

    func cached(for preference: CloudTaskEnvironmentPreference) -> CloudTaskEnvironment? {
        switch preference {
        case .repositoryBound:
            return repositoryBoundEnvironment
        case .selfContainedBundle:
            return selfContainedBundleEnvironment
        }
    }

    func remember(_ environment: CloudTaskEnvironment, for preference: CloudTaskEnvironmentPreference) {
        switch preference {
        case .repositoryBound:
            repositoryBoundEnvironment = environment
        case .selfContainedBundle:
            selfContainedBundleEnvironment = environment
        }
    }

    func quarantine(
        _ environmentID: String,
        for preference: CloudTaskEnvironmentPreference,
        duration: TimeInterval = 6 * 60 * 60
    ) {
        pruneExpiredQuarantines(now: .now)

        switch preference {
        case .repositoryBound:
            repositoryBoundQuarantine[environmentID] = Date().addingTimeInterval(duration)
            if repositoryBoundEnvironment?.id == environmentID {
                repositoryBoundEnvironment = nil
            }
        case .selfContainedBundle:
            selfContainedBundleQuarantine[environmentID] = Date().addingTimeInterval(duration)
            if selfContainedBundleEnvironment?.id == environmentID {
                selfContainedBundleEnvironment = nil
            }
        }
    }

    func quarantinedIDs(for preference: CloudTaskEnvironmentPreference) -> Set<String> {
        pruneExpiredQuarantines(now: .now)

        switch preference {
        case .repositoryBound:
            return Set(repositoryBoundQuarantine.keys)
        case .selfContainedBundle:
            return Set(selfContainedBundleQuarantine.keys)
        }
    }

    private func pruneExpiredQuarantines(now: Date) {
        repositoryBoundQuarantine = repositoryBoundQuarantine.filter { $0.value > now }
        selfContainedBundleQuarantine = selfContainedBundleQuarantine.filter { $0.value > now }
    }
}

private actor OpenAIResearchStageFallbackRouter {
    private var unavailableReason: String?

    func cachedUnavailabilityReason() -> String? {
        unavailableReason
    }

    func remember(_ reason: String) {
        unavailableReason = reason
    }

    func clear() {
        unavailableReason = nil
    }
}

private struct ClusterResponse: Decodable {
    struct Cluster: Decodable {
        let noteIDs: [String]
        let theme: String
        let suggestedTitle: String
        let isReady: Bool?
        let datasetIDs: [String]?
        let readinessMode: String?

        enum CodingKeys: String, CodingKey {
            case noteIDs
            case theme
            case suggestedTitle
            case isReady = "is_ready"
            case datasetIDs = "dataset_ids"
            case readinessMode = "readiness_mode"
        }
    }

    let clusters: [Cluster]
}

private struct PaperResponse: Decodable {
    let title: String
    let markdown: String
    let figures: [PaperResponseFigure]?
    let provenance: TaskOutputProvenance?
}

private struct PaperResponseFigure: Decodable {
    let filename: String
    let caption: String?
    let mimeType: String?
    let base64Data: String

    enum CodingKeys: String, CodingKey {
        case filename
        case caption
        case mimeType = "mime_type"
        case base64Data = "base64_data"
    }
}

private struct CloudTaskEnvironment: Decodable {
    let id: String
    let label: String?
    let isPinned: Bool?
    let taskCount: Int?
    let agentNetworkAccess: CloudTaskAgentNetworkAccess?
    let envVars: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case isPinned = "is_pinned"
        case taskCount = "task_count"
        case agentNetworkAccess = "agent_network_access"
        case envVars = "env_vars"
    }

    var hasPythonRuntime: Bool {
        envVars?["CODEX_ENV_PYTHON_VERSION"] != nil
    }
}

private struct CloudTaskAgentNetworkAccess: Decodable {
    let mode: String?
    let presetAllowlist: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case presetAllowlist = "preset_allowlist"
    }
}

private struct CloudTaskDetails: Decodable {
    let task: CloudTaskMetadata?
    let taskStatusDisplay: CloudTaskStatusDisplay?
    let currentUserTurn: CloudTaskTurn?
    let currentAssistantTurn: CloudTaskTurn?
    let currentDiffTaskTurn: CloudTaskTurn?

    enum CodingKeys: String, CodingKey {
        case task
        case taskStatusDisplay = "task_status_display"
        case currentUserTurn = "current_user_turn"
        case currentAssistantTurn = "current_assistant_turn"
        case currentDiffTaskTurn = "current_diff_task_turn"
    }

    var normalizedStatus: String {
        let latestTaskStatus = taskStatusDisplay?.latestTurnStatusDisplay?.turnStatus
        let taskMetadataStatus = task?.taskStatusDisplay?.latestTurnStatusDisplay?.turnStatus
        let assistantTurnStatus = currentAssistantTurn?.turnStatus
        let diffTurnStatus = currentDiffTaskTurn?.turnStatus
        let taskState = taskStatusDisplay?.state
        let taskMetadataState = task?.taskStatusDisplay?.state

        let rawStatus = latestTaskStatus
            ?? taskMetadataStatus
            ?? assistantTurnStatus
            ?? diffTurnStatus
            ?? taskState
            ?? taskMetadataState
            ?? "pending"

        switch rawStatus {
        case "ready", "applied":
            return "completed"
        case "error":
            return "failed"
        default:
            return rawStatus
        }
    }

    var outputText: String {
        prioritizedMessageText(from: currentAssistantTurn)
            ?? prioritizedMessageText(from: currentDiffTaskTurn)
            ?? ""
    }

    var outputDiffText: String {
        prioritizedDiffText(from: currentAssistantTurn)
            ?? prioritizedDiffText(from: currentDiffTaskTurn)
            ?? ""
    }

    var errorMessage: String? {
        currentAssistantTurn?.error?.summary
            ?? currentDiffTaskTurn?.error?.summary
            ?? task?.lastErrorMessage
    }

    func progressSnapshot(taskID: String) -> PaperTaskProgressSnapshot {
        let assistantTurn = currentAssistantTurn ?? currentDiffTaskTurn

        return PaperTaskProgressSnapshot(
            taskID: taskID,
            status: normalizedStatus,
            observedAt: .now,
            taskCreatedAt: task?.createdAtDate,
            assistantTurnCreatedAt: assistantTurn?.createdAtDate,
            latestEventAt: assistantTurn?.latestEventCreatedAt,
            latestEventText: assistantTurn?.latestEvent?.text,
            outputCharacterCount: outputText.count,
            environmentID: assistantTurn?.environmentID,
            environmentLabel: assistantTurn?.environment?.label,
            environmentNetworkMode: assistantTurn?.environment?.agentNetworkAccess?.mode
        )
    }

    private func prioritizedMessageText(from turn: CloudTaskTurn?) -> String? {
        let text = turn?.messageTexts.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return text.isEmpty ? nil : text
    }

    private func prioritizedDiffText(from turn: CloudTaskTurn?) -> String? {
        let text = turn?.diffTexts.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return text.isEmpty ? nil : text
    }
}

private struct CloudTaskMetadata: Decodable {
    let id: String?
    let title: String?
    let createdAt: Double?
    let taskStatusDisplay: CloudTaskStatusDisplay?
    let error: CloudTaskTurnError?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt = "created_at"
        case taskStatusDisplay = "task_status_display"
        case error
    }

    var lastErrorMessage: String? {
        error?.summary
    }

    var createdAtDate: Date? {
        createdAt.map(Date.init(timeIntervalSince1970:))
    }
}

private struct CloudTaskStatusDisplay: Decodable {
    let state: String?
    let latestTurnStatusDisplay: CloudTaskLatestTurnStatusDisplay?

    enum CodingKeys: String, CodingKey {
        case state
        case latestTurnStatusDisplay = "latest_turn_status_display"
    }
}

private struct CloudTaskLatestTurnStatusDisplay: Decodable {
    let turnStatus: String?

    enum CodingKeys: String, CodingKey {
        case turnStatus = "turn_status"
    }
}

private struct CloudTaskTurn: Decodable {
    let id: String?
    let attemptPlacement: Int?
    let turnStatus: String?
    let siblingTurnIDs: [String]?
    let outputItems: [CloudTaskOutputItem]?
    let latestEvent: CloudTaskLatestEvent?
    let worklog: CloudTaskWorklog?
    let error: CloudTaskTurnError?
    let createdAt: Double?
    let environmentID: String?
    let environment: CloudTaskExecutionEnvironment?

    enum CodingKeys: String, CodingKey {
        case id
        case attemptPlacement = "attempt_placement"
        case turnStatus = "turn_status"
        case siblingTurnIDs = "sibling_turn_ids"
        case outputItems = "output_items"
        case latestEvent = "latest_event"
        case worklog
        case error
        case createdAt = "created_at"
        case environmentID = "environment_id"
        case environment
    }

    var createdAtDate: Date? {
        createdAt.map(Date.init(timeIntervalSince1970:))
    }

    var latestEventCreatedAt: Date? {
        latestEvent?.created.map(Date.init(timeIntervalSince1970:))
    }

    var messageTexts: [String] {
        var texts = (outputItems ?? []).flatMap(\.textValues)

        let worklogTexts = (worklog?.messages ?? [])
            .filter(\.isAssistant)
            .flatMap(\.textValues)

        texts.append(contentsOf: worklogTexts)
        return texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var diffTexts: [String] {
        (outputItems ?? []).compactMap(\.diffText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private struct CloudTaskLatestEvent: Decodable {
    let created: Double?
    let text: String?
    let eventType: String?

    enum CodingKeys: String, CodingKey {
        case created
        case text
        case eventType = "event_type"
    }
}

private struct CloudTaskExecutionEnvironment: Decodable {
    let label: String?
    let agentNetworkAccess: CloudTaskAgentNetworkAccess?

    enum CodingKeys: String, CodingKey {
        case label
        case agentNetworkAccess = "agent_network_access"
    }
}

private struct CloudTaskOutputItem: Decodable {
    let type: String?
    let content: [CloudTaskContentFragment]?
    let outputDiff: CloudTaskOutputDiff?

    enum CodingKeys: String, CodingKey {
        case type
        case content
        case outputDiff = "output_diff"
    }

    var textValues: [String] {
        guard type == "message" else {
            return []
        }

        return (content ?? []).compactMap(\.text)
    }

    var diffText: String? {
        outputDiff?.diff
    }
}

private struct CloudTaskOutputDiff: Decodable {
    let diff: String?
}

private enum CloudTaskContentFragment: Decodable {
    case structured(CloudTaskStructuredContent)
    case text(String)

    init(from decoder: Decoder) throws {
        if let structured = try? CloudTaskStructuredContent(from: decoder) {
            self = .structured(structured)
            return
        }

        let container = try decoder.singleValueContainer()
        self = .text(try container.decode(String.self))
    }

    var text: String? {
        switch self {
        case let .structured(content):
            guard content.contentType?.lowercased() == "text" else {
                return nil
            }
            return content.text
        case let .text(text):
            return text
        }
    }
}

private struct CloudTaskStructuredContent: Decodable {
    let contentType: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case contentType = "content_type"
        case text
    }
}

private struct CloudTaskWorklog: Decodable {
    let messages: [CloudTaskWorklogMessage]?
}

private struct CloudTaskWorklogMessage: Decodable {
    let author: CloudTaskAuthor?
    let content: CloudTaskWorklogContent?

    var isAssistant: Bool {
        author?.role?.lowercased() == "assistant"
    }

    var textValues: [String] {
        (content?.parts ?? []).compactMap(\.text)
    }
}

private struct CloudTaskAuthor: Decodable {
    let role: String?
}

private struct CloudTaskWorklogContent: Decodable {
    let parts: [CloudTaskContentFragment]?
}

private struct CloudTaskTurnError: Decodable {
    let code: String?
    let message: String?

    var summary: String? {
        let code = code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch (code.isEmpty, message.isEmpty) {
        case (true, true):
            return nil
        case (false, true):
            return code
        case (true, false):
            return message
        case (false, false):
            return "\(code): \(message)"
        }
    }
}

private struct ResponseEnvelope: Decodable {
    let id: String?
    let status: String
    let output: [ResponseOutputItem]?
    let error: ResponseAPIError?

    init(id: String?, status: String, output: [ResponseOutputItem]?, error: ResponseAPIError?) {
        self.id = id
        self.status = status
        self.output = output
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case output
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        output = try container.decodeIfPresent([ResponseOutputItem].self, forKey: .output)
        error = try container.decodeIfPresent(ResponseAPIError.self, forKey: .error)
    }

    var outputText: String {
        output?.compactMap(\.flattenedText).joined(separator: "\n\n") ?? ""
    }

    var files: [ResponseFile] {
        var discovered: [ResponseFile] = []
        output?.forEach { item in
            discovered.append(contentsOf: item.discoveredFiles)
        }
        return Array(Set(discovered))
    }
}

private struct ResponseOutputItem: Decodable {
    let type: String?
    let content: [ResponseContent]?
    let summary: [ResponseContent]?
    let filename: String?
    let fileID: String?

    init(
        type: String?,
        content: [ResponseContent]?,
        summary: [ResponseContent]?,
        filename: String?,
        fileID: String?
    ) {
        self.type = type
        self.content = content
        self.summary = summary
        self.filename = filename
        self.fileID = fileID
    }

    enum CodingKeys: String, CodingKey {
        case type
        case content
        case summary
        case filename
        case fileID = "file_id"
    }

    var flattenedText: String? {
        let direct = [content, summary]
            .compactMap { $0 }
            .flatMap { $0 }
            .compactMap(\.text)

        if !direct.isEmpty {
            return direct.joined(separator: "\n")
        }

        return nil
    }

    var discoveredFiles: [ResponseFile] {
        var files: [ResponseFile] = []

        if let filename, let fileID {
            files.append(ResponseFile(fileID: fileID, filename: filename))
        }

        [content, summary]
            .compactMap { $0 }
            .flatMap { $0 }
            .forEach { files.append(contentsOf: $0.discoveredFiles) }

        return files
    }

    static func assistantMessage(text: String) -> ResponseOutputItem {
        ResponseOutputItem(
            type: "message",
            content: [.outputText(text)],
            summary: nil,
            filename: nil,
            fileID: nil
        )
    }
}

private struct ResponseContent: Decodable {
    let type: String?
    let text: String?
    let annotations: [ResponseAnnotation]?
    let filename: String?
    let fileID: String?

    init(
        type: String?,
        text: String?,
        annotations: [ResponseAnnotation]?,
        filename: String?,
        fileID: String?
    ) {
        self.type = type
        self.text = text
        self.annotations = annotations
        self.filename = filename
        self.fileID = fileID
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case annotations
        case filename
        case fileID = "file_id"
    }

    var discoveredFiles: [ResponseFile] {
        var files: [ResponseFile] = []

        if let filename, let fileID {
            files.append(ResponseFile(fileID: fileID, filename: filename))
        }

        annotations?.forEach { annotation in
            if let filename = annotation.filename, let fileID = annotation.fileID {
                files.append(ResponseFile(fileID: fileID, filename: filename))
            }
        }

        return files
    }

    static func outputText(_ text: String) -> ResponseContent {
        ResponseContent(
            type: "output_text",
            text: text,
            annotations: nil,
            filename: nil,
            fileID: nil
        )
    }
}

private struct ResponseAnnotation: Decodable {
    let type: String?
    let text: String?
    let filename: String?
    let fileID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case filename
        case fileID = "file_id"
    }
}

private struct ResponseFile: Hashable {
    let fileID: String
    let filename: String
}

private struct StreamedResponseEvent: Decodable {
    let type: String
    let response: ResponseEnvelope?
    let item: ResponseOutputItem?
    let delta: String?
    let error: ResponseAPIError?

    enum CodingKeys: String, CodingKey {
        case type
        case response
        case item
        case delta
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        response = try? container.decodeIfPresent(ResponseEnvelope.self, forKey: .response)
        item = try? container.decodeIfPresent(ResponseOutputItem.self, forKey: .item)
        delta = try? container.decodeIfPresent(String.self, forKey: .delta)
        error = try? container.decodeIfPresent(ResponseAPIError.self, forKey: .error)
    }
}

private struct ResponseAPIError: Decodable {
    let code: String?
    let message: String?
}

private enum GitBinaryPatchFigureExtractor {
    private struct RecoveredFigure {
        let filename: String
        let data: Data
    }

    private static let base85Alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~".utf8)
    private static let base85DecodeTable: [UInt8: UInt32] = {
        Dictionary(uniqueKeysWithValues: base85Alphabet.enumerated().map { (UInt8($0.element), UInt32($0.offset)) })
    }()

    static func extractFigureData(from diff: String, referencedBy markdown: String) -> [Data] {
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let normalizedDiff = diff
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let referencedFiles = referencedFigureFilenames(in: markdown)
        var recovered: [RecoveredFigure] = []
        let lines = normalizedDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("diff --git ") else {
                index += 1
                continue
            }

            let targetPath = diffTargetPath(from: line)
            index += 1

            var sectionLines: [String] = []
            while index < lines.count, !lines[index].hasPrefix("diff --git ") {
                sectionLines.append(lines[index])
                index += 1
            }

            guard let targetPath, targetPath.lowercased().hasSuffix(".png") else {
                continue
            }

            let filename = URL(fileURLWithPath: targetPath).lastPathComponent
            let normalizedFilename = filename.lowercased()
            if !referencedFiles.isEmpty, !referencedFiles.contains(normalizedFilename) {
                continue
            }

            guard let data = literalImageData(from: sectionLines) else {
                continue
            }

            recovered.append(RecoveredFigure(filename: filename, data: data))
        }

        return recovered
            .sorted { lhs, rhs in
                let left = figureSortKey(for: lhs.filename)
                let right = figureSortKey(for: rhs.filename)

                switch (left, right) {
                case let (.some(leftNumber), .some(rightNumber)):
                    if leftNumber != rightNumber {
                        return leftNumber < rightNumber
                    }
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    break
                }

                return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
            }
            .map(\.data)
    }

    private static func diffTargetPath(from line: String) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else {
            return nil
        }

        let target = String(parts[3])
        guard target.hasPrefix("b/") else {
            return nil
        }

        return String(target.dropFirst(2))
    }

    private static func literalImageData(from lines: [String]) -> Data? {
        guard let patchMarker = lines.firstIndex(of: "GIT binary patch") else {
            return nil
        }

        let headerIndex = lines.index(after: patchMarker)
        guard headerIndex < lines.count else {
            return nil
        }

        let header = lines[headerIndex].split(separator: " ", omittingEmptySubsequences: true)
        guard header.count == 2,
              header[0] == "literal",
              let inflatedSize = Int(header[1]) else {
            return nil
        }

        var compressed = Data()
        var lineIndex = headerIndex + 1

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }

            guard let firstByte = line.utf8.first,
                  let byteLength = decodedLineByteLength(for: firstByte),
                  let chunk = decode85(String(line.dropFirst()), byteLength: byteLength) else {
                return nil
            }

            compressed.append(chunk)
            lineIndex += 1
        }

        return inflateZlib(data: compressed, expectedSize: inflatedSize)
    }

    private static func decodedLineByteLength(for firstByte: UInt8) -> Int? {
        switch firstByte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"):
            return Int(firstByte - UInt8(ascii: "A")) + 1
        case UInt8(ascii: "a") ... UInt8(ascii: "z"):
            return Int(firstByte - UInt8(ascii: "a")) + 27
        default:
            return nil
        }
    }

    private static func decode85(_ payload: String, byteLength: Int) -> Data? {
        let bytes = Array(payload.utf8)
        let expectedChunkCount = ((byteLength + 3) / 4) * 5
        guard bytes.count >= expectedChunkCount else {
            return nil
        }

        var decoded: [UInt8] = []
        decoded.reserveCapacity(byteLength)

        var remaining = byteLength
        var index = 0

        while remaining > 0 {
            guard index + 5 <= bytes.count else {
                return nil
            }

            var accumulator: UInt32 = 0
            for offset in 0 ..< 5 {
                guard let value = base85DecodeTable[bytes[index + offset]] else {
                    return nil
                }

                accumulator = (accumulator * 85) + value
            }

            let chunkCount = min(4, remaining)
            for _ in 0 ..< chunkCount {
                accumulator = (accumulator << 8) | (accumulator >> 24)
                decoded.append(UInt8(accumulator & 0xff))
            }

            remaining -= chunkCount
            index += 5
        }

        return Data(decoded)
    }

    private static func inflateZlib(data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else {
            return Data()
        }

        var stream = z_stream()
        var destination = Data(count: expectedSize)

        let status: Int32 = data.withUnsafeBytes { sourceBuffer in
            destination.withUnsafeMutableBytes { destinationBuffer in
                guard let sourceBase = sourceBuffer.bindMemory(to: Bytef.self).baseAddress,
                      let destinationBase = destinationBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_DATA_ERROR
                }

                stream.next_in = UnsafeMutablePointer(mutating: sourceBase)
                stream.avail_in = uInt(data.count)
                stream.next_out = destinationBase
                stream.avail_out = uInt(expectedSize)

                let initStatus = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                guard initStatus == Z_OK else {
                    return initStatus
                }

                defer {
                    inflateEnd(&stream)
                }

                return inflate(&stream, Z_FINISH)
            }
        }

        guard status == Z_STREAM_END, Int(stream.total_out) == expectedSize else {
            return nil
        }

        destination.count = Int(stream.total_out)
        return destination
    }

    private static func referencedFigureFilenames(in markdown: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\(([^)\n]+\.png)\)"#, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        let matches = regex.matches(in: markdown, options: [], range: range)

        return Set(matches.compactMap { match in
            guard match.numberOfRanges > 1,
                  let pathRange = Range(match.range(at: 1), in: markdown) else {
                return nil
            }

            let path = String(markdown[pathRange])
            return URL(fileURLWithPath: path).lastPathComponent.lowercased()
        })
    }

    private static func figureSortKey(for filename: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"figure_(\d+)\.png"#, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: filename) else {
            return nil
        }

        return Int(filename[valueRange])
    }
}
