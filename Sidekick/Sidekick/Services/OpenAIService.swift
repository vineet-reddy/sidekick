import Combine
import Foundation

struct NoteCluster: Codable, Hashable {
    let noteIDs: [UUID]
    let theme: String
    let suggestedTitle: String
    let isReady: Bool
}

struct PaperArtifacts {
    let title: String
    let markdown: String
    let figures: [Data]
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
    private let originator = "codex_cli_rs"
    private let modelRouter = OpenAIModelRouter()
    private let environmentRouter = OpenAIEnvironmentRouter()

    init(auth: AuthService, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
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

        let systemInstructions = """
        You are a research assistant. Group these notes into thematic clusters.
        A cluster is ready when the notes imply a testable claim and relevant open data likely exists.
        Be eager. Rough first drafts are better than unused ideas.

        Return strict JSON only with this shape:
        {
          "clusters": [
            {
              "noteIDs": ["UUID"],
              "theme": "string",
              "suggestedTitle": "string",
              "isReady": true
            }
          ]
        }
        """

        let userInput = "Notes:\n\(stringify(notesPayload))"

        log("assessNotes creating /codex/responses request")
        let response = try await createResponse(
            for: .noteAssessment,
            tools: [],
            instructions: systemInstructions,
            input: userInput
        )

        let text = response.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
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

                return NoteCluster(
                    noteIDs: ids,
                    theme: rawCluster.theme,
                    suggestedTitle: rawCluster.suggestedTitle,
                    isReady: rawCluster.isReady
                )
            }
        } catch {
            log("assessNotes failed to decode ClusterResponse: \(String(describing: error))")
            log("assessNotes normalized JSON preview: \(preview(String(data: data, encoding: .utf8) ?? "<non-utf8>", limit: 320))")
            throw error
        }
    }

    func submitPaperTask(notes: [Note], title: String, theme: String) async throws -> String {
        let notesBody = notes.map { note in
            "- [\(note.id.uuidString)] \(note.content)"
        }.joined(separator: "\n\n")

        let systemInstructions = """
        You are a research scientist using Code Interpreter.
        Create a real draft paper from the notes below.

        Requirements:
        1. Use open datasets or open literature APIs when relevant.
        2. Prefer focused API queries and subsets over bulk downloads.
        3. Run real analysis if data is available.
        4. Generate charts as PNG files when they add value.
        5. Return strict JSON only in your final message:
           {
             "title": "string",
             "markdown": "full academic markdown with references to figure_1.png style filenames"
           }
        6. If analysis is partial, state limitations clearly and still produce the strongest draft possible.
        """

        let userInput = """
        Suggested title: \(title)
        Theme: \(theme)

        Notes:
        \(notesBody)
        """

        let prompt = """
        \(systemInstructions)

        User request:
        \(userInput)
        """

        log("submitPaperTask creating remote task. title=\(title)")
        return try await createTask(prompt: prompt)
    }

    func checkTask(_ taskID: String) async throws -> PaperArtifacts? {
        log("checkTask polling. task_id=\(taskID)")
        let task = try await fetchTask(taskID: taskID)
        log("checkTask status=\(task.normalizedStatus) output_chars=\(task.outputText.count)")

        switch task.normalizedStatus {
        case "queued", "in_progress", "incomplete":
            return nil
        case "completed":
            break
        case "failed", "cancelled":
            throw ServiceError.taskFailed(task.errorMessage ?? "The paper task failed.")
        default:
            return nil
        }

        guard let data = normalizedJSONData(from: task.outputText) else {
            throw ServiceError.malformedPayload
        }

        let payload = try JSONDecoder().decode(PaperResponse.self, from: data)

        return PaperArtifacts(title: payload.title, markdown: payload.markdown, figures: [])
    }

    private func createResponse(
        for workload: OpenAIWorkload,
        tools: [[String: Any]],
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
                "tool_choice": "auto",
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

    private func createTask(prompt: String) async throws -> String {
        let environment = try await selectEnvironment()
        log("createTask using environment id=\(environment.id) label=\(environment.label ?? "<none>") branch=\(resolvedTaskBranch())")
        let body: [String: Any] = [
            "new_task": [
                "environment_id": environment.id,
                "branch": resolvedTaskBranch(),
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

        let data = try await sendBackendRequest(
            pathComponents: ["wham", "tasks"],
            method: "POST",
            body: body
        )
        log("createTask response bytes=\(data.count)")

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

    private func fetchTask(taskID: String) async throws -> CloudTaskDetails {
        let data = try await sendBackendRequest(
            pathComponents: ["wham", "tasks", taskID],
            method: "GET",
            body: nil
        )
        log("fetchTask response bytes=\(data.count) task_id=\(taskID)")

        return try JSONDecoder().decode(CloudTaskDetails.self, from: data)
    }

    private func selectEnvironment() async throws -> CloudTaskEnvironment {
        if let cached = await environmentRouter.cached() {
            return cached
        }

        let data = try await sendBackendRequest(
            pathComponents: ["wham", "environments"],
            method: "GET",
            body: nil
        )

        let environments = try JSONDecoder().decode([CloudTaskEnvironment].self, from: data)
        log("selectEnvironment fetched environments count=\(environments.count)")
        guard !environments.isEmpty else {
            throw ServiceError.taskFailed("No Codex cloud environments are available for this ChatGPT workspace.")
        }

        let selected = environments.first(where: { $0.isPinned == true })
            ?? environments.max(by: { ($0.taskCount ?? 0) < ($1.taskCount ?? 0) })
            ?? environments[0]

        await environmentRouter.remember(selected)
        return selected
    }

    private func resolvedTaskBranch() -> String {
        if let override = ProcessInfo.processInfo.environment["SIDEKICK_CODEX_BRANCH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }

        return "main"
    }

    private func sendJSONRequest(
        pathComponents: [String],
        method: String,
        body: [String: Any]?,
        responseMode: ResponseStreamMode = .completed
    ) async throws -> ResponseEnvelope {
        let token = try await auth.validToken()
        var request = URLRequest(url: endpoint(baseURL: codexBaseURL, path: pathComponents))
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
            let message = responseErrorMessage(from: data)
            throw ServiceError.taskFailed(message)
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

    private func normalizedJSONData(from raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        let cleaned = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = cleaned.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start <= end {
            let candidate = String(cleaned[start ... end])
            if let data = candidate.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return data
            }
        }

        return cleaned.data(using: .utf8)
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

    private var codexBaseURL: URL {
        backendBaseURL.appendingPathComponent("codex")
    }

    private func endpoint(baseURL: URL, path: [String]) -> URL {
        path.reduce(baseURL) { url, component in
            url.appendingPathComponent(component)
        }
    }
}

private enum ResponseStreamMode {
    case created
    case completed
}

private enum OpenAIWorkload {
    case noteAssessment
    case paperGeneration

    nonisolated var description: String {
        switch self {
        case .noteAssessment:
            return "note assessment"
        case .paperGeneration:
            return "paper generation"
        }
    }

    nonisolated var storageKey: String {
        switch self {
        case .noteAssessment:
            return "noteAssessment"
        case .paperGeneration:
            return "paperGeneration"
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
        }
    }
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
    private var selectedEnvironment: CloudTaskEnvironment?

    func cached() -> CloudTaskEnvironment? {
        selectedEnvironment
    }

    func remember(_ environment: CloudTaskEnvironment) {
        selectedEnvironment = environment
    }
}

private struct ClusterResponse: Decodable {
    struct Cluster: Decodable {
        let noteIDs: [String]
        let theme: String
        let suggestedTitle: String
        let isReady: Bool
    }

    let clusters: [Cluster]
}

private struct PaperResponse: Decodable {
    let title: String
    let markdown: String
}

private struct CloudTaskEnvironment: Decodable {
    let id: String
    let label: String?
    let isPinned: Bool?
    let taskCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case isPinned = "is_pinned"
        case taskCount = "task_count"
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
        assistantTexts.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var errorMessage: String? {
        currentAssistantTurn?.error?.summary
            ?? currentDiffTaskTurn?.error?.summary
            ?? task?.lastErrorMessage
    }

    private var assistantTexts: [String] {
        [currentDiffTaskTurn, currentAssistantTurn]
            .compactMap { $0 }
            .flatMap(\.messageTexts)
    }
}

private struct CloudTaskMetadata: Decodable {
    let id: String?
    let title: String?
    let taskStatusDisplay: CloudTaskStatusDisplay?
    let error: CloudTaskTurnError?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case taskStatusDisplay = "task_status_display"
        case error
    }

    var lastErrorMessage: String? {
        error?.summary
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
    let worklog: CloudTaskWorklog?
    let error: CloudTaskTurnError?

    enum CodingKeys: String, CodingKey {
        case id
        case attemptPlacement = "attempt_placement"
        case turnStatus = "turn_status"
        case siblingTurnIDs = "sibling_turn_ids"
        case outputItems = "output_items"
        case worklog
        case error
    }

    var messageTexts: [String] {
        var texts = (outputItems ?? []).flatMap(\.textValues)

        let worklogTexts = (worklog?.messages ?? [])
            .filter(\.isAssistant)
            .flatMap(\.textValues)

        texts.append(contentsOf: worklogTexts)
        return texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private struct CloudTaskOutputItem: Decodable {
    let type: String?
    let content: [CloudTaskContentFragment]?

    var textValues: [String] {
        guard type == "message" else {
            return []
        }

        return (content ?? []).compactMap(\.text)
    }
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
