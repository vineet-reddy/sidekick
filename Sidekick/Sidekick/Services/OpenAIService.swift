import Combine
import CryptoKit
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

struct OAuthExecutionSetupSnapshot: Equatable {
    enum Phase: String {
        case ready
        case connectGitHub
        case confirmRepositoryScope
        case waitingForMachine
        case autoProvisioning
        case waitingForEnvironment
        case manualFinish
    }

    let phase: Phase
    let message: String?
    let environmentLabel: String?
    let machineLabel: String?
    let workspaceRepositoryFullName: String?

    static let ready = OAuthExecutionSetupSnapshot(
        phase: .ready,
        message: nil,
        environmentLabel: nil,
        machineLabel: nil,
        workspaceRepositoryFullName: nil
    )

    var requiresGitHubConnection: Bool {
        phase == .connectGitHub
    }

    var requiresScopeAttestation: Bool {
        phase == .confirmRepositoryScope
    }

    var isReady: Bool {
        phase == .ready
    }
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

    @Published private(set) var hasUserAPIKeyOverride = false
    @Published private(set) var userAPIKeyHint: String?
    @Published private(set) var userAPIKeyErrorMessage: String?
    @Published private(set) var oauthExecutionSetupMessage: String?
    @Published private(set) var oauthExecutionRequiresGitHubConnection = false
    @Published private(set) var oauthExecutionSetup = OAuthExecutionSetupSnapshot.ready
    @Published private(set) var oauthExecutionSetupSheetRequestID = 0

    private let auth: AuthService
    private let github: GitHubService
    private let session: URLSession
    private let defaults: UserDefaults
    private let backendBaseURL = URL(string: "https://chatgpt.com/backend-api")!
    private let apiBaseURL = URL(string: "https://api.openai.com/v1")!
    private let originator = "codex_cli_rs"
    private let modelRouter = OpenAIModelRouter()
    private let environmentRouter = OpenAIEnvironmentRouter()
    private let researchStageFallbackRouter = OpenAIResearchStageFallbackRouter()
    private let trustedDatasets: TrustedDatasetRegistry
    private let stageFallback: ResearchStageFallbackService
    private let apiKeychain = KeychainStore(service: "com.vineet.sidekick.openai-api")
    private let apiKeyAccount = "user-api-key"
    private let qaAPIKeyEnvironmentVariable = "SIDEKICK_QA_OPENAI_API_KEY"
    private let qaForceNoSignalRemoteTasksEnvironmentVariable = "SIDEKICK_QA_FORCE_NO_SIGNAL_REMOTE_TASKS"
    private let qaForceNoSignalRemoteTaskAgeSecondsEnvironmentVariable = "SIDEKICK_QA_FORCE_NO_SIGNAL_TASK_AGE_SECONDS"
    private let qaProbeCodexEnvironmentEndpointsEnvironmentVariable = "SIDEKICK_QA_PROBE_CODEX_ENV_ENDPOINTS"
    private let qaForceOAuthSetupPhaseEnvironmentVariable = "SIDEKICK_QA_FORCE_OAUTH_SETUP_PHASE"
    private let qaForceOAuthSetupMessageEnvironmentVariable = "SIDEKICK_QA_FORCE_OAUTH_SETUP_MESSAGE"
    private let qaForceOAuthWorkspaceRepoEnvironmentVariable = "SIDEKICK_QA_FORCE_OAUTH_WORKSPACE_REPO"
    private let apiKeyFailureMessageDefaultsKey = "com.vineet.sidekick.openai-api.failure-message"
    private let apiKeyFailureFingerprintDefaultsKey = "com.vineet.sidekick.openai-api.failure-fingerprint"
    private let oauthSetupBootstrap = OAuthExecutionSetupBootstrapCoordinator()
    private let sidekickOfflineEnvironmentLabel = "Sidekick Offline"
    private let sidekickResearchEnvironmentLabel = "Sidekick Research"

    init(
        auth: AuthService,
        github: GitHubService,
        session: URLSession = .shared,
        trustedDatasets: TrustedDatasetRegistry? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.auth = auth
        self.github = github
        self.session = session
        self.defaults = defaults
        let registry = trustedDatasets ?? TrustedDatasetRegistry(session: session)
        self.trustedDatasets = registry
        stageFallback = ResearchStageFallbackService(session: session)
        refreshAPIKeyOverrideState()
        restorePersistedUserAPIKeyFailureIfNeeded()
        log(
            "API key override \(hasUserAPIKeyOverride ? "active" : "inactive"). " +
                "source=\(apiKeyOverrideSourceDescription())"
        )

        Task {
            await registry.refreshIfNeeded()
        }
    }

    func saveUserAPIKey(_ rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.isEmpty {
            try clearUserAPIKey()
            return
        }

        try apiKeychain.save(normalized, account: apiKeyAccount)
        clearUserAPIKeyFailure()
        refreshAPIKeyOverrideState()

        Task {
            await researchStageFallbackRouter.clear()
        }
    }

    func clearUserAPIKey() throws {
        try apiKeychain.delete(account: apiKeyAccount)
        clearUserAPIKeyFailure()
        refreshAPIKeyOverrideState()

        Task {
            await researchStageFallbackRouter.clear()
        }
    }

    var hasBlockingUserAPIKeyError: Bool {
        hasUserAPIKeyOverride && userAPIKeyErrorMessage != nil
    }

    func recordUserAPIKeyFailure(_ message: String) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasUserAPIKeyOverride, !normalized.isEmpty else {
            return
        }

