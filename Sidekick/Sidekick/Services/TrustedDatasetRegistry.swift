import Foundation

nonisolated enum NoteClusterReadinessMode: String, Codable, Hashable {
    case trustedReady = "trusted_ready"
    case trustedPartial = "trusted_partial"
    case exploratoryReady = "exploratory_ready"
}

nonisolated struct PaperTaskSubmission {
    let taskID: String
    let selectedDatasetIDs: [String]
    let allowedDomains: [String]
    let registryVersion: Int
    let precomputedArtifacts: PaperArtifacts?
}

nonisolated struct TaskOutputProvenance: Codable {
    let usedDatasetIDs: [String]
    let accessedDomains: [String]
    let leftTrustedSet: Bool
    let externalSources: [String]
    let notes: String

    enum CodingKeys: String, CodingKey {
        case usedDatasetIDs = "used_dataset_ids"
        case accessedDomains = "accessed_domains"
        case leftTrustedSet = "left_trusted_set"
        case externalSources = "external_sources"
        case notes
    }
}

nonisolated enum TrustedDatasetEntryType: String, Codable, Sendable {
    case directSource = "direct_source"
    case discoveryCatalog = "discovery_catalog"
}

nonisolated enum TrustedDatasetStatus: String, Codable, Sendable {
    case trusted
    case candidate
    case deprecated
}

nonisolated enum TrustedDatasetTrustTier: String, Codable, Sendable {
    case official
    case curated
    case discovery
}

nonisolated enum TrustedDatasetSourceType: String, Codable, Sendable {
    case api
    case literatureAPI = "literature_api"
    case portal
    case download
    case catalog
    case huggingface
    case kaggle
}

nonisolated struct TrustedDatasetCatalog: Codable, Sendable {
    let version: Int
    let updatedAt: String?
    let entries: [TrustedDataset]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case entries
    }

    static let empty = TrustedDatasetCatalog(version: 0, updatedAt: nil, entries: [])
}

nonisolated struct TrustedDataset: Codable, Hashable, Sendable {
    let id: String
    let entryType: TrustedDatasetEntryType
    let status: TrustedDatasetStatus
    let trustTier: TrustedDatasetTrustTier
    let sourceType: TrustedDatasetSourceType
    let title: String
    let handle: String
    let domains: [String]
    let disciplines: [String]
    let keywords: [String]
    let useFor: String
    let avoidFor: String
    let accessHint: String
    let exampleAccess: String?
    let samplingHint: String?
    let citationHint: String
    let requiresAuth: Bool
    let priority: Double

    enum CodingKeys: String, CodingKey {
        case id
        case entryType = "entry_type"
        case status
        case trustTier = "trust_tier"
        case sourceType = "source_type"
        case title
        case handle
        case domains
        case disciplines
        case keywords
        case useFor = "use_for"
        case avoidFor = "avoid_for"
        case accessHint = "access_hint"
        case exampleAccess = "example_access"
        case samplingHint = "sampling_hint"
        case citationHint = "citation_hint"
        case requiresAuth = "requires_auth"
        case priority
    }

    var isTrustedDirectSource: Bool {
        entryType == .directSource && status == .trusted && !requiresAuth
    }

    var searchTerms: Set<String> {
        TrustedDatasetRegistry.tokenize(
            [
                title,
                disciplines.joined(separator: " "),
                keywords.joined(separator: " "),
                useFor,
                avoidFor
            ].joined(separator: " ")
        )
    }

    func assessmentLine() -> String {
        let disciplinesText = disciplines.prefix(3).joined(separator: ", ")
        return "[\(id)] \(title) | disciplines: \(disciplinesText) | use: \(useFor.compactPromptText(limit: 84)) | avoid: \(avoidFor.compactPromptText(limit: 68))"
    }

    func taskLine() -> String {
        let disciplinesText = disciplines.prefix(3).joined(separator: ", ")
        let domainsText = domains.prefix(4).joined(separator: ", ")
        let exampleText: String
        if let exampleAccess, !exampleAccess.isEmpty {
            exampleText = " | example: \(exampleAccess.compactPromptText(limit: 88))"
        } else {
            exampleText = ""
        }
        let samplingText: String
        if let samplingHint, !samplingHint.isEmpty {
            samplingText = " | sample: \(samplingHint.compactPromptText(limit: 76))"
        } else {
            samplingText = ""
        }

        return "[\(id)] \(title) | disciplines: \(disciplinesText) | use: \(useFor.compactPromptText(limit: 90)) | avoid: \(avoidFor.compactPromptText(limit: 70)) | access: \(accessHint.compactPromptText(limit: 92))\(samplingText) | domains: \(domainsText)\(exampleText)"
    }
}

