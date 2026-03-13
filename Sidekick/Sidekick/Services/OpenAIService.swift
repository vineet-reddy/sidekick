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
    private let baseURL = URL(string: "https://chatgpt.com/backend-api/codex")!

    init(auth: AuthService, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    func assessNotes(_ notes: [Note]) async throws -> [NoteCluster] {
        guard !notes.isEmpty else {
            return []
        }

        let notesPayload = notes.map { note in
            [
                "id": note.id.uuidString,
                "content": note.content,
                "createdAt": ISO8601DateFormatter().string(from: note.createdAt)
            ]
        }

        let prompt = """
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

        Notes:
        \(stringify(notesPayload))
        """

        let response = try await createResponse(
            model: "gpt-4o-mini",  // lightweight model for clustering
            background: false,
            tools: [],
            input: prompt
        )

        let text = response.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = normalizedJSONData(from: text) else {
            throw ServiceError.malformedPayload
        }

        let decoded = try JSONDecoder().decode(ClusterResponse.self, from: data)
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
    }

    func submitPaperTask(notes: [Note], title: String, theme: String) async throws -> String {
        let notesBody = notes.map { note in
            "- [\(note.id.uuidString)] \(note.content)"
        }.joined(separator: "\n\n")

        let prompt = """
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

        Suggested title: \(title)
        Theme: \(theme)

        Notes:
        \(notesBody)
        """

        let response = try await createResponse(
            model: "gpt-4o",  // full model for paper generation with code interpreter
            background: true,
            tools: [["type": "code_interpreter", "container": ["type": "auto"]]],
            input: prompt
        )

        guard let id = response.id, !id.isEmpty else {
            throw ServiceError.missingTaskID
        }

        return id
    }

    func checkTask(_ taskID: String) async throws -> PaperArtifacts? {
        let response = try await fetchResponse(taskID: taskID)

        switch response.status {
        case "queued", "in_progress", "incomplete":
            return nil
        case "completed":
            break
        case "failed", "cancelled":
            throw ServiceError.taskFailed(response.outputText.isEmpty ? "The paper task failed." : response.outputText)
        default:
            return nil
        }

        guard let data = normalizedJSONData(from: response.outputText) else {
            throw ServiceError.malformedPayload
        }

        let payload = try JSONDecoder().decode(PaperResponse.self, from: data)
        let figures = try await downloadFigures(from: response.files)

        return PaperArtifacts(title: payload.title, markdown: payload.markdown, figures: figures)
    }

    private func createResponse(
        model: String,
        background: Bool,
        tools: [[String: Any]],
        input: String
    ) async throws -> ResponseEnvelope {
        let body: [String: Any] = [
            "model": model,
            "background": background,
            "store": true,
            "tools": tools,
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

        return try await sendJSONRequest(
            pathComponents: ["responses"],
            method: "POST",
            body: body
        )
    }

    private func fetchResponse(taskID: String) async throws -> ResponseEnvelope {
        try await sendJSONRequest(pathComponents: ["responses", taskID], method: "GET", body: nil)
    }

    private func sendJSONRequest(
        pathComponents: [String],
        method: String,
        body: [String: Any]?
    ) async throws -> ResponseEnvelope {
        let token = try await auth.validToken()
        var request = URLRequest(url: endpoint(pathComponents))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "OpenAI request failed."
            throw ServiceError.taskFailed(message)
        }

        return try JSONDecoder().decode(ResponseEnvelope.self, from: data)
    }

    private func downloadFigures(from files: [ResponseFile]) async throws -> [Data] {
        let pngFiles = files
            .filter { $0.filename.lowercased().hasSuffix(".png") }
            .sorted { $0.filename < $1.filename }

        guard !pngFiles.isEmpty else {
            return []
        }

        let token = try await auth.validToken()
        var collected: [Data] = []

        for file in pngFiles {
            var request = URLRequest(url: endpoint(["files", file.fileID, "content"]))
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ..< 300).contains(httpResponse.statusCode) else {
                continue
            }

            collected.append(data)
        }

        return collected
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

        return cleaned.data(using: .utf8)
    }

    private func endpoint(_ path: [String]) -> URL {
        path.reduce(baseURL) { url, component in
            url.appendingPathComponent(component)
        }
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

private struct ResponseEnvelope: Decodable {
    let id: String?
    let status: String
    let output: [ResponseOutputItem]?

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
}

private struct ResponseContent: Decodable {
    let type: String?
    let text: String?
    let annotations: [ResponseAnnotation]?
    let filename: String?
    let fileID: String?

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
