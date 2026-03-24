import Combine
import Foundation

enum MustUseSourceKind: String, Codable, CaseIterable, Identifiable {
    case paper
    case dataset
    case codebase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper:
            return "Paper"
        case .dataset:
            return "Dataset"
        case .codebase:
            return "Codebase"
        }
    }
}

struct MustUseSourceInput: Codable, Hashable, Identifiable {
    var id: UUID
    var kind: MustUseSourceKind
    var url: String
    var notes: String

    init(
        id: UUID = UUID(),
        kind: MustUseSourceKind = .paper,
        url: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.notes = notes
    }

    var normalizedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isMeaningful: Bool {
        !normalizedURL.isEmpty
    }

    var requestPayload: [String: String] {
        [
            "kind": kind.rawValue,
            "url": normalizedURL,
            "notes": normalizedNotes,
        ]
    }
}

struct ResearchInputSnapshot: Codable, Hashable {
    var mustUseSources: [MustUseSourceInput]
    var domainGuidance: String

    static let empty = ResearchInputSnapshot(mustUseSources: [], domainGuidance: "")

    var cleaned: ResearchInputSnapshot {
        ResearchInputSnapshot(
            mustUseSources: mustUseSources.filter(\.isMeaningful),
            domainGuidance: domainGuidance.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

@MainActor
final class ResearchInputStore: ObservableObject {
    @Published var mustUseSources: [MustUseSourceInput]
    @Published var domainGuidance: String

    private let defaults: UserDefaults
    private let key = "com.vineet.sidekick.research-inputs"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let stored = try? decoder.decode(ResearchInputSnapshot.self, from: data) {
            let cleaned = stored.cleaned
            mustUseSources = cleaned.mustUseSources
            domainGuidance = cleaned.domainGuidance
        } else {
            mustUseSources = []
            domainGuidance = ""
        }
    }

    var snapshot: ResearchInputSnapshot {
        ResearchInputSnapshot(
            mustUseSources: mustUseSources,
            domainGuidance: domainGuidance
        ).cleaned
    }

    func addBlankSource() {
        mustUseSources.append(MustUseSourceInput())
        save()
    }

    func removeSource(id: UUID) {
        mustUseSources.removeAll { $0.id == id }
        save()
    }

    func updateSource(_ source: MustUseSourceInput) {
        guard let index = mustUseSources.firstIndex(where: { $0.id == source.id }) else {
            return
        }
        mustUseSources[index] = source
        save()
    }

    func updateDomainGuidance(_ guidance: String) {
        domainGuidance = guidance
        save()
    }

    func save() {
        guard let data = try? encoder.encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