        userAPIKeyErrorMessage = normalized
        persistUserAPIKeyFailureIfNeeded(normalized)
        log("API key override blocked. message=\(preview(normalized, limit: 220))")
    }

    func clearUserAPIKeyFailure() {
        userAPIKeyErrorMessage = nil
        defaults.removeObject(forKey: apiKeyFailureMessageDefaultsKey)
        defaults.removeObject(forKey: apiKeyFailureFingerprintDefaultsKey)
    }

    func refreshOAuthExecutionSetupStateIfNeeded() async -> String? {
        guard !hasUserAPIKeyOverride else {
            await oauthSetupBootstrap.reset()
            await publishOAuthExecutionSetupState(.ready)
            return nil
        }

        if let forcedSnapshot = qaForcedOAuthExecutionSetupSnapshot() {
            await oauthSetupBootstrap.reset()
            await publishOAuthExecutionSetupState(forcedSnapshot)
            return forcedSnapshot.message
        }

        do {
            _ = try await github.refreshBootstrapSessionIfNeeded()
        } catch {
            log("github bootstrap session refresh failed: \(error.localizedDescription)")
        }

        let workspaceContext = github.workspaceContext

        do {
            let environments = try await fetchEnvironments()
            await oauthSetupBootstrap.reset()
            let preferredEnvironment = preferredSetupEnvironment(from: environments)
            await publishOAuthExecutionSetupState(
                OAuthExecutionSetupSnapshot(
                    phase: .ready,
                    message: nil,
                    environmentLabel: preferredEnvironment?.label,
                    machineLabel: nil,
                    workspaceRepositoryFullName: workspaceContext?.repositoryFullName
                )
            )
            return nil
        } catch {
            let installationExists = await oauthExecutionGitHubInstallationExists()
            if installationExists {
                github.recordBootstrapErrorMessage(nil)
            }
            let repositoryScopeDiagnostics = await fetchConnectedGitHubRepositoriesDiagnostics(
                workspaceContext: workspaceContext
            )

            let snapshot: OAuthExecutionSetupSnapshot

            if !installationExists {
                await oauthSetupBootstrap.reset()
                snapshot = OAuthExecutionSetupSnapshot(
                    phase: .connectGitHub,
                    message: connectorBootstrapMessage(for: workspaceContext),
                    environmentLabel: nil,
                    machineLabel: nil,
                    workspaceRepositoryFullName: workspaceContext?.repositoryFullName
                )
            } else if let workspaceContext,
                      !github.hasRecentConnectorScopeAttestation(
                          for: workspaceContext,
                          chatgptEmail: auth.userEmail
                      ) {
                await oauthSetupBootstrap.reset()
                snapshot = OAuthExecutionSetupSnapshot(
                    phase: .confirmRepositoryScope,
                    message: connectorAttestationMessage(for: workspaceContext),
                    environmentLabel: nil,
                    machineLabel: nil,
                    workspaceRepositoryFullName: workspaceContext.repositoryFullName
                )
            } else if case let .mismatch(detail) = repositoryScopeDiagnostics {
                await oauthSetupBootstrap.reset()
                snapshot = OAuthExecutionSetupSnapshot(
                    phase: .confirmRepositoryScope,
                    message: detail,
                    environmentLabel: nil,
                    machineLabel: nil,
                    workspaceRepositoryFullName: workspaceContext?.repositoryFullName
                )
            } else {
                let message = oauthExecutionSetupBlockerMessage(
                    for: error,
                    requiresGitHubConnection: false
                ) ?? """
                GitHub is connected. Sidekick is finishing a repository-bound Codex environment for your secure workspace repo.
                """

                snapshot = await resolvePostGitHubOAuthExecutionSetupState(
                    fallbackMessage: message,
                    workspaceContext: workspaceContext
                )
            }

            await publishOAuthExecutionSetupState(snapshot)
            return snapshot.message
        }
    }

    @MainActor
    func requestOAuthExecutionSetupSheet() {
        guard oauthExecutionSetupMessage != nil else {
            return
        }

        oauthExecutionSetupSheetRequestID += 1
    }

    func oauthExecutionSetupBlockerMessage(for error: Error) -> String? {
        oauthExecutionSetupBlockerMessage(for: error, requiresGitHubConnection: false)
    }

    func oauthExecutionSetupBlockerMessage(
        for error: Error,
        requiresGitHubConnection: Bool
    ) -> String? {
        guard !hasUserAPIKeyOverride else {
            return nil
        }

        let normalized = error.localizedDescription.lowercased()
        let indicators = [
            "no codex cloud environments are available",
            "no usable codex cloud environment",
            "missing_github_connector_link",
            "github connection not found for user",
            "repo_not_accessible",
            "repository is not accessible"
        ]

        guard indicators.contains(where: normalized.contains) else {
            return nil
        }

        if requiresGitHubConnection {
            return connectorBootstrapMessage(for: github.workspaceContext)
        }

        return """
        GitHub is connected, but this ChatGPT workspace does not have a usable repository-bound Codex environment yet. Keep this screen open while Sidekick finishes the environment for your Sidekick workspace repo. If Codex still does not expose it, open ChatGPT Codex Environments or add your own OpenAI API key in Settings.
        """
    }

    private func connectorBootstrapMessage(for workspaceContext: GitHubWorkspaceContext?) -> String {
        if let workspaceContext {
            return """
            Sidekick already provisioned \(workspaceContext.repositoryFullName). Open GitHub from Sidekick, keep the ChatGPT Codex Connector on Only selected repositories, and leave \(workspaceContext.repositoryFullName) as the only selected repo.
            """
        }

        return """
        Sidekick needs to create your secure GitHub workspace repo first, then open the ChatGPT Codex Connector already scoped to that repo. Continue in GitHub from Sidekick and leave the connector on Only selected repositories.
        """
    }

    private func connectorAttestationMessage(for workspaceContext: GitHubWorkspaceContext) -> String {
        """
        Sidekick opened GitHub with only \(workspaceContext.repositoryFullName) preselected. Confirm that you left the ChatGPT Codex Connector on Only selected repositories and that \(workspaceContext.repositoryFullName) was the only selected repo.
        """
    }

    func runQACodexEnvironmentBootstrapProbeIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        let isEnabled =
            arguments.contains("--qa-probe-codex-env-endpoints")
            || environment[qaProbeCodexEnvironmentEndpointsEnvironmentVariable] == "1"

        guard isEnabled else {
            return
        }

        log("qa env bootstrap probe starting")

        let probes: [(String, [String], String, [String: Any]?)] = [
            ("list_environments", ["wham", "environments"], "GET", nil),
            ("options_environments", ["wham", "environments"], "OPTIONS", nil),
            ("list_machines", ["wham", "machines"], "GET", nil),
            ("list_repos", ["wham", "repos"], "GET", nil),
            ("list_repositories", ["wham", "repositories"], "GET", nil),
            ("list_github_repos", ["wham", "github", "repos"], "GET", nil),
            ("list_github_repositories", ["wham", "github", "repositories"], "GET", nil),
            ("list_github_installations", ["wham", "github", "installations"], "GET", nil),
            ("get_github_connect", ["wham", "github", "connect"], "GET", nil),
            ("post_github_connect", ["wham", "github", "connect"], "POST", [:]),
            ("get_github_link", ["wham", "github", "link"], "GET", nil),
            ("post_github_link", ["wham", "github", "link"], "POST", [:]),
            ("post_github_installations", ["wham", "github", "installations"], "POST", [:]),
            ("post_environments_empty", ["wham", "environments"], "POST", [:]),
            (
                "post_environments_minimal",
                ["wham", "environments"],
                "POST",
                [
                    "machine_id": "default",
                    "label": "Sidekick Offline",
                    "repos": []
                ]
            ),
            (
                "post_environments_new_environment",
                ["wham", "environments"],
                "POST",
                [
                        "new_environment": [
                        "label": "Sidekick Offline",
                        "branch": "main"
                    ]
                ]
            )
        ]

        var results: [[String: Any]] = []
        results.reserveCapacity(probes.count)

        for (name, path, method, body) in probes {
            do {
                let result = try await probeBackendRequest(
                    name: name,
                    pathComponents: path,
                    method: method,
                    body: body
                )
                results.append(
                    [
                        "name": name,
                        "path": path.joined(separator: "/"),
                        "method": method,
                        "status_code": result.statusCode,
                        "allow": result.allowHeader as Any,
                        "content_type": result.contentType as Any,
                        "body_preview": result.bodyPreview
                    ]
                )
                log("qa env probe \(name) status=\(result.statusCode) allow=\(result.allowHeader ?? "<none>")")
            } catch {
                results.append(
                    [
                        "name": name,
                        "path": path.joined(separator: "/"),
                        "method": method,
                        "error": error.localizedDescription
                    ]
                )
                log("qa env probe \(name) failed error=\(error.localizedDescription)")
            }
        }

        let payload: [String: Any] = [
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "results": results
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            persistDebugPayload(data, named: "codex-environment-bootstrap-probe.json")
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
            limit: 32
        )
        let datasetGuide = shortlistedDatasets.isEmpty
            ? "- No trusted dataset cards are currently loaded."
            : shortlistedDatasets.map { $0.assessmentLine() }.joined(separator: "\n")

        let systemInstructions = """
        You are a research assistant. Group these notes into thematic research clusters.
        Be eager with clustering, and lean toward bounded pilot-paper generation when a plausible reliable source-family fit exists.

        Important note behavior assumptions:
        - This product turns throwaway research notes into first-pass pilot papers.
        - The notes may be fragmented, typo-heavy, rushed, half-written, or internally inconsistent.
        - A single note may be too incomplete to stand alone but still become meaningful in combination with other notes.
        - Infer the latent scientific question from the combination of notes rather than requiring one polished note.
        - It is acceptable to infer a defensible middle layer: sharpen the question, choose a narrow first-pass comparison, and fill in ordinary methodological details that the note leaves implicit.
        - Do not require the note to already specify every cohort split, confounder, or endpoint before marking a cluster runnable.
        - Do not require the notes to name a repository, portal, or dataset explicitly before choosing a fitting trusted dataset card.
        - Treat `dataset_ids` as source-family hints for bounded discovery, not as a final execution commitment.
        - Each trusted dataset card includes a reliability tier: supported, experimental, or disabled.
        - Treat reliability as a prior, not a license to force a mismatched supported dataset onto an idea that clearly belongs elsewhere.
        - Prefer supported cards when they genuinely fit the scientific question.
        - If the only plausible match is experimental, you may name it, but keep `is_ready` false unless the idea is still clearly bounded and the risk is worth surfacing.
        - Treat speculative fragments like "maybe", "not sure", or rough confounder ideas as hints rather than mandatory title text.
        - Prefer clusters that combine complementary fragments into one coherent empirical question.
        - Avoid redundant singleton clusters when a stronger multi-note cluster captures the same idea.
        - Each note should belong to at most one cluster unless a small overlap is truly indispensable; overlapping trusted_ready clusters are usually a mistake.
        - Do not create multiple trusted_ready clusters from the same note pocket with only minor wording differences or alternate sub-questions.
        - If one cluster already captures a note set, fold alternate angles into that cluster's question, methods, or hypotheses rather than spawning a second runnable cluster.
        - If the inbox spans multiple unrelated domains, preserve them as separate clusters rather than collapsing everything into one dominant topic.
        - Aim to account for the full inbox; unless notes are clearly redundant or uninterpretable, do not leave a coherent topical pocket unclustered.
        - When one note gives the outcome and nearby notes add confounders, subgroup ideas, or practical constraints, prefer one richer multi-note cluster over multiple singleton clusters.
        - A realistic scientist inbox often stores context across several messy notes; preserve that context inside the cluster instead of forcing every paper to map to one note.
        - Prefer a single primary trusted dataset card when one card is sufficient for a strong first-pass paper; only include multiple dataset_ids when the notes clearly require cross-source validation or one source alone cannot answer the question.

        Readiness modes:
        - trusted_ready: at least one trusted dataset card clearly or plausibly fits and you can infer a bounded first-pass empirical analysis without inventing a fundamentally different scientific question; set is_ready to true
        - trusted_partial: trusted data exists, but even after reasonable inference the paper would still be too ambiguous, too weak, or too mismatched to auto-run; set is_ready to false
        - exploratory_ready: the idea likely needs unvetted external data; set is_ready to false

        Dataset-tier guardrails:
        - Do not mark a cluster `trusted_ready` just because a supported card exists somewhere in the shortlist; the supported card must honestly match the question.
        - When a supported card is a plausible fit and the missing details are ordinary framing choices rather than a different scientific question, prefer `trusted_ready` over `trusted_partial`.
        - If the best match is experimental, prefer `trusted_partial` unless the notes already imply an unusually narrow first-pass metadata study.
        - Do not invent a supported match when the real best-fit source family is experimental or absent.

        A cluster can still be trusted_ready when the notes are rough if a single trusted dataset card clearly supports a manageable study-, cohort-, atlas-, survey-, or table-level question.
        A single messy note can still be trusted_ready when it implies a concrete pilot comparison on a supported source family, even if the exact covariates or subgroup details must be filled in during planning.
        A biology or neuroscience atlas cluster can still be trusted_ready when two or more messy notes jointly point to a concrete labeled-cell comparison, even if no single note is polished.

        Use only dataset_ids from the trusted dataset cards below. Prefer at most 3 dataset_ids per cluster, and prefer 1 when possible.
        `theme` and `suggestedTitle` should name the scientific question, variables, cohort, organism, or phenomenon.
        Do not default to repository or dataset-brand names in `theme` or `suggestedTitle` unless they are genuinely required for clarity.
        `suggestedTitle` should read like a plausible paper title or strong working title, not a dataset lookup or a literal note dump.
        Keep `suggestedTitle` compact. Avoid exhaustive comma-separated covariate lists and avoid naming more than 3 speculative variables in the title.
        When rushed notes mention a grab-bag of possible covariates, use an umbrella phrase such as clinical factors, functional measures, atlas composition, or observation metadata instead of echoing every candidate variable.

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
            responseBaseURL: codexBaseURL,
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
        let selection = await trustedDatasets.sourceSelection(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            limit: 4
        )
        let selectedDatasets = selection.datasets
        let allowedDomains = TrustedDatasetRegistry.allowedDomains(for: selectedDatasets)
        let registryVersion = await trustedDatasets.registryVersion()

        return ResearchRunPreparation(
            selectedDatasetIDs: selectedDatasets.map(\.id),
            allowedDomains: allowedDomains,
            registryVersion: registryVersion,
            sourceSupportTier: selection.supportTier,
            schedulingDisposition: (selection.isAutoStartEligible || selection.allowsExploratoryAutoStart) ? .autoStart : .hold,
            initialStatusMessage: selection.message ?? "Research queued.",
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
        let datasetGuidance = datasetExecutionGuidance(for: selectedDatasets, stage: .plan)
        let exploratoryGuidance = exploratoryExecutionGuidance(for: selectedDatasets, stage: .plan)
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
        - Use only the provided notes and source-family cards below.
        - The notes may be typo-heavy, fragmented, or only meaningful in combination; infer the strongest coherent empirical question from the whole note set rather than waiting for polished wording.
        - Treat the trusted dataset cards as candidate source families for a bounded discovery pass, not as a precommitted dataset choice.
        - Discovery-catalog cards are scouting surfaces, not datasets themselves.
        - Quickly compare topical fit, tractability, likely reachable slice, and reliability across the candidate source families before naming one in `dataset_needs`.
        - Keep the plan concise, empirical, and executable on a first pass.
        - If the cards below are exploratory discovery catalogs or the reliable direct-source fit is weak, plan a bounded source scout across at most 3 candidate public source families and commit to the first tractable narrow slice instead of waiting for a gold-standard dataset.
        - In an exploratory run, once a tractable public dataset slice is found through a discovery catalog, the run may continue into inspection and analysis without prior registry onboarding as long as provenance is recorded explicitly.
        - Dataset-specific planning guardrails below are binding. If a guardrail says a variable, design element, or comparison must be confirmed first, keep it as a contingent risk or inspection target rather than committing to it in the main question, hypotheses, methods, or figure titles.
        - Prefer exactly one primary source family when it is enough for a credible first-pass paper. Supporting source families should be rare.
        - When the notes imply a broader mechanistic ambition than the reachable slice supports, rewrite the plan around the strongest honest first-pass empirical question the dataset can really answer.
        - Candidate methods must match the likely reachable slice; do not default to raw-data pipelines, large matrix reprocessing, or advanced models unless the trusted slice clearly supports them.
        - Planned figures should be real figures that the expected slice can support now, not wishlist figures for a later deeper analysis.
        - Do not force a dataset just because it is reliable. If none of the candidate source families is a strong fit, either set `dataset_id` to null and explain the exploratory scouting plan, or name the strongest plausible exploratory source family for inspection.
        - Do not write the paper yet.
        """

        let input = """
        Suggested title: \(title)
        Theme: \(theme)

        Trusted dataset cards:
        \(datasetCards)

        Dataset-specific planning guardrails:
        \(datasetGuidance)

        Exploratory scouting guidance:
        \(exploratoryGuidance)

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

    func resolvePlanDatasetBinding(
        plan: ResearchPlanArtifact,
        noteTexts: [String]
    ) async -> (datasetIDs: [String], datasets: [TrustedDataset]) {
        let rankedNeeds = plan.datasetNeeds.enumerated().sorted { lhs, rhs in
            let lhsPriority = datasetNeedPriority(lhs.element)
            let rhsPriority = datasetNeedPriority(rhs.element)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            return lhs.offset < rhs.offset
        }

        var orderedDatasetIDs: [String] = []
        var seen = Set<String>()

        for (_, need) in rankedNeeds {
            guard let datasetID = normalizedDatasetID(need.datasetID),
                  seen.insert(datasetID).inserted else {
                continue
            }

            orderedDatasetIDs.append(datasetID)
        }

        guard !orderedDatasetIDs.isEmpty else {
            return ([], [])
        }

        let resolved = await trustedDatasets.taskDatasetSelection(
            datasetIDs: orderedDatasetIDs,
            noteTexts: noteTexts,
            limit: max(1, orderedDatasetIDs.count)
        )

        return (resolved.map(\.id), resolved)
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
        let prompt = await researchAnalysisTaskPrompt(
            notes: notes,
            title: title,
            theme: theme,
            datasetIDs: datasetIDs,
            allowedDomains: allowedDomains,
            plan: plan,
            inspection: inspection,
            revisionRequest: revisionRequest
        )

        return try await createTask(prompt: prompt, preference: .networkedSelfContained)
    }

    private func datasetNeedPriority(_ need: ResearchDatasetNeed) -> Int {
        switch need.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "primary":
            return 0
        case "supporting":
            return 1
        default:
            return 2
        }
    }

    private func normalizedDatasetID(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    func runNetworkedResearchAnalysisResponse(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String],
        allowedDomains: [String],
        plan: ResearchPlanArtifact,
        inspection: ResearchInspectionArtifact,
        revisionRequest: ResearchVerificationArtifact? = nil
    ) async throws -> ResearchAnalysisArtifact {
        let prompt = await researchAnalysisTaskPrompt(
            notes: notes,
            title: title,
            theme: theme,
            datasetIDs: datasetIDs,
            allowedDomains: allowedDomains,
            plan: plan,
            inspection: inspection,
            revisionRequest: revisionRequest
        )
        let response = try await createResearchStageDirectResponse(prompt: prompt)
        let artifact = try decodeStructuredPayload(ResearchAnalysisArtifact.self, from: response.outputText)
        return try normalizedResearchAnalysisArtifact(artifact)
    }

    private func researchAnalysisTaskPrompt(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String],
        allowedDomains: [String],
        plan: ResearchPlanArtifact,
        inspection: ResearchInspectionArtifact,
        revisionRequest: ResearchVerificationArtifact? = nil
    ) async -> String {
        let selectedDatasets = await trustedDatasets.taskDatasetSelection(
            datasetIDs: datasetIDs,
            noteTexts: notes.map(\.content),
            limit: 4
        )
        let datasetCards = selectedDatasets.isEmpty
            ? "- No trusted dataset cards were resolved for this run."
            : selectedDatasets.map { $0.taskLine() }.joined(separator: "\n")
        let datasetGuidance = datasetExecutionGuidance(for: selectedDatasets, stage: .analyze)
        let exploratoryGuidance = exploratoryExecutionGuidance(for: selectedDatasets, stage: .analyze)
        let allowedDomainText = allowedDomains.isEmpty ? "none" : allowedDomains.joined(separator: ", ")
        let notesBody = notes.map { note in
            "- [\(note.id.uuidString)] \(note.content)"
        }.joined(separator: "\n\n")

        return """
        You are a research scientist using Code Interpreter.
        Run the empirical analysis only. The dataset inspection checkpoint has already happened. Do not write the paper yet.

        Requirements:
        1. Prefer the vetted dataset cards below and the inspected manifest before using anything else.
        2. Keep internet usage inside the approved domains unless those sources are blocked or insufficient.
        3. Stay aligned with the inspected dataset slice unless inspection clearly missed a blocker.
        3a. If inspection left the trusted set, do not resume source-shopping now; analyze the exact inspected external slice and record that provenance explicitly.
        4. Access real data, run the analysis, and produce real figures when warranted.
        4a. Every figure must be generated from this run's computed results. Do not copy images from papers, websites, or prior artifacts.
        4b. Figures should be print-ready PNGs with readable labels in a PDF, typically about 1100-1600 px on the long side unless a different aspect ratio is clearly better for the analysis.
        5. Return strict JSON only with this exact shape:
           {
             "dataset_manifest": {
               "primary_dataset_ids": ["trusted-dataset-id or external-source-id"],
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
               "used_dataset_ids": ["trusted-dataset-id or external-source-id"],
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
        15. Do not abandon the inspected primary trusted source just because one access method failed; retry the same approved source with an alternate approved-domain client or endpoint before declaring it blocked.
        16. If multiple trusted dataset cards are listed, keep one primary source and use a supporting source only if the inspected primary slice already yielded real usable data and a small targeted cross-check is genuinely necessary.

        Suggested title: \(title)
        Theme: \(theme)
        Approved domains: \(allowedDomainText)

        Trusted dataset cards:
        \(datasetCards)

        Dataset-specific execution guardrails:
        \(datasetGuidance)

        Exploratory scouting guidance:
        \(exploratoryGuidance)

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
    }

    func quarantineSelfContainedBundleEnvironment(_ environmentID: String?) async {
        guard let environmentID,
              !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        await environmentRouter.quarantine(environmentID, for: .selfContainedBundle)
    }

    func quarantineRepositoryBoundEnvironment(_ environmentID: String?) async {
        guard let environmentID,
              !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        await environmentRouter.quarantine(environmentID, for: .repositoryBound)
    }

    func quarantineNetworkedSelfContainedEnvironment(_ environmentID: String?) async {
        guard let environmentID,
              !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        await environmentRouter.quarantine(environmentID, for: .networkedSelfContained)
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

    func prefersBundledResearchFallback(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) async -> Bool {
        await stageFallback.prefersPrimaryFallback(
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
        A thin local orchestrator has already fetched a narrow public research slice from a trusted source.
        Inspect only that supplied bundle. Do not widen the slice, do not switch studies or collections, and do not run the final analysis yet.

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
        \(bulletList(stagedFallbackInspectionRequirements(for: fallback.kind)))
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

        Resolved public research bundle (\(fallback.providerLabel)) JSON:
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
        let fallbackStart = Date()
        log("startBundledResearchInspectionTask resolving fallback input. dataset_ids=\(datasetIDs)")
        guard let fallback = try await stageFallback.inspectionInput(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            theme: theme
        ) else {
            throw ServiceError.taskFailed("No staged remote fallback is available for this inspection slice yet.")
        }
        let fallbackSeconds = Date().timeIntervalSince(fallbackStart)
        log(
            "startBundledResearchInspectionTask resolved fallback kind=\(fallback.kind.rawValue) " +
                "bundle_chars=\(fallback.promptJSON.count) resolve_seconds=\(String(format: "%.2f", fallbackSeconds))"
        )

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
        A thin local coordinator already fetched a narrow trusted public research bundle. Use only that supplied bundle.
        Treat network access as unavailable for this task even if the environment technically exposes it.

        Requirements:
        \(numberedList(stagedFallbackBundledInspectionRequirements(for: fallback.kind, title: title, theme: theme), startingAt: 1))

        \(stagedFallbackStructuredInspectionShape())
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

        Resolved public research bundle (\(fallback.providerLabel)) JSON:
        \(fallback.promptJSON)
        """

        let fullPrompt = prompt + "\n\n" + input
        log("startBundledResearchInspectionTask creating task prompt_chars=\(fullPrompt.count)")
        return try await createTask(prompt: fullPrompt, preference: .selfContainedBundle)
    }

    func startResearchInspectionTask(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String],
        allowedDomains: [String],
        plan: ResearchPlanArtifact
    ) async throws -> String {
        let prompt = await researchInspectionTaskPrompt(
            notes: notes,
            title: title,
            theme: theme,
            datasetIDs: datasetIDs,
            allowedDomains: allowedDomains,
            plan: plan
        )

        return try await createTask(prompt: prompt, preference: .networkedSelfContained)
    }

    func runNetworkedResearchInspectionResponse(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String],
        allowedDomains: [String],
        plan: ResearchPlanArtifact
    ) async throws -> ResearchInspectionArtifact {
        let prompt = await researchInspectionTaskPrompt(
            notes: notes,
            title: title,
            theme: theme,
            datasetIDs: datasetIDs,
            allowedDomains: allowedDomains,
            plan: plan
        )
        let response = try await createResearchStageDirectResponse(prompt: prompt)
        return try decodeStructuredPayload(ResearchInspectionArtifact.self, from: response.outputText)
    }

    private func researchInspectionTaskPrompt(
        notes: [Note],
        title: String,
        theme: String,
        datasetIDs: [String],
        allowedDomains: [String],
        plan: ResearchPlanArtifact
    ) async -> String {
        let selectedDatasets = await trustedDatasets.taskDatasetSelection(
            datasetIDs: datasetIDs,
            noteTexts: notes.map(\.content),
            limit: 4
        )
        let datasetCards = selectedDatasets.isEmpty
            ? "- No trusted dataset cards were resolved for this run."
            : selectedDatasets.map { $0.taskLine() }.joined(separator: "\n")
        let datasetGuidance = datasetExecutionGuidance(for: selectedDatasets, stage: .inspect)
        let exploratoryGuidance = exploratoryExecutionGuidance(for: selectedDatasets, stage: .inspect)
        let allowedDomainText = allowedDomains.isEmpty ? "none" : allowedDomains.joined(separator: ", ")
        let notesBody = notes.map { note in
            "- [\(note.id.uuidString)] \(note.content)"
        }.joined(separator: "\n\n")

        return """
        You are a research scientist using Code Interpreter.
        Resolve the best reachable dataset slice and inspect it only. Do not run the final analysis yet.

        Requirements:
        1. Prefer vetted direct-source cards below before using anything else. If the listed cards are discovery catalogs, use them only to scout candidate public sources.
        2. Keep internet usage inside the approved domains unless those sources are blocked or insufficient.
        3. Resolve a concrete dataset slice, inspect the schema or metadata, and report what is actually usable for analysis.
        3a. If this run is exploratory, scout at most 3 candidate public source families total and stop searching as soon as one yields a tractable slice with real usable variables.
        4. Return strict JSON only with this exact shape:
           {
             "dataset_manifest": {
               "primary_dataset_ids": ["trusted-dataset-id or external-source-id"],
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
        10. If the first HTTP client or shell tool hits a tunnel, proxy, or CONNECT-style denial, retry the same approved source with at least one alternate approved-domain access method before concluding the source is blocked.
        11. If multiple trusted dataset cards are listed, choose one primary slice first and stay with it unless the notes explicitly require cross-source validation.
        11a. If you leave the trusted set during exploratory scouting, that is acceptable for this run, but record the exact chosen public source and domains explicitly.
        12. The final assistant message must contain only the JSON object and nothing before or after it.

        Suggested title: \(title)
        Theme: \(theme)
        Approved domains: \(allowedDomainText)

        Trusted dataset cards:
        \(datasetCards)

        Dataset-specific execution guardrails:
        \(datasetGuidance)

        Exploratory scouting guidance:
        \(exploratoryGuidance)

        Notes:
        \(notesBody)

        Research plan JSON:
        \(prettyJSONString(plan))
        """
    }

    func checkResearchInspectionTask(_ taskID: String) async throws -> ResearchInspectionTaskCheckResult {
        if let forcedSnapshot = qaForcedNoSignalTaskSnapshot(taskID: taskID) {
            return .waiting(forcedSnapshot)
        }

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
        if let forcedSnapshot = qaForcedNoSignalTaskSnapshot(taskID: taskID) {
            return .waiting(forcedSnapshot)
        }

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
        A thin local orchestrator has already fetched a narrow trusted public research slice and checkpointed the inspection artifact.
        Analyze only the supplied bundle. Do not widen the dataset slice, do not invent extra variables, do not make network requests, and do not write the paper yet.

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
        \(bulletList(stagedFallbackAnalysisRequirements(for: fallback.kind)))
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

        Resolved public research bundle (\(fallback.providerLabel)) JSON:
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
        A thin local coordinator already fetched a narrow trusted public research bundle and checkpointed the inspection artifact. Analyze only that supplied bundle.
        Treat network access as unavailable for this task even if the environment technically exposes it.

        Requirements:
        \(numberedList(stagedFallbackBundledAnalysisRequirements(for: fallback.kind), startingAt: 1))

        \(stagedFallbackStructuredAnalysisShape())

        Suggested title: \(title)
        Theme: \(theme)
        Study question: \(plan.question)
        Key hypotheses: \(compactHypotheses)
        Inspection checklist: \(compactChecklist)
        \(revisionRequest.map { """

        Verification revision JSON:
        \(stringify(verificationPromptPayload(from: $0)))
        """ } ?? "")

        Resolved public research bundle (\(fallback.providerLabel)):
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
        You are writing a full professional manuscript from verified research artifacts.
        Use the supplied plan, analysis, and verification only. Do not invent new results.

        Return strict JSON only with this exact shape:
        {
          "title": "string",
          "markdown": "clean academic markdown only, with references to bare figure_1.png style filenames"
        }

        Requirements:
        - Write a serious empirical paper, not a planning memo or short abstract.
        - The manuscript should read like a real arXiv-style paper and should usually typeset to roughly 6-7 pages at standard academic density unless the verified evidence is genuinely too limited.
        - Target approximately 2,600-3,800 words when the supplied artifacts support that depth; a short 1,200-1,800 word report is usually not acceptable.
        - Prefer standard sections such as Abstract, Introduction, Data, Methods, Results, Discussion, Limitations, and References when they fit.
        - Give the Introduction, Data/Methods, Results, and Discussion enough detail that a scientist would believe the analysis was actually carried out.
        - Reproduce at least one structured markdown table whenever `analysis.tables` contains a materially useful table.
        - Reference every available figure asset in the narrative results or discussion using bare filenames like `figure_1.png`.
        - Only state empirical results that are supported by `supported_claims`.
        - Treat `weak_or_unsupported_claims`, `model_warnings`, and `sample_warnings` as limitations, caveats, or omissions rather than results.
        - Avoid bullet-heavy formatting except where a conventional reference list or table note truly requires it.
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
        9. The markdown must read like a serious paper suitable for an arXiv-style PDF, not a planning memo. Prefer standard sections such as Abstract, Introduction, Data, Methods, Results, Discussion, Limitations, and References when they fit.
        9a. Unless the verified evidence is genuinely sparse, aim for a manuscript that would typeset to roughly 6-7 pages at standard academic density rather than a short 2-page report.
        9aa. When the artifacts are rich enough, target roughly 2,600-3,800 words instead of a thin summary.
        9b. When the analysis supports it, include at least one substantive markdown table and discuss it in the Results section.
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
            registryVersion: registryVersion
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
        let retryDelays: [Duration] = [.seconds(1), .seconds(2)]
        let baseURL = responseBaseURL ?? defaultResponsesBaseURL()
        let authMode = try await responseRequestAuth(for: baseURL)
        log(
            "createResponse routing. workload=\(workload.description) " +
                "base=\(baseURL.host ?? "<unknown>") auth=\(authMode.description)"
        )

        for model in candidates {
            for attempt in 0 ... retryDelays.count {
                log(
                    "createResponse starting. workload=\(workload.description) model=\(model) " +
                        "tool_count=\(tools.count) attempt=\(attempt + 1)"
                )
                var body: [String: Any] = [
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

                if baseURL.host == apiBaseURL.host {
                    body["reasoning"] = responseReasoningConfiguration(for: workload)
                }

                do {
                    let response = try await sendJSONRequest(
                        baseURL: baseURL,
                        pathComponents: ["responses"],
                        method: "POST",
                        body: body,
                        authMode: authMode,
                        responseMode: .completed
                    )
                    log(
                        "createResponse succeeded. workload=\(workload.description) model=\(model) " +
                            "status=\(response.status) attempt=\(attempt + 1)"
                    )
                    if case .apiKey = authMode {
                        clearUserAPIKeyFailure()
                    }
                    await modelRouter.remember(model: model, for: workload)
                    return response
                } catch {
                    log(
                        "createResponse failed. workload=\(workload.description) model=\(model) " +
                            "attempt=\(attempt + 1) error=\(String(describing: error))"
                    )
                    if let retryMessage = retryableModelSelectionMessage(from: error) {
                        unsupportedMessages.append("\(model): \(retryMessage)")
                        break
                    }

                    guard attempt < retryDelays.count,
                          shouldRetryCreateResponse(after: error) else {
                        throw error
                    }

                    let delay = retryDelays[attempt]
                    log(
                        "createResponse retrying same model after transient failure. " +
                            "workload=\(workload.description) model=\(model) " +
                            "next_attempt=\(attempt + 2) delay_seconds=\(delay.components.seconds)"
                    )
                    try? await Task.sleep(for: delay)
                }
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
        if hasUserAPIKeyOverride {
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
        }

        let oauthUnavailableReason = "Direct Code Interpreter fallback is unavailable in ChatGPT OAuth mode."

        if let unavailableReason = await researchStageFallbackRouter.cachedUnavailabilityReason() {
            log(
                "createResearchStageFallbackResponse skipping direct responses fallback " +
                    "due to cached unavailability: \(unavailableReason)"
            )
            throw ServiceError.taskFailed(unavailableReason)
        }

        await researchStageFallbackRouter.remember(oauthUnavailableReason)
        throw ServiceError.taskFailed(oauthUnavailableReason)
    }

    private func createResearchStageDirectResponse(prompt: String) async throws -> ResponseEnvelope {
        let instructions = """
        You are a research scientist using Code Interpreter.
        Follow the full user specification exactly.
        Return only the requested structured JSON artifact and nothing else.
        """

        if hasUserAPIKeyOverride {
            return try await createResponse(
                for: .researchStageFallback,
                tools: codeInterpreterTools(),
                toolChoice: "required",
                responseBaseURL: apiBaseURL,
                instructions: instructions,
                input: prompt
            )
        }

        do {
            return try await createResponse(
                for: .researchStageFallback,
                tools: codeInterpreterTools(),
                toolChoice: "required",
                responseBaseURL: apiBaseURL,
                instructions: instructions,
                input: prompt
            )
        } catch {
            guard shouldRetryResearchStageFallbackResponse(after: error) else {
                throw error
            }

            log(
                "createResearchStageDirectResponse retrying via ChatGPT backend /codex/responses " +
                    "after api failure: \(String(describing: error))"
            )

            return try await createResponse(
                for: .researchStageFallback,
                tools: codeInterpreterTools(),
                toolChoice: "required",
                responseBaseURL: codexBaseURL,
                instructions: instructions,
                input: prompt
            )
        }
    }

    private func createTask(
        prompt: String,
        preference: CloudTaskEnvironmentPreference = .repositoryBound
    ) async throws -> String {
        let effectivePreference = effectiveTaskPreference(for: preference)
        let environments = try await candidateEnvironments(for: preference)
        guard !environments.isEmpty else {
            throw ServiceError.taskFailed("No usable repository-bound Codex environments are available for this ChatGPT workspace.")
        }
        let branch = taskBranch(for: effectivePreference)
        let workerPrompt = queuedRemoteTaskPrompt(from: prompt)
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
                                "text": workerPrompt
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
                await environmentRouter.remember(environment, for: effectivePreference)
                return taskID
            } catch let error as BackendRequestFailure
                where error.detailType == "repo_not_accessible" {
                    let label = environment.label ?? environment.id
                    skippedLabels.append(label)
                    lastError = error
                    await environmentRouter.quarantine(environment.id, for: effectivePreference)
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

    private func taskBranch(for _: CloudTaskEnvironmentPreference) -> String {
        // The current task backend requires a branch for every task creation request.
        return resolvedTaskBranch()
    }

    private func queuedRemoteTaskPrompt(from prompt: String) -> String {
        """
        You are running as a queued remote research worker.
        While the task is active, emit brief plain-text progress updates at major milestones so Sidekick can tell the worker is alive.
        Keep those progress updates short, avoid braces or JSON, and keep the final assistant message in the exact output format requested by the user.

        \(prompt)
        """
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

    private func resolvePostGitHubOAuthExecutionSetupState(
        fallbackMessage: String,
        workspaceContext: GitHubWorkspaceContext?
    ) async -> OAuthExecutionSetupSnapshot {
        let outcome = await autoBootstrapOAuthExecutionEnvironmentIfPossible()

        if let environments = try? await fetchEnvironments() {
            await oauthSetupBootstrap.reset()
            let preferredEnvironment = preferredSetupEnvironment(from: environments)
            return OAuthExecutionSetupSnapshot(
                phase: .ready,
                message: nil,
                environmentLabel: preferredEnvironment?.label,
                machineLabel: nil,
                workspaceRepositoryFullName: workspaceContext?.repositoryFullName
            )
        }

        let shouldEscalateToManualFinish: Bool
        switch outcome {
        case .autoProvisioning:
            shouldEscalateToManualFinish = false
            await oauthSetupBootstrap.recordProgress()
        case .waitingForMachine, .waitingForEnvironment:
            shouldEscalateToManualFinish = await oauthSetupBootstrap.recordUnresolvedStateObservation()
        }

        switch outcome {
        case .waitingForMachine:
            if shouldEscalateToManualFinish {
                return OAuthExecutionSetupSnapshot(
                    phase: .manualFinish,
                    message: manualEnvironmentCompletionMessage(
                        workspaceContext: workspaceContext,
                        detail: "Codex has not exposed a usable repository-bound machine template to Sidekick yet."
                    ),
                    environmentLabel: nil,
                    machineLabel: nil,
                    workspaceRepositoryFullName: workspaceContext?.repositoryFullName
                )
            }

            return OAuthExecutionSetupSnapshot(
                phase: .waitingForMachine,
                message: """
                GitHub is connected, but Codex has not exposed a usable repository-bound runtime template yet. Leave this screen open. Sidekick will keep checking and will create your Sidekick workspace environment automatically as soon as one becomes available.
                """,
                environmentLabel: nil,
                machineLabel: nil,
                workspaceRepositoryFullName: workspaceContext?.repositoryFullName
            )
        case let .autoProvisioning(machineLabel):
            let suffix: String
            if let machineLabel, !machineLabel.isEmpty {
                suffix = " using \(machineLabel)."
            } else {
                suffix = "."
            }

            return OAuthExecutionSetupSnapshot(
                phase: .autoProvisioning,
                message: """
                GitHub is connected. Sidekick is creating and verifying your repository-bound Codex environment\(suffix) Keep this sheet open and your held papers will resume automatically when the environment is ready.
                """,
                environmentLabel: nil,
                machineLabel: machineLabel,
                workspaceRepositoryFullName: workspaceContext?.repositoryFullName
            )
        case let .waitingForEnvironment(machineLabel, detail):
            if shouldEscalateToManualFinish {
                return OAuthExecutionSetupSnapshot(
                    phase: .manualFinish,
                    message: manualEnvironmentCompletionMessage(
                        workspaceContext: workspaceContext,
                        detail: detail
                    ),
                    environmentLabel: nil,
                    machineLabel: machineLabel,
                    workspaceRepositoryFullName: workspaceContext?.repositoryFullName
                )
            }

            let detailSuffix: String
            if let detail,
               !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                detailSuffix = " Last backend response: \(detail)"
            } else {
                detailSuffix = ""
            }

            let machineSuffix: String
            if let machineLabel, !machineLabel.isEmpty {
                machineSuffix = " Sidekick is targeting \(machineLabel)."
            } else {
                machineSuffix = ""
            }

            return OAuthExecutionSetupSnapshot(
                phase: .waitingForEnvironment,
                message: fallbackMessage + machineSuffix + detailSuffix,
                environmentLabel: nil,
                machineLabel: machineLabel,
                workspaceRepositoryFullName: workspaceContext?.repositoryFullName
            )
        }
    }

    private func manualEnvironmentCompletionMessage(
        workspaceContext: GitHubWorkspaceContext?,
        detail: String?
    ) -> String {
        let repoName = workspaceContext?.repositoryFullName ?? "your Sidekick workspace repo"
        let normalizedDetail = detail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detailSuffix: String

        if let normalizedDetail, !normalizedDetail.isEmpty {
            detailSuffix = " Last backend response: \(normalizedDetail)"
        } else {
            detailSuffix = ""
        }

        return """
        GitHub is connected and Sidekick already scoped Codex to \(repoName), but Codex has not surfaced a usable repository-bound environment automatically. Open Codex Environments to finish or verify the environment for \(repoName), then come back and tap Check Again Now.\(detailSuffix)
        """
    }

    private func autoBootstrapOAuthExecutionEnvironmentIfPossible() async -> OAuthExecutionSetupBootstrapOutcome {
        do {
            let machines = try await fetchBootstrapMachines()
            guard let machine = preferredBootstrapMachine(from: machines) else {
                return .waitingForMachine
            }

            let shouldAttemptCreation = await oauthSetupBootstrap.beginAttempt(machineID: machine.id)
            guard shouldAttemptCreation else {
                return .autoProvisioning(machineLabel: machine.displayLabel)
            }

            do {
                _ = try await createOAuthExecutionEnvironment(machineID: machine.id)
                await oauthSetupBootstrap.finish(machineID: machine.id)
                return .autoProvisioning(machineLabel: machine.displayLabel)
            } catch let error as BackendRequestFailure {
                await oauthSetupBootstrap.finish(machineID: machine.id)

                if isAutoProvisioningFailure(error) {
                    return .autoProvisioning(machineLabel: machine.displayLabel)
                }

                let normalized = error.message.lowercased()
                if normalized.contains("machine"), normalized.contains("not found") {
                    return .waitingForMachine
                }

                return .waitingForEnvironment(
                    machineLabel: machine.displayLabel,
                    detail: error.message
                )
            } catch {
                await oauthSetupBootstrap.finish(machineID: machine.id)
                return .waitingForEnvironment(
                    machineLabel: machine.displayLabel,
                    detail: error.localizedDescription
                )
            }
        } catch {
            return .waitingForEnvironment(machineLabel: nil, detail: error.localizedDescription)
        }
    }

    private func fetchBootstrapMachines() async throws -> [CloudTaskMachineRecord] {
        let data = try await sendBackendRequest(
            pathComponents: ["wham", "machines"],
            method: "GET",
            body: nil
        )
        persistDebugPayload(data, named: "machines.json")

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let dictionaries = dictionaryArray(fromJSONObject: json)
        let machines: [CloudTaskMachineRecord] = dictionaries.compactMap { machineDictionary in
            guard let id = firstStringValue(
                in: machineDictionary,
                keys: ["id", "machine_id", "machineId"]
            ) else {
                return nil
            }

            return CloudTaskMachineRecord(
                id: id,
                label: firstStringValue(in: machineDictionary, keys: ["label", "name", "title"])
            )
        }

        var uniqueMachines: [CloudTaskMachineRecord] = []
        var seenMachineIDs = Set<String>()

        for machine in machines where seenMachineIDs.insert(machine.id).inserted {
            uniqueMachines.append(machine)
        }

        log("oauth setup fetched machines count=\(uniqueMachines.count)")
        return uniqueMachines
    }

    private func createOAuthExecutionEnvironment(machineID: String) async throws -> String? {
        guard let workspaceContext = github.workspaceContext else {
            throw ServiceError.taskFailed("Sidekick has not provisioned a workspace repository yet.")
        }

        let data = try await sendBackendRequest(
            pathComponents: ["wham", "environments"],
            method: "POST",
            body: [
                "machine_id": machineID,
                "label": sidekickOfflineEnvironmentLabel,
                "repos": [workspaceContext.repositoryFullName],
                "agent_network_access": [
                    "mode": "off"
                ]
            ]
        )
        persistDebugPayload(data, named: "environment-create-response.json")

        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let object = json as? [String: Any] {
            return firstStringValue(in: object, keys: ["id", "environment_id", "environmentId"])
        }

        return nil
    }

    private func preferredBootstrapMachine(
        from machines: [CloudTaskMachineRecord]
    ) -> CloudTaskMachineRecord? {
        machines.max { lhs, rhs in
            bootstrapMachinePriority(lhs) < bootstrapMachinePriority(rhs)
        }
    }

    private func bootstrapMachinePriority(_ machine: CloudTaskMachineRecord) -> Int {
        let label = machine.displayLabel.lowercased()
        var score = 0

        if label.contains("python") {
            score += 40
        }

        if label.contains("codex") {
            score += 30
        }

        if label.contains("default") {
            score += 20
        }

        if !label.isEmpty {
            score += 10
        }

        return score
    }

    private func preferredSetupEnvironment(
        from environments: [CloudTaskEnvironment]
    ) -> CloudTaskEnvironment? {
        environments.max { lhs, rhs in
            environmentPriority(lhs, for: .repositoryBound)
                < environmentPriority(rhs, for: .repositoryBound)
        }
    }

    private func isAutoProvisioningFailure(_ error: BackendRequestFailure) -> Bool {
        let evidence = [error.message, error.rawBody].joined(separator: " ").lowercased()
        let indicators = [
            "already exists",
            "duplicate",
            "in progress",
            "provisioning",
            "pending"
        ]

        return indicators.contains(where: evidence.contains)
    }

    private func dictionaryArray(fromJSONObject object: Any) -> [[String: Any]] {
        if let array = object as? [[String: Any]] {
            return array
        }

        if let dictionary = object as? [String: Any] {
            let preferredKeys = ["machines", "items", "results", "data"]

            for key in preferredKeys {
                if let array = dictionary[key] as? [[String: Any]] {
                    return array
                }
            }

            for value in dictionary.values {
                if let array = value as? [[String: Any]], !array.isEmpty {
                    return array
                }
            }
        }

        return []
    }

    private func firstStringValue(
        in dictionary: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return nil
    }

    private func candidateEnvironments(
        for preference: CloudTaskEnvironmentPreference
    ) async throws -> [CloudTaskEnvironment] {
        let environments = try await fetchEnvironments()
        let effectivePreference = effectiveTaskPreference(for: preference)
        let compatibleEnvironments: [CloudTaskEnvironment]

        switch effectivePreference {
        case .networkedSelfContained:
            let networkEnabled = environments.filter { $0.agentNetworkAccess?.mode?.lowercased() == "on" }
            compatibleEnvironments = networkEnabled.isEmpty ? environments : networkEnabled
        case .repositoryBound:
            compatibleEnvironments = environments.filter(\.isRepositoryBound)
        case .selfContainedBundle:
            compatibleEnvironments = environments
        }

        let quarantinedIDs = await environmentRouter.quarantinedIDs(for: effectivePreference)
        let viableEnvironments =
            quarantinedIDs.isEmpty
            ? compatibleEnvironments
            : compatibleEnvironments.filter { !quarantinedIDs.contains($0.id) }
        let environmentPool = viableEnvironments.isEmpty ? compatibleEnvironments : viableEnvironments
        let candidates: [CloudTaskEnvironment]

        switch effectivePreference {
        case .repositoryBound:
            var prioritized = environmentPool
                .sorted { environmentPriority($0, for: effectivePreference) > environmentPriority($1, for: effectivePreference) }

            if let remembered = await environmentRouter.cached(for: effectivePreference),
               let index = prioritized.firstIndex(where: { $0.id == remembered.id }) {
                let cached = prioritized.remove(at: index)
                prioritized.insert(cached, at: 0)
            }

            candidates = prioritized

        case .selfContainedBundle:
            let preferredPool = preferredSelfContainedEnvironmentPool(from: environmentPool)
            let preferredIDs = Set(preferredPool.map(\.id))
            let fallbackPool = environmentPool.filter { !preferredIDs.contains($0.id) }
            var prioritized =
                preferredPool
                .sorted { environmentPriority($0, for: effectivePreference) > environmentPriority($1, for: effectivePreference) }
                + fallbackPool.sorted {
                    environmentPriority($0, for: effectivePreference) > environmentPriority($1, for: effectivePreference)
                }

            if let remembered = await environmentRouter.cached(for: effectivePreference),
               let index = prioritized.firstIndex(where: { $0.id == remembered.id }) {
                let cached = prioritized.remove(at: index)
                prioritized.insert(cached, at: 0)
            }

            candidates = prioritized

        case .networkedSelfContained:
            let preferredPool = preferredNetworkedSelfContainedEnvironmentPool(from: environmentPool)
            let preferredIDs = Set(preferredPool.map(\.id))
            let fallbackPool = environmentPool.filter { !preferredIDs.contains($0.id) }
            var prioritized =
                preferredPool
                .sorted { environmentPriority($0, for: effectivePreference) > environmentPriority($1, for: effectivePreference) }
                + fallbackPool.sorted {
                    environmentPriority($0, for: effectivePreference) > environmentPriority($1, for: effectivePreference)
                }

            if let remembered = await environmentRouter.cached(for: effectivePreference),
               let index = prioritized.firstIndex(where: { $0.id == remembered.id }) {
                let cached = prioritized.remove(at: index)
                prioritized.insert(cached, at: 0)
            }

            candidates = prioritized
        }

        return candidates
    }

    private func preferredSelfContainedEnvironmentPool(
        from environments: [CloudTaskEnvironment]
    ) -> [CloudTaskEnvironment] {
        let codexPython = environments.filter { environment in
            environment.hasPythonRuntime
                && environment.agentNetworkAccess?.presetAllowlist?.lowercased() == "codex"
        }

        if !codexPython.isEmpty {
            return codexPython
        }

        let nonRepositoryPython = environments.filter { environment in
            environment.hasPythonRuntime && !(environment.label ?? "").contains("/")
        }

        return nonRepositoryPython.isEmpty ? environments : nonRepositoryPython
    }

    private func preferredNetworkedSelfContainedEnvironmentPool(
        from environments: [CloudTaskEnvironment]
    ) -> [CloudTaskEnvironment] {
        let unrestrictedNetworkedPython = environments.filter { environment in
            environment.hasPythonRuntime
                && environment.agentNetworkAccess?.mode?.lowercased() == "on"
                && environment.agentNetworkAccess?.presetAllowlist?.lowercased() == "all"
        }

        if !unrestrictedNetworkedPython.isEmpty {
            return unrestrictedNetworkedPython
        }

        let codexNetworkedPython = environments.filter { environment in
            environment.hasPythonRuntime
                && environment.agentNetworkAccess?.mode?.lowercased() == "on"
                && environment.agentNetworkAccess?.presetAllowlist?.lowercased() == "codex"
        }

        if !codexNetworkedPython.isEmpty {
            return codexNetworkedPython
        }

        let nonRepositoryNetworkedPython = environments.filter { environment in
            environment.hasPythonRuntime
                && environment.agentNetworkAccess?.mode?.lowercased() == "on"
                && !(environment.label ?? "").contains("/")
        }

        if !nonRepositoryNetworkedPython.isEmpty {
            return nonRepositoryNetworkedPython
        }

        let networkEnabled = environments.filter { $0.agentNetworkAccess?.mode?.lowercased() == "on" }
        return networkEnabled.isEmpty ? environments : networkEnabled
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

        switch preference {
        case .repositoryBound:
            if environment.isRepositoryBound {
                score += 6_000
            } else {
                score -= 12_000
            }
            if environment.hasPythonRuntime {
                score += 2_000
            }
            if mode == "off" {
                score += 1_000
            } else if mode == "on" {
                score += 250
            }
            let normalizedLabel = label.lowercased()
            if normalizedLabel.contains(sidekickOfflineEnvironmentLabel.lowercased()) {
                score += 750
            } else if normalizedLabel.contains(sidekickResearchEnvironmentLabel.lowercased()) {
                score += 500
            }
            if preset == "codex" {
                score += 100
            }

        case .selfContainedBundle:
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

            if preset == "codex" {
                score += 350
            } else if preset == "all" {
                score += 50
            }

            if label.contains("/") {
                score -= 100
            } else {
                score += 25
            }

        case .networkedSelfContained:
            if environment.hasPythonRuntime {
                score += 7_000
            } else {
                score -= 7_000
            }

            if mode == "on" {
                score += 8_000
            } else if mode == "off" {
                score -= 8_000
            }

            if preset == "all" {
                score += 1_000
            } else if preset == "codex" {
                score += 100
            }

            if label.contains("/") {
                score -= 250
            } else {
                score += 50
            }
        }

        // Prefer less-loaded environments when the coarse capabilities are otherwise similar.
        score -= environment.taskCount ?? 0

        return score
    }

    private func effectiveTaskPreference(
        for preference: CloudTaskEnvironmentPreference
    ) -> CloudTaskEnvironmentPreference {
        hasUserAPIKeyOverride ? preference : .repositoryBound
    }

    private func sendJSONRequest(
        baseURL: URL,
        pathComponents: [String],
        method: String,
        body: [String: Any]?,
        authMode: ResponseRequestAuth,
        responseMode: ResponseStreamMode = .completed
    ) async throws -> ResponseEnvelope {
        var request = URLRequest(url: endpoint(baseURL: baseURL, path: pathComponents))
        request.httpMethod = method
        applyResponseAuthHeaders(to: &request, authMode: authMode)
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
        applyOAuthHeaders(to: &request, token: token)
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

    private func probeBackendRequest(
        name: String,
        pathComponents: [String],
        method: String,
        body: [String: Any]?
    ) async throws -> BackendProbeResponse {
        let token = try await auth.validToken()
        var request = URLRequest(url: endpoint(baseURL: backendBaseURL, path: pathComponents))
        request.httpMethod = method
        applyOAuthHeaders(to: &request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        log("probeBackendRequest \(method) \(request.url?.absoluteString ?? "<nil>")")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        let safeName = name.replacingOccurrences(of: "/", with: "_")
        persistDebugPayload(
            data,
            named: "probe-\(safeName)-\(method.lowercased())-\(httpResponse.statusCode).json"
        )

        return BackendProbeResponse(
            statusCode: httpResponse.statusCode,
            allowHeader: httpResponse.value(forHTTPHeaderField: "Allow"),
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
            bodyPreview: preview(String(data: data, encoding: .utf8) ?? "", limit: 1200)
        )
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
            if event.type != "response.output_text.delta" {
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
            return [try decodeSingleStreamedEvent(from: joinedPayload, logOnFailure: dataLines.count == 1)]
        } catch let joinedError {
            guard dataLines.count > 1 else {
                throw joinedError
            }

            log("processStreamedEvent retrying batched SSE payload line-by-line. line_count=\(dataLines.count)")

            var events: [StreamedResponseEvent] = []
            events.reserveCapacity(dataLines.count)

            do {
                for line in dataLines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != "[DONE]" else {
                        continue
                    }

                    events.append(try decodeSingleStreamedEvent(from: trimmed, logOnFailure: false))
                }
            } catch let lineError {
                log(
                    "processStreamedEvent failed to decode joined SSE payload and line-by-line fallback. " +
                        "joined_error=\(String(describing: joinedError)) line_error=\(String(describing: lineError))"
                )
                log("processStreamedEvent payload preview: \(preview(joinedPayload, limit: 500))")
                throw lineError
            }

            return events
        }
    }

    private func decodeSingleStreamedEvent(
        from payload: String,
        logOnFailure: Bool = true
    ) throws -> StreamedResponseEvent {
        let data = Data(payload.utf8)

        do {
            return try JSONDecoder().decode(StreamedResponseEvent.self, from: data)
        } catch {
            guard logOnFailure else {
                throw error
            }

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

    private func applyResponseAuthHeaders(
        to request: inout URLRequest,
        authMode: ResponseRequestAuth
    ) {
        switch authMode {
        case let .oauth(token):
            applyOAuthHeaders(to: &request, token: token)
        case let .apiKey(key):
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private func applyOAuthHeaders(to request: inout URLRequest, token: String) {
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
        let sanitized = jsonCompatibleValue(value)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return string
    }

    private func jsonCompatibleValue(_ value: Any) -> Any {
        switch value {
        case is NSNull:
            return NSNull()
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case let array as [Any]:
            return array.map(jsonCompatibleValue)
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonCompatibleValue)
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        default:
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                if let wrapped = mirror.children.first?.value {
                    return jsonCompatibleValue(wrapped)
                }
                return NSNull()
            }

            return String(describing: value)
        }
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
                if let imageData = figure.imageData {
                    return [
                        "filename": figure.filename,
                        "caption": figure.caption,
                        "asset_status": "ok",
                        "image_bytes": NSNumber(value: imageData.count)
                    ]
                }

                return [
                    "filename": figure.filename,
                    "caption": figure.caption,
                    "asset_status": "missing_or_unusable",
                    "image_bytes": NSNull()
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
            case .plan:
                lines.append("- For neuro-oncology or glioblastoma notes, keep the first-pass plan inside one public cohort such as TCGA-GBM or one public cBioPortal GBM study.")
                lines.append("- Phrase the question around cohort-level survival associations, molecular subgroup coverage, or clinical covariates that the public slice can really support on a first pass.")
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
            case .plan:
                lines.append("- For neuroscience atlas or single-cell notes, rewrite broad mechanistic ideas into the strongest first-pass question that curated metadata, labeled cell populations, donor counts, and study-level fields can support.")
                lines.append("- Do not plan differential expression, pathway enrichment, or latent-module work unless the reachable slice clearly includes ready-to-analyze expression statistics; atlas composition, lineage coverage, and timepoint coverage are safer first-pass questions.")
            case .inspect:
                lines.append("- Choose one dandiset, atlas, morphology slice, or single-cell collection and return the exact collection identifier or atlas family you inspected.")
                lines.append("- Inspect only manageable metadata or study-level fields first; do not imply that large raw NWB matrices or image volumes were downloaded.")
                lines.append("- If only collection metadata and schema labels are reachable, make that explicit and keep the run grounded in donor, cell-count, lineage-label, tissue, and timepoint coverage.")
            case .analyze:
                lines.append("- Keep neuroscience analyses at the study, cohort, cell-type, brain-region, or collection level unless the inspected slice clearly supports more.")
                lines.append("- Report concrete counts such as donors, cells, reconstructions, sessions, or assets before making functional claims.")
                lines.append("- Do not claim differential expression, shared programs, or pathway enrichment from CELLxGENE metadata-only slices unless the inspected artifact actually contains those statistics.")
            }
        }

        if datasetIDs.contains("cellxgene-discover") {
            switch stage {
            case .plan:
                lines.append("- For CELLxGENE specifically, do not assume that per-cell tables, lesion-edge covariates, or donor-level paired statistics are reachable before inspection resolves one concrete collection and confirms those fields.")
                lines.append("- Until inspection confirms richer fields, phrase the first pass as atlas composition, label coverage, injury-related annotation coverage, or lineage representation rather than pseudo cell-level reanalysis.")
            case .inspect:
                lines.append("- For CELLxGENE, explicitly record whether lesion or edge labels, donor identifiers, injury timepoints, and glial subtype labels are present in the resolved collection.")
                lines.append("- If the reachable slice is only collection metadata plus schema categories, say so plainly and do not imply hidden per-cell tables.")
            case .analyze:
                lines.append("- For CELLxGENE rescue analyses, keep claims at the collection, subdataset, schema-label, or atlas-composition level unless inspection proved that richer per-cell metadata were actually available.")
            }
        }

        if !datasetIDs.isDisjoint(with: ["mast-observations", "nasa-exoplanet-archive"]) {
            switch stage {
            case .plan:
                lines.append("- For astronomy archive notes, keep the first-pass plan at the observation metadata or catalog-table level: filter names, exposure times, proposal counts, targets, missions, or table summaries.")
                lines.append("- Do not plan raw-image reduction, photometric extraction, or bespoke calibration pipelines unless the inspected slice explicitly supports them.")
            case .inspect:
                lines.append("- Resolve one archive table, mission, target set, or observation slice and return its exact name in the manifest.")
                lines.append("- Keep the inspection to catalog metadata, observation summaries, or mission-linked tables rather than broad archive crawling.")
                lines.append("- Preserve proposal, instrument, filter, exposure-time, and target fields when they are available because they often become the actual first-pass analysis surface.")
            case .analyze:
                lines.append("- Favor mission-scoped catalog summaries, transit/host-star comparisons, or observation-count analyses with explicit row counts.")
                lines.append("- Avoid implying custom raw-image or pixel-level reduction pipelines unless the inspected slice explicitly supported them.")
                lines.append("- Proposal-level or table-level summaries are acceptable when they preserve the contextual variables needed for the actual question.")
            }
        }

        if datasetIDs.contains("brfss-2015-github-mirror") {
            switch stage {
            case .plan:
                lines.append("- For the BRFSS diabetes mirror, keep the first pass inside one cross-sectional public mirror and phrase the question around likely reachable variables such as diabetes diagnosis, BMI, hypertension, self-rated health, physical activity, difficulty walking, age, sex, education, and income.")
                lines.append("- Do not commit to sleep analyses, survey-weighted design inference, race or geography effects, or year trends before inspection confirms those columns.")
            case .inspect:
                lines.append("- Inspect the exact mirror columns and outcome coding first, then report only the variables that are actually reachable.")
                lines.append("- Explicitly record whether sleep, survey weights, PSU or strata fields, race or ethnicity, geography, and year are absent so later stages do not imply them.")
            case .analyze:
                lines.append("- Keep the analysis cross-sectional and restricted to variables confirmed during inspection.")
                lines.append("- If sleep or survey-design fields are absent, prefer unweighted models or descriptive comparisons using the confirmed subset rather than pretending those fields existed.")
            }
        }

        if lines.isEmpty {
            return "- Stay narrow, name the exact public dataset slice, and prefer conservative empirical claims over broad speculative ones."
        }

        return lines.joined(separator: "\n")
    }

    private func exploratoryExecutionGuidance(
        for selectedDatasets: [TrustedDataset],
        stage: DatasetExecutionStage
    ) -> String {
        let isExploratory = selectedDatasets.isEmpty
            || selectedDatasets.contains { dataset in
                dataset.entryType == .discoveryCatalog || dataset.resolvedSupportTier != .supported
            }

        guard isExploratory else {
            return "- This run already has a supported direct source-family fit. Stay with it unless access truly fails."
        }

        switch stage {
        case .plan:
            return [
                "- Treat this as a bounded source-scouting run: compare at most 3 candidate public source families before committing to one.",
                "- Prefer official or curated public sources with a small tractable slice over a gold-standard dataset that is too heavy, blocked, or underspecified.",
                "- If the best first pass will likely leave the trusted set, say so plainly in `execution_notes` and keep the question narrow enough to inspect and analyze in one pass."
            ].joined(separator: "\n")
        case .inspect:
            return [
                "- Spend at most 3 candidate source-family attempts total in this inspection pass.",
                "- Stop scouting as soon as one public source yields a concrete analyzable slice with real variables, counts, or metadata.",
                "- If you leave the trusted set, record the exact chosen source name and domain in `data_sources` and `quality_checks` rather than hiding the pivot."
            ].joined(separator: "\n")
        case .analyze:
            return [
                "- Do not keep browsing for a better source during analysis. Analyze the exact inspected slice you already resolved.",
                "- If the inspected slice is external, set `provenance.left_trusted_set` to true and list the external source family and domains explicitly.",
                "- Prefer a quick honest pilot analysis over deeper but speculative source-shopping."
            ].joined(separator: "\n")
        }
    }

    private func stagedFallbackInspectionRequirements(
        for kind: ResearchStageFallbackKind
    ) -> [String] {
        var lines = [
            "Use Code Interpreter to validate and summarize the supplied bundle only.",
            "Keep the manifest anchored to the exact study, collection, archive slice, coverage counts, and variables present in the bundle.",
            "Prefer the strongest honest reachable slice over the broader original ambition.",
            "If the supplied bundle lacks something you wanted to inspect, record that limitation in `quality_checks` instead of trying to fetch replacement data.",
            "`selected_variables` must contain exact field names from the supplied bundle.",
            "The final assistant message must contain only the JSON object and nothing before or after it."
        ]

        switch kind {
        case .gbmCBioPortal:
            lines.append("If MGMT is only available as continuous methylation values, state that explicitly rather than inventing a binary promoter annotation.")
        case .mastObservations:
            lines.append("Treat the supplied proposal, filter, exposure-time, and preview metadata as the authoritative MAST slice; do not imply raw image downloads or pixel-level reduction.")
            lines.append("Keep `analysis_checklist` focused on exposure-time comparisons, filter-band coverage, proposal context, and any missing proposal or target metadata.")
        case .cellxgeneAtlas:
            lines.append("Treat the supplied collection metadata, subdataset counts, and schema categories as authoritative for this inspection pass.")
            lines.append("Do not claim gene-level differential expression, module discovery, or pathway enrichment unless the bundle explicitly includes those statistics.")
            lines.append("Keep `analysis_checklist` focused on atlas composition, donor coverage, injury timepoints, lineage labels, and other metadata-level comparisons that the bundle can support.")
        }

        return lines
    }

    private func stagedFallbackBundledInspectionRequirements(
        for kind: ResearchStageFallbackKind,
        title _: String,
        theme _: String
    ) -> [String] {
        var lines = [
            "Do not rely on repository files or repository context; the repo is irrelevant to this task.",
            "Do not make network requests, browse for external data, or hit live APIs. The supplied bundle is authoritative for this task.",
            "Do not widen the slice, switch studies or collections, or browse for replacement data unless the supplied bundle is malformed.",
            "Inspect the supplied bundle only and follow the structured JSON schema below."
        ]
        lines.append(contentsOf: stagedFallbackInspectionRequirements(for: kind))
        return lines
    }

    private func stagedFallbackAnalysisRequirements(
        for kind: ResearchStageFallbackKind
    ) -> [String] {
        var lines = [
            "Use Code Interpreter to decode and analyze only the supplied bundle and generate any figure bytes included in the final JSON.",
            "Do not contact external services. The supplied bundle is authoritative for this analysis pass.",
            "Prefer one concrete public dataset slice analysis over speculative multi-source synthesis.",
            "Generate real print-ready PNG figures directly from the computed results in this run. Do not copy figures from papers, websites, or old artifacts.",
            "Figures should usually be about 1100-1600 px on the long side with readable labels, legends, and line weights for PDF output. Compress intelligently, but do not shrink the figure below roughly 900 px on the long side just to save bytes.",
            "Do not emit placeholder, solid-color, or empty image files. Keep working until you have a real plot or explain precisely why the supplied bundle cannot support one.",
            "Also write each generated figure PNG into the task workspace using the same filename and leave it in place so the final task diff or snapshot contains the real binary asset.",
            "`findings[].evidence` must cite exact counts, field names, subgroup definitions, or figure/table identifiers from this run.",
            "If the strongest trustworthy result is descriptive or limited, return that instead of stalling.",
            "If verification guidance is supplied below, every required revision is mandatory unless the supplied bundle truly lacks the needed fields; in that case explain the blocker precisely in `limitations` and `quality_notes`.",
            "If a desired claim cannot be supported from the supplied bundle, say so in `limitations` or `quality_notes` instead of trying to fetch replacement data.",
            "The final assistant message must contain only the JSON object and nothing before or after it."
        ]

        switch kind {
        case .gbmCBioPortal:
            lines.append("Treat MGMT measurements exactly as represented in the bundle; do not relabel continuous methylation values as a binary promoter status unless the data justify it.")
            lines.append("If survival time and event fields are present, generate a real Kaplan-Meier survival figure as `figure_1.png` with the corresponding risk table rendered beneath each requested panel when the cohort supports it; do not substitute a bar chart or median-only graphic.")
            lines.append("The caption for `figure_1.png` must explicitly name the plotted stratifications and state whether the saved figure includes the risk table, so downstream verification can confirm the requirement from the checkpointed artifact.")
            lines.append("Include a table or table note that reports the exact number of patients contributing to every Kaplan-Meier stratum shown in the saved figure and the exact complete-case sample size used for the Cox model.")
            lines.append("If HM27 and HM450 MGMT measurements are both present, report the exact count available from each assay and the exact merge rule used in the model.")
            lines.append("If the study question or verification guidance asks about sex-specific survival differences, sex distributions alone are insufficient; report an explicit sex effect estimate and/or a sex-stratified survival comparison from the supplied cohort.")
            lines.append("Findings and results text must address every requested predictor that is available in the supplied bundle, including IDH1, EGFR, MGMT, age, and sex, or explicitly explain any omission in `limitations` or `quality_notes`.")
            lines.append("For each hazard ratio, make the modeled contrast explicit in the table or narrative. For sex and other binary predictors, name the reference group and ensure the interpretation matches the reported hazard ratio direction.")
            lines.append("If survival time, event, and the requested covariates are available with enough complete cases, fit the requested multivariable Cox model and report hazard ratios with confidence intervals.")
            lines.append("If age and sex fields are present, report their distributions and include at least one age- or sex-aware survival comparison or subgroup summary.")
            lines.append("If multiple assay fields represent one biological variable, document the exact merge rule in `dataset_manifest.quality_notes` and any relevant table notes.")
            lines.append("Keep narrative claims directionally consistent with the reported estimates and confidence intervals; do not describe an effect as harmful or protective if the estimate and uncertainty do not support that wording.")
        case .mastObservations:
            lines.append("Analyze the supplied proposal-filter summary table and preview metadata only; do not imply raw-image downloads or pixel-level reduction.")
            lines.append("Treat F225W, F275W, and F336W as ultraviolet filters and F438W, F555W, F606W, and F814W as optical filters unless the supplied bundle explicitly says otherwise.")
            lines.append("Generate a real `figure_1.png` comparing ultraviolet and optical exposure-time distributions or proposal-level medians from the supplied metadata.")
            lines.append("Report exact observation counts, proposal counts, and exposure summaries by filter band and by filter when the bundle supports them.")
            lines.append("If proposal-level summaries are available, prefer proposal-aware comparisons over naive pooled statements; if proposal IDs are missing, quantify that limitation.")
            lines.append("Keep astronomy claims associative and metadata-based; do not turn archive exposure-time differences into causal instrument-performance claims.")
        case .cellxgeneAtlas:
            lines.append("Analyze the supplied collection metadata, subdataset counts, and schema categories only; do not download matrices or claim gene-level differential expression, shared transcriptional programs, or pathway enrichment unless the bundle explicitly includes those statistics.")
            lines.append("Frame the first-pass result as atlas composition or coverage: donor count, disease labels, injury timepoints, subdataset cell counts, and glial label availability.")
            lines.append("Generate a real `figure_1.png` summarizing atlas composition or glial coverage from the supplied counts or category lists.")
            lines.append("Report exact counts for major subdatasets and note the presence of reactive astrocyte and oligodendrocyte-lineage labels and injury timepoints when they are present.")
            lines.append("If the notes ask about shared glial programs, state clearly that the metadata slice supports comparative atlas coverage but not direct program quantification.")
        }

        return lines
    }

    private func stagedFallbackBundledAnalysisRequirements(
        for kind: ResearchStageFallbackKind
    ) -> [String] {
        var lines = [
            "Do not rely on repository files or repository context; the repo is irrelevant to this task.",
            "Do not make network requests, browse for external data, or hit live APIs. The supplied bundle is authoritative for this task.",
            "Do not widen the slice, switch studies or collections, or browse for replacement data unless the supplied bundle is malformed.",
            "Use Python or equivalent computation inside the task to decode and analyze the supplied bundle, including any base64+zlib CSV payloads when present.",
            "Return strict JSON only with the exact shape shown below.",
            "Set `provenance.accessed_domains` and `provenance.external_sources` to empty lists unless you truly used an external domain, which you must not do in this task."
        ]
        lines.append(contentsOf: stagedFallbackAnalysisRequirements(for: kind))
        return lines
    }

    private func stagedFallbackStructuredInspectionShape() -> String {
        """
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
        """
    }

    private func stagedFallbackStructuredAnalysisShape() -> String {
        """
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
        """
    }

    private func bulletList(_ lines: [String]) -> String {
        lines.map { "- \($0)" }.joined(separator: "\n")
    }

    private func numberedList(_ lines: [String], startingAt start: Int) -> String {
        lines.enumerated()
            .map { "\(start + $0.offset). \($0.element)" }
            .joined(separator: "\n")
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

    private func shouldRetryCreateResponse(after error: Error) -> Bool {
        if error is URLError {
            return true
        }

        guard case let ServiceError.taskFailed(message) = error else {
            return false
        }

        let normalized = message.lowercased()
        let retryableIndicators = [
            "server had an error processing your request",
            "internal server error",
            "server error",
            "service unavailable",
            "temporarily unavailable",
            "temporarily busy",
            "overloaded",
            "rate limit",
            "timeout",
            "timed out",
            "connection reset",
            "connection lost",
            "network connection was lost",
            "bad gateway",
            "gateway timeout",
            "openai stream closed before the response completed",
            "openai response was incomplete"
        ]

        return retryableIndicators.contains(where: normalized.contains)
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

    private func defaultResponsesBaseURL() -> URL {
        hasUserAPIKeyOverride ? apiBaseURL : codexBaseURL
    }

    private func responseRequestAuth(for baseURL: URL) async throws -> ResponseRequestAuth {
        if baseURL.host == apiBaseURL.host,
           let apiKey = configuredAPIKeyOverride(),
           !apiKey.isEmpty {
            return .apiKey(apiKey)
        }

        return .oauth(try await auth.validToken())
    }

    private func refreshAPIKeyOverrideState() {
        let configuredKey = configuredAPIKeyOverride() ?? ""
        hasUserAPIKeyOverride = !configuredKey.isEmpty
        userAPIKeyHint = Self.apiKeyHint(for: configuredKey)

        if hasUserAPIKeyOverride {
            oauthExecutionSetup = .ready
            oauthExecutionSetupMessage = nil
            oauthExecutionRequiresGitHubConnection = false
        }
    }

    private func configuredAPIKeyOverride() -> String? {
        if let qaOverride = qaAPIKeyOverride() {
            return qaOverride
        }

        return storedAPIKey()
    }

    private func qaAPIKeyOverride() -> String? {
        let value = ProcessInfo.processInfo.environment[qaAPIKeyEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            return nil
        }

        return value
    }

    private func qaForcedNoSignalTaskSnapshot(taskID: String) -> PaperTaskProgressSnapshot? {
        guard ProcessInfo.processInfo.environment[qaForceNoSignalRemoteTasksEnvironmentVariable] == "1" else {
            return nil
        }

        let rawAge = ProcessInfo.processInfo.environment[qaForceNoSignalRemoteTaskAgeSecondsEnvironmentVariable] ?? ""
        let ageSeconds = max(5, Double(rawAge) ?? 125)
        let createdAt = Date().addingTimeInterval(-ageSeconds)

        return PaperTaskProgressSnapshot(
            taskID: taskID,
            status: "in_progress",
            observedAt: .now,
            taskCreatedAt: createdAt,
            assistantTurnCreatedAt: nil,
            latestEventAt: nil,
            latestEventText: nil,
            outputCharacterCount: 0,
            environmentID: "qa-silent-worker",
            environmentLabel: "QA silent worker",
            environmentNetworkMode: "on"
        )
    }

    private func qaForcedOAuthExecutionSetupSnapshot() -> OAuthExecutionSetupSnapshot? {
        guard let rawPhase = ProcessInfo.processInfo.environment[qaForceOAuthSetupPhaseEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let phase = OAuthExecutionSetupSnapshot.Phase(rawValue: rawPhase) else {
            return nil
        }

        let repo = ProcessInfo.processInfo.environment[qaForceOAuthWorkspaceRepoEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = ProcessInfo.processInfo.environment[qaForceOAuthSetupMessageEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch phase {
        case .ready:
            return .ready
        case .connectGitHub:
            return OAuthExecutionSetupSnapshot(
                phase: .connectGitHub,
                message: message?.isEmpty == false ? message : connectorBootstrapMessage(for: nil),
                environmentLabel: nil,
                machineLabel: nil,
                workspaceRepositoryFullName: repo
            )
        case .confirmRepositoryScope:
            return OAuthExecutionSetupSnapshot(
                phase: .confirmRepositoryScope,
                message: message?.isEmpty == false ? message : """
                Sidekick opened GitHub with only \(repo ?? "sidekick-workspace") preselected. Confirm that you left the ChatGPT Codex Connector on Only selected repositories and that this workspace repo was the only selected repo.
                """,
                environmentLabel: nil,
                machineLabel: nil,
                workspaceRepositoryFullName: repo
            )
        case .waitingForMachine:
            return OAuthExecutionSetupSnapshot(
                phase: .waitingForMachine,
                message: message?.isEmpty == false ? message : "GitHub is connected. Sidekick is waiting for Codex to expose a usable machine template for the workspace repo.",
                environmentLabel: nil,
                machineLabel: nil,
                workspaceRepositoryFullName: repo
            )
        case .autoProvisioning:
            return OAuthExecutionSetupSnapshot(
                phase: .autoProvisioning,
                message: message?.isEmpty == false ? message : "GitHub is connected. Sidekick is creating and verifying the repository-bound Codex environment.",
                environmentLabel: nil,
                machineLabel: "QA simulator machine",
                workspaceRepositoryFullName: repo
            )
        case .waitingForEnvironment:
            return OAuthExecutionSetupSnapshot(
                phase: .waitingForEnvironment,
                message: message?.isEmpty == false ? message : "GitHub is connected. Sidekick is waiting for the repository-bound Codex environment to appear.",
                environmentLabel: nil,
                machineLabel: "QA simulator machine",
                workspaceRepositoryFullName: repo
            )
        case .manualFinish:
            return OAuthExecutionSetupSnapshot(
                phase: .manualFinish,
                message: message?.isEmpty == false ? message : "GitHub is connected, but ChatGPT still needs a repository-bound environment for \(repo ?? "sidekick-workspace"). Open Codex Environments, finish or verify it there, then come back and check again.",
                environmentLabel: nil,
                machineLabel: "QA simulator machine",
                workspaceRepositoryFullName: repo
            )
        }
    }

    private func storedAPIKey() -> String? {
        let value = (try? apiKeychain.load(account: apiKeyAccount)).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let value, !value.isEmpty else {
            return nil
        }

        return value
    }

    private func apiKeyOverrideSourceDescription() -> String {
        if qaAPIKeyOverride() != nil {
            return "qa_env"
        }

        if storedAPIKey() != nil {
            return "keychain"
        }

        return "none"
    }

    private func restorePersistedUserAPIKeyFailureIfNeeded() {
        guard qaAPIKeyOverride() == nil,
              hasUserAPIKeyOverride,
              let persistedMessage = defaults.string(forKey: apiKeyFailureMessageDefaultsKey),
              let persistedFingerprint = defaults.string(forKey: apiKeyFailureFingerprintDefaultsKey),
              persistedFingerprint == persistedAPIKeyFingerprint() else {
            clearUserAPIKeyFailure()
            return
        }

        userAPIKeyErrorMessage = persistedMessage
    }

    private func publishOAuthExecutionSetupState(
        _ snapshot: OAuthExecutionSetupSnapshot
    ) async {
        await MainActor.run {
            guard self.oauthExecutionSetup != snapshot
                || self.oauthExecutionSetupMessage != snapshot.message
                || self.oauthExecutionRequiresGitHubConnection != snapshot.requiresGitHubConnection else {
                return
            }

            self.oauthExecutionSetup = snapshot
            self.oauthExecutionSetupMessage = snapshot.message
            self.oauthExecutionRequiresGitHubConnection = snapshot.requiresGitHubConnection
        }
    }

    private func oauthExecutionGitHubInstallationExists() async -> Bool {
        do {
            let data = try await sendBackendRequest(
                pathComponents: ["wham", "github", "installations"],
                method: "GET",
                body: nil
            )
            if data.isEmpty {
                return false
            }
            return true
        } catch let error as BackendRequestFailure {
            if error.statusCode == 404 {
                return false
            }
            return !(error.detailType == "missing_github_connector_link"
                || error.localizedDescription.localizedCaseInsensitiveContains("github connection not found for user"))
        } catch {
            return false
        }
    }

    private func fetchConnectedGitHubRepositoriesDiagnostics(
        workspaceContext: GitHubWorkspaceContext?
    ) async -> ConnectedGitHubRepositoriesDiagnostics {
        guard let workspaceContext else {
            return .unavailable
        }

        let candidatePaths = [
            ["wham", "github", "repos"],
            ["wham", "repos"],
        ]

        for path in candidatePaths {
            do {
                let data = try await sendBackendRequest(
                    pathComponents: path,
                    method: "GET",
                    body: nil
                )
                let repositories = decodeConnectedGitHubRepositories(from: data)
                guard !repositories.isEmpty else {
                    return .mismatch(
                        """
                        Codex reported a GitHub connection, but Sidekick could not confirm that only \(workspaceContext.repositoryFullName) is connected. Review GitHub access again and leave the connector on Only selected repositories.
                        """
                    )
                }

                guard repositories.count == 1 else {
                    return .mismatch(
                        """
                        Codex reported \(repositories.count) connected repositories. Sidekick only supports one workspace repo per user. Review GitHub access again and leave the connector scoped only to \(workspaceContext.repositoryFullName).
                        """
                    )
                }

                let connectedRepository = repositories[0]
                if connectedRepository.matches(workspaceContext: workspaceContext) {
                    return .matched
                }

                return .mismatch(
                    """
                    Codex reported \(connectedRepository.displayName) instead of \(workspaceContext.repositoryFullName). Review GitHub access again and leave the connector scoped only to \(workspaceContext.repositoryFullName).
                    """
                )
            } catch let error as BackendRequestFailure where error.statusCode == 404 {
                continue
            } catch {
                log("connected repo diagnostics failed for \(path.joined(separator: "/")): \(error.localizedDescription)")
            }
        }

        return .unavailable
    }

    private func decodeConnectedGitHubRepositories(from data: Data) -> [ConnectedGitHubRepository] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let dictionaries = dictionaryArray(fromJSONObject: json)
        return dictionaries.compactMap(ConnectedGitHubRepository.init)
    }

    private func persistUserAPIKeyFailureIfNeeded(_ message: String) {
        guard qaAPIKeyOverride() == nil,
              let fingerprint = persistedAPIKeyFingerprint() else {
            return
        }

        defaults.set(message, forKey: apiKeyFailureMessageDefaultsKey)
        defaults.set(fingerprint, forKey: apiKeyFailureFingerprintDefaultsKey)
    }

    private func persistedAPIKeyFingerprint() -> String? {
        guard let apiKey = storedAPIKey() else {
            return nil
        }

        let digest = SHA256.hash(data: Data(apiKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func apiKeyHint(for key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else {
            return nil
        }

        return "Ends with \(trimmed.suffix(4))"
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
    case plan
    case inspect
    case analyze
}

private enum OAuthExecutionSetupBootstrapOutcome {
    case waitingForMachine
    case autoProvisioning(machineLabel: String?)
    case waitingForEnvironment(machineLabel: String?, detail: String?)
}

private enum ResponseStreamMode {
    case created
    case completed
}

private enum ResponseRequestAuth {
    case oauth(String)
    case apiKey(String)

    var description: String {
        switch self {
        case .oauth:
            return "oauth"
        case .apiKey:
            return "api_key"
        }
    }
}

private struct CloudTaskMachineRecord: Hashable {
    let id: String
    let label: String?

    var displayLabel: String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? id : trimmed
    }
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

private func responseReasoningConfiguration(for _: OpenAIWorkload) -> [String: String] {
    [
        "effort": "low"
    ]
}

private enum CloudTaskEnvironmentPreference: String, Codable {
    case repositoryBound
    case selfContainedBundle
    case networkedSelfContained
}

private enum ConnectedGitHubRepositoriesDiagnostics {
    case matched
    case mismatch(String)
    case unavailable
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

private struct BackendProbeResponse {
    let statusCode: Int
    let allowHeader: String?
    let contentType: String?
    let bodyPreview: String
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

private actor OAuthExecutionSetupBootstrapCoordinator {
    private var isAttemptInFlight = false
    private var lastAttemptedMachineID: String?
    private var lastAttemptAt: Date?
    private var unresolvedStateFirstObservedAt: Date?
    private var unresolvedStateObservationCount = 0

    func beginAttempt(
        machineID: String,
        cooldown: TimeInterval = 20
    ) -> Bool {
        let now = Date()

        if isAttemptInFlight {
            return false
        }

        if lastAttemptedMachineID == machineID,
           let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < cooldown {
            return false
        }

        isAttemptInFlight = true
        lastAttemptedMachineID = machineID
        lastAttemptAt = now
        return true
    }

    func finish(machineID: String) {
        isAttemptInFlight = false
        lastAttemptedMachineID = machineID
        lastAttemptAt = Date()
    }

    func recordProgress() {
        unresolvedStateFirstObservedAt = nil
        unresolvedStateObservationCount = 0
    }

    func recordUnresolvedStateObservation(
        minimumObservations: Int = 4,
        timeout: TimeInterval = 45
    ) -> Bool {
        let now = Date()
        unresolvedStateObservationCount += 1

        if unresolvedStateFirstObservedAt == nil {
            unresolvedStateFirstObservedAt = now
        }

        guard let unresolvedStateFirstObservedAt else {
            return false
        }

        return unresolvedStateObservationCount >= minimumObservations
            || now.timeIntervalSince(unresolvedStateFirstObservedAt) >= timeout
    }

    func reset() {
        isAttemptInFlight = false
        lastAttemptedMachineID = nil
        lastAttemptAt = nil
        unresolvedStateFirstObservedAt = nil
        unresolvedStateObservationCount = 0
    }
}

private actor OpenAIEnvironmentRouter {
    private struct PersistedState: Codable {
        let repositoryBoundEnvironment: CloudTaskEnvironment?
        let selfContainedBundleEnvironment: CloudTaskEnvironment?
        let networkedSelfContainedEnvironment: CloudTaskEnvironment?
        let repositoryBoundQuarantine: [String: Date]
        let selfContainedBundleQuarantine: [String: Date]
        let networkedSelfContainedQuarantine: [String: Date]
    }

    private let defaults: UserDefaults
    private let stateKey = "com.vineet.sidekick.openai-environment-router"
    private var repositoryBoundEnvironment: CloudTaskEnvironment?
    private var selfContainedBundleEnvironment: CloudTaskEnvironment?
    private var networkedSelfContainedEnvironment: CloudTaskEnvironment?
    private var repositoryBoundQuarantine: [String: Date] = [:]
    private var selfContainedBundleQuarantine: [String: Date] = [:]
    private var networkedSelfContainedQuarantine: [String: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let persisted = Self.loadPersistedState(from: defaults)
        let now = Date()
        repositoryBoundEnvironment = persisted?.repositoryBoundEnvironment
        selfContainedBundleEnvironment = persisted?.selfContainedBundleEnvironment
        networkedSelfContainedEnvironment = persisted?.networkedSelfContainedEnvironment
        repositoryBoundQuarantine = (persisted?.repositoryBoundQuarantine ?? [:]).filter { $0.value > now }
        selfContainedBundleQuarantine = (persisted?.selfContainedBundleQuarantine ?? [:]).filter { $0.value > now }
        networkedSelfContainedQuarantine = (persisted?.networkedSelfContainedQuarantine ?? [:]).filter { $0.value > now }
    }

    func cached(for preference: CloudTaskEnvironmentPreference) -> CloudTaskEnvironment? {
        switch preference {
        case .repositoryBound:
            return repositoryBoundEnvironment
        case .selfContainedBundle:
            return selfContainedBundleEnvironment
        case .networkedSelfContained:
            return networkedSelfContainedEnvironment
        }
    }

    func remember(_ environment: CloudTaskEnvironment, for preference: CloudTaskEnvironmentPreference) {
        switch preference {
        case .repositoryBound:
            repositoryBoundEnvironment = environment
            repositoryBoundQuarantine.removeValue(forKey: environment.id)
        case .selfContainedBundle:
            selfContainedBundleEnvironment = environment
            selfContainedBundleQuarantine.removeValue(forKey: environment.id)
        case .networkedSelfContained:
            networkedSelfContainedEnvironment = environment
            networkedSelfContainedQuarantine.removeValue(forKey: environment.id)
        }

        persistState()
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
        case .networkedSelfContained:
            networkedSelfContainedQuarantine[environmentID] = Date().addingTimeInterval(duration)
            if networkedSelfContainedEnvironment?.id == environmentID {
                networkedSelfContainedEnvironment = nil
            }
        }

        persistState()
    }

    func quarantinedIDs(for preference: CloudTaskEnvironmentPreference) -> Set<String> {
        pruneExpiredQuarantines(now: .now)

        switch preference {
        case .repositoryBound:
            return Set(repositoryBoundQuarantine.keys)
        case .selfContainedBundle:
            return Set(selfContainedBundleQuarantine.keys)
        case .networkedSelfContained:
            return Set(networkedSelfContainedQuarantine.keys)
        }
    }

    private func pruneExpiredQuarantines(now: Date) {
        let prunedRepositoryBound = repositoryBoundQuarantine.filter { $0.value > now }
        let prunedSelfContained = selfContainedBundleQuarantine.filter { $0.value > now }
        let prunedNetworked = networkedSelfContainedQuarantine.filter { $0.value > now }
        let didChange =
            prunedRepositoryBound != repositoryBoundQuarantine
            || prunedSelfContained != selfContainedBundleQuarantine
            || prunedNetworked != networkedSelfContainedQuarantine

        repositoryBoundQuarantine = prunedRepositoryBound
        selfContainedBundleQuarantine = prunedSelfContained
        networkedSelfContainedQuarantine = prunedNetworked

        if didChange {
            persistState()
        }
    }

    private func persistState() {
        let state = PersistedState(
            repositoryBoundEnvironment: repositoryBoundEnvironment,
            selfContainedBundleEnvironment: selfContainedBundleEnvironment,
            networkedSelfContainedEnvironment: networkedSelfContainedEnvironment,
            repositoryBoundQuarantine: repositoryBoundQuarantine,
            selfContainedBundleQuarantine: selfContainedBundleQuarantine,
            networkedSelfContainedQuarantine: networkedSelfContainedQuarantine
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(state) else {
            return
        }

        defaults.set(data, forKey: stateKey)
    }

    private static func loadPersistedState(from defaults: UserDefaults) -> PersistedState? {
        guard let data = defaults.data(forKey: "com.vineet.sidekick.openai-environment-router") else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedState.self, from: data)
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

private struct CloudTaskEnvironment: Codable {
    let id: String
    let label: String?
    let isPinned: Bool?
    let taskCount: Int?
    let agentNetworkAccess: CloudTaskAgentNetworkAccess?
    let envVars: [String: String]?
    let repos: [CloudTaskEnvironmentRepository]?
    let repositories: [CloudTaskEnvironmentRepository]?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case isPinned = "is_pinned"
        case taskCount = "task_count"
        case agentNetworkAccess = "agent_network_access"
        case envVars = "env_vars"
        case repos
        case repositories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
        taskCount = try container.decodeIfPresent(Int.self, forKey: .taskCount)
        agentNetworkAccess = try container.decodeIfPresent(CloudTaskAgentNetworkAccess.self, forKey: .agentNetworkAccess)
        envVars = try container.decodeIfPresent([String: String].self, forKey: .envVars)
        repos = CloudTaskEnvironment.decodeRepositories(container: container, key: .repos)
        repositories = CloudTaskEnvironment.decodeRepositories(container: container, key: .repositories)
    }

    var hasPythonRuntime: Bool {
        envVars?["CODEX_ENV_PYTHON_VERSION"] != nil
    }

    var isRepositoryBound: Bool {
        let connectedRepositories = (repos ?? []) + (repositories ?? [])
        if !connectedRepositories.isEmpty {
            return true
        }
        return (label ?? "").contains("/")
    }

    private static func decodeRepositories(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> [CloudTaskEnvironmentRepository]? {
        if let repositories = try? container.decodeIfPresent([CloudTaskEnvironmentRepository].self, forKey: key) {
            return repositories
        }

        if let names = try? container.decodeIfPresent([String].self, forKey: key) {
            return names.map {
                CloudTaskEnvironmentRepository(name: nil, fullName: $0)
            }
        }

        return nil
    }
}

private struct CloudTaskEnvironmentRepository: Codable {
    let name: String?
    let fullName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
    }
}

private struct ConnectedGitHubRepository {
    let repositoryID: Int?
    let name: String?
    let fullName: String?

    nonisolated init?(dictionary: [String: Any]) {
        let repositoryID: Int?
        if let intValue = dictionary["id"] as? Int {
            repositoryID = intValue
        } else if let stringValue = dictionary["id"] as? String {
            repositoryID = Int(stringValue)
        } else if let intValue = dictionary["repository_id"] as? Int {
            repositoryID = intValue
        } else if let stringValue = dictionary["repository_id"] as? String {
            repositoryID = Int(stringValue)
        } else {
            repositoryID = nil
        }

        let name = (dictionary["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fullName = (
            (dictionary["full_name"] as? String)
            ?? (dictionary["fullName"] as? String)
            ?? (dictionary["repo"] as? String)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard repositoryID != nil || name != nil || fullName != nil else {
            return nil
        }

        self.repositoryID = repositoryID
        self.name = name
        self.fullName = fullName
    }

    var displayName: String {
        fullName ?? name ?? "<unknown repository>"
    }

    func matches(workspaceContext: GitHubWorkspaceContext) -> Bool {
        if let repositoryID, repositoryID == workspaceContext.repositoryID {
            return true
        }
        if let fullName, fullName == workspaceContext.repositoryFullName {
            return true
        }
        if let name, name == workspaceContext.repositoryName {
            return true
        }
        return false
    }
}

private struct CloudTaskAgentNetworkAccess: Codable {
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
