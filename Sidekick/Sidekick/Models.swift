import Foundation
import SwiftData

enum PaperStatus: String, Codable, CaseIterable {
    case generating
    case ready
    case failed
}

@Model
final class Note {
    var id: UUID
    var content: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        content: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var title: String {
        let firstLine = content
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let firstLine, !firstLine.isEmpty else {
            return "Untitled idea"
        }

        return String(firstLine.prefix(64))
    }

    var summary: String {
        let normalized = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return "Start writing."
        }

        return String(normalized.prefix(140))
    }
}

@Model
final class Paper {
    var id: UUID
    var title: String
    var markdown: String
    var statusRaw: String
    var codexTaskID: String
    var sourceNoteIDsStorage: String
    var figureDataStorage: String
    var createdAt: Date
    var updatedAt: Date
    var lastNotifiedAt: Date?

    init(
        id: UUID = UUID(),
        title: String = "",
        markdown: String = "",
        status: PaperStatus = .generating,
        codexTaskID: String = "",
        sourceNoteIDs: [UUID] = [],
        figureData: [Data] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastNotifiedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.statusRaw = status.rawValue
        self.codexTaskID = codexTaskID
        self.sourceNoteIDsStorage = Self.encode(sourceNoteIDs)
        self.figureDataStorage = Self.encode(figureData)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastNotifiedAt = lastNotifiedAt
    }

    var status: PaperStatus {
        get { PaperStatus(rawValue: statusRaw) ?? .generating }
        set {
            statusRaw = newValue.rawValue
            updatedAt = .now
        }
    }

    var sourceNoteIDs: [UUID] {
        get { Self.decode(sourceNoteIDsStorage, as: [UUID].self) ?? [] }
        set {
            sourceNoteIDsStorage = Self.encode(newValue)
            updatedAt = .now
        }
    }

    var figureData: [Data] {
        get { Self.decode(figureDataStorage, as: [Data].self) ?? [] }
        set {
            figureDataStorage = Self.encode(newValue)
            updatedAt = .now
        }
    }

    var isTerminal: Bool {
        status != .generating
    }

    func matches(noteIDs: [UUID]) -> Bool {
        Set(sourceNoteIDs) == Set(noteIDs)
    }

    var summary: String {
        let body = PaperContentNormalizer.normalize(markdown: markdown)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else {
            return status == .generating ? "Paper generation in progress." : "No paper content yet."
        }

        return String(body.prefix(180))
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