actor TrustedDatasetRegistry {
    static let defaultRemoteURL = URL(string: "https://raw.githubusercontent.com/vineet-reddy/sidekick/main/Sidekick/Sidekick/Resources/trusted_datasets.json")

    private let session: URLSession
    private let remoteURL: URL?
    private var catalog: TrustedDatasetCatalog

    init(session: URLSession = .shared, remoteURL: URL? = TrustedDatasetRegistry.defaultRemoteURL) {
        self.session = session
        self.remoteURL = remoteURL
        catalog = Self.loadInitialCatalog()
    }

    func registryVersion() -> Int {
        catalog.version
    }

    func refreshIfNeeded(force: Bool = false) async {
        guard let remoteURL else {
            return
        }

        let cacheURL = Self.cacheFileURL()
        if !force,
           let cacheURL,
           let modifiedAt = Self.modificationDate(for: cacheURL),
           Date().timeIntervalSince(modifiedAt) < 12 * 60 * 60 {
            return
        }

        do {
            let (data, response) = try await session.data(from: remoteURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ..< 300).contains(httpResponse.statusCode) else {
                return
            }

            let decoded = try JSONDecoder().decode(TrustedDatasetCatalog.self, from: data)
            guard !decoded.entries.isEmpty else {
                return
            }

            catalog = decoded

            if let cacheURL {
                try Self.ensureParentDirectory(for: cacheURL)
                try data.write(to: cacheURL, options: .atomic)
            }
        } catch {
            print("[TrustedDatasets] Refresh skipped: \(error.localizedDescription)")
        }
    }

    func assessmentShortlist(noteTexts: [String], limit: Int = 10) async -> [TrustedDataset] {
        await refreshIfNeeded()
        return shortlist(noteTexts: noteTexts, limit: limit)
    }

    func taskDatasetSelection(datasetIDs: [String], noteTexts: [String], limit: Int = 4) async -> [TrustedDataset] {
        await refreshIfNeeded()

        let directSources = catalog.entries.filter(\.isTrustedDirectSource)
        let directByID = Dictionary(uniqueKeysWithValues: directSources.map { ($0.id, $0) })

        let resolved = datasetIDs.compactMap { directByID[$0] }
        if !resolved.isEmpty {
            // Once a run has selected explicit trusted dataset IDs, keep execution scoped to those cards.
            // Injecting shortlist extras here can silently widen domains or trigger unrelated local fallbacks.
            return Array(resolved.prefix(limit))
        }

        return shortlist(noteTexts: noteTexts, limit: limit)
    }

    static func allowedDomains(for datasets: [TrustedDataset]) -> [String] {
        Array(Set(datasets.flatMap(\.domains))).sorted()
    }

    static func tokenize(_ text: String) -> Set<String> {
        let parts = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)

        return Set(parts.compactMap { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, !Self.stopwords.contains(trimmed) else {
                return nil
            }

            return trimmed
        })
    }

    private func shortlist(noteTexts: [String], limit: Int) -> [TrustedDataset] {
        let terms = Self.tokenize(noteTexts.joined(separator: " "))
        let enrichedTerms = Self.enrichedTerms(from: terms)
        let directSources = catalog.entries.filter(\.isTrustedDirectSource)

        let scored = directSources.map { entry in
            (entry: entry, score: score(entry: entry, directTerms: terms, enrichedTerms: enrichedTerms))
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                if lhs.entry.priority == rhs.entry.priority {
                    return lhs.entry.title < rhs.entry.title
                }

                return lhs.entry.priority > rhs.entry.priority
            }

            return lhs.score > rhs.score
        }

        let positiveMatches = scored.filter { $0.score > $0.entry.priority + officialBoost(for: $0.entry) }
        let pool = positiveMatches.count >= min(3, limit) ? positiveMatches : scored

        return Array(pool.prefix(limit).map(\.entry))
    }

    private func score(
        entry: TrustedDataset,
        directTerms: Set<String>,
        enrichedTerms: Set<String>
    ) -> Double {
        guard !directTerms.isEmpty else {
            return entry.priority + officialBoost(for: entry)
        }

        let titleTerms = Self.tokenize(entry.title)
        let disciplineTerms = Self.tokenize(entry.disciplines.joined(separator: " "))
        let searchTerms = entry.searchTerms

        let directOverlap = Double(searchTerms.intersection(directTerms).count)
        let enrichedOverlap = Double(searchTerms.intersection(enrichedTerms).count)
        let titleOverlap = Double(titleTerms.intersection(directTerms).count)
        let disciplineOverlap = Double(disciplineTerms.intersection(enrichedTerms).count)
        let expandedOnlyOverlap = max(0, enrichedOverlap - directOverlap)

        return entry.priority
            + officialBoost(for: entry)
            + (directOverlap * 2.6)
            + (expandedOnlyOverlap * 1.3)
            + (titleOverlap * 1.4)
            + (disciplineOverlap * 1.1)
    }

    private func officialBoost(for entry: TrustedDataset) -> Double {
        switch entry.trustTier {
        case .official:
            return 0.35
        case .curated:
            return 0.15
        case .discovery:
            return 0.05
        }
    }

    private static func loadInitialCatalog() -> TrustedDatasetCatalog {
        if let cached = loadCatalog(from: cacheFileURL()) {
            return cached
        }

        if let bundled = loadCatalog(from: Bundle.main.url(forResource: "trusted_datasets", withExtension: "json")) {
            return bundled
        }

        print("[TrustedDatasets] Missing bundled registry. Falling back to an empty catalog.")
        return .empty
    }

    private static func loadCatalog(from url: URL?) -> TrustedDatasetCatalog? {
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TrustedDatasetCatalog.self, from: data) else {
            return nil
        }

        return decoded
    }

    private static func cacheFileURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("TrustedDatasets", isDirectory: true)
            .appendingPathComponent("trusted_datasets.json")
    }

    private static func ensureParentDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private static func modificationDate(for url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private static func enrichedTerms(from terms: Set<String>) -> Set<String> {
        var expanded = terms

        for term in terms {
            guard let additions = termExpansions[term] else {
                continue
            }

            expanded.formUnion(additions)
        }

        return expanded
    }

    private static let termExpansions: [String: Set<String>] = [
        "glioblastoma": ["gbm", "glioma", "oncology", "tumor", "cancer", "survival", "mutation", "expression", "tcga"],
        "gbm": ["glioblastoma", "glioma", "oncology", "tumor", "cancer", "survival", "tcga"],
        "glioma": ["glioblastoma", "gbm", "oncology", "tumor", "cancer", "survival"],
        "neurosurgery": ["brain", "oncology", "clinical", "glioblastoma", "neuroscience"],
        "neurosurgeon": ["brain", "oncology", "clinical", "glioblastoma", "neuroscience"],
        "neuroscience": ["brain", "neuron", "glia", "cortex", "electrophysiology", "imaging", "atlas"],
        "neural": ["brain", "neuron", "glia", "neuroscience"],
        "brain": ["neuroscience", "neuron", "glia", "cortex", "atlas"],
        "neuron": ["neuroscience", "brain", "electrophysiology", "morphology"],
        "glia": ["astrocyte", "brain", "neuroscience", "transcriptomics"],
        "astrocyte": ["glia", "brain", "single", "cell", "transcriptomics"],
        "electrophysiology": ["neurophysiology", "spike", "nwb", "neuropixels", "dandiset"],
        "neuropixels": ["electrophysiology", "neurophysiology", "spike", "brain"],
        "fmri": ["brain", "neuroscience", "imaging"],
        "genomics": ["gene", "expression", "mutation", "cohort", "transcriptomics"],
        "transcriptomics": ["expression", "gene", "rna", "scrna", "single", "cell"],
        "scrna": ["single", "cell", "transcriptomics", "atlas", "expression"],
        "singlecell": ["single", "cell", "transcriptomics", "atlas", "expression"],
        "proteomics": ["protein", "uniprot", "pathway", "biomarker"],
        "astrophysics": ["astronomy", "telescope", "spectra", "photometry", "galaxy", "exoplanet", "stellar"],
        "astronomy": ["astrophysics", "telescope", "spectra", "photometry", "galaxy", "exoplanet", "stellar"],
        "jwst": ["mast", "telescope", "infrared", "spectra"],
        "hubble": ["mast", "telescope", "imaging", "catalog"],
        "tess": ["exoplanet", "transit", "photometry", "stellar"],
        "exoplanet": ["planet", "transit", "tess", "kepler", "stellar", "archive"],
        "galaxy": ["survey", "spectra", "photometry", "catalog", "stellar"],
        "stellar": ["galaxy", "spectra", "photometry", "telescope"]
    ]

    private static let stopwords: Set<String> = [
        "about", "after", "all", "also", "and", "any", "are", "because", "been", "before",
        "between", "both", "but", "can", "could", "data", "does", "doing", "each", "for",
        "from", "have", "idea", "ideas", "into", "just", "like", "make", "more", "most",
        "much", "need", "notes", "not", "our", "over", "paper", "papers", "really", "should",
        "some", "than", "that", "the", "their", "them", "there", "these", "they", "this",
        "those", "use", "used", "using", "very", "want", "what", "when", "where", "which",
        "with", "would", "write", "your"
    ]
}

private extension String {
    nonisolated func compactPromptText(limit: Int) -> String {
        let collapsed = components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard collapsed.count > limit, limit > 3 else {
            return collapsed
        }

        return String(collapsed.prefix(limit - 3)) + "..."
    }
}
