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

nonisolated enum TrustedDatasetSupportTier: String, Codable, Sendable {
    case supported
    case experimental
    case disabled
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
    let supportTier: TrustedDatasetSupportTier?
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
        case supportTier = "support_tier"
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
        entryType == .directSource
            && status == .trusted
            && !requiresAuth
            && resolvedSupportTier != .disabled
    }

    var resolvedSupportTier: TrustedDatasetSupportTier {
        supportTier ?? Self.defaultSupportTier(
            for: id,
            entryType: entryType,
            status: status
        )
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
        return "[\(id)] \(title) | reliability: \(resolvedSupportTier.rawValue) | disciplines: \(disciplinesText) | use: \(useFor.compactPromptText(limit: 84)) | avoid: \(avoidFor.compactPromptText(limit: 68))"
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

        return "[\(id)] \(title) | reliability: \(resolvedSupportTier.rawValue) | disciplines: \(disciplinesText) | use: \(useFor.compactPromptText(limit: 90)) | avoid: \(avoidFor.compactPromptText(limit: 70)) | access: \(accessHint.compactPromptText(limit: 92))\(samplingText) | domains: \(domainsText)\(exampleText)"
    }

    private static func defaultSupportTier(
        for id: String,
        entryType: TrustedDatasetEntryType,
        status: TrustedDatasetStatus
    ) -> TrustedDatasetSupportTier {
        guard entryType == .directSource, status == .trusted else {
            return .disabled
        }

        switch id {
        case "brfss-2015-github-mirror", "cbioportal-public", "nci-gdc-api", "mast-observations":
            return .supported
        case "cellxgene-discover":
            return .disabled
        default:
            return .experimental
        }
    }
}

nonisolated struct TrustedSourceSelection: Sendable {
    let datasets: [TrustedDataset]
    let primaryDataset: TrustedDataset?
    let supportTier: TrustedDatasetSupportTier
    let isAutoStartEligible: Bool
    let allowsExploratoryAutoStart: Bool
    let message: String?
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

    func sourceSelection(
        datasetIDs: [String],
        noteTexts: [String],
        limit: Int = 4
    ) async -> TrustedSourceSelection {
        await refreshIfNeeded()
        return selectSource(datasetIDs: datasetIDs, noteTexts: noteTexts, limit: limit)
    }

    func taskDatasetSelection(datasetIDs: [String], noteTexts: [String], limit: Int = 4) async -> [TrustedDataset] {
        await refreshIfNeeded()

        let runtimeEntries = catalog.entries.filter { entry in
            guard entry.status == .trusted, !entry.requiresAuth else {
                return false
            }

            if entry.entryType == .directSource {
                return entry.resolvedSupportTier != .disabled
            }

            return entry.entryType == .discoveryCatalog
        }
        let runtimeByID = Dictionary(uniqueKeysWithValues: runtimeEntries.map { ($0.id, $0) })

        let resolved = datasetIDs.compactMap { runtimeByID[$0] }
        if !resolved.isEmpty {
            // Once a stage has selected explicit source-family cards, keep that stage scoped to those cards.
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

    static func semanticSimilarityScore(
        sourceTerms: Set<String>,
        candidateText: String,
        exactWeight: Double = 1,
        fuzzyWeight: Double = 0.65
    ) -> Double {
        semanticSimilarityScore(
            sourceTerms: sourceTerms,
            candidateTerms: tokenize(candidateText),
            exactWeight: exactWeight,
            fuzzyWeight: fuzzyWeight
        )
    }

    static func semanticSimilarityScore(
        sourceTerms: Set<String>,
        candidateTerms: Set<String>,
        exactWeight: Double = 1,
        fuzzyWeight: Double = 0.65
    ) -> Double {
        let overlap = semanticOverlapBreakdown(sourceTerms: sourceTerms, candidateTerms: candidateTerms)
        return (Double(overlap.exact) * exactWeight) + (Double(overlap.fuzzy) * fuzzyWeight)
    }

    private func shortlist(noteTexts: [String], limit: Int) -> [TrustedDataset] {
        let terms = Self.tokenize(noteTexts.joined(separator: " "))
        let enrichedTerms = Self.enrichedTerms(from: terms)
        let directSources = catalog.entries.filter(\.isTrustedDirectSource)

        let scored = directSources.map { entry in
            scoredEntry(
                entry: entry,
                directTerms: terms,
                enrichedTerms: enrichedTerms,
                hintedIDs: []
            )
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

        let positiveMatches = scored.filter { $0.fitScore > minimumFitScore(for: $0.entry, hinted: false) }
        let pool = positiveMatches.count >= min(3, limit) ? positiveMatches : scored

        return Array(pool.prefix(limit).map(\.entry))
    }

    private func scoredEntry(
        entry: TrustedDataset,
        directTerms: Set<String>,
        enrichedTerms: Set<String>,
        hintedIDs: Set<String>
    ) -> (entry: TrustedDataset, score: Double, fitScore: Double, isHinted: Bool) {
        let fit = fitScore(
            entry: entry,
            directTerms: directTerms,
            enrichedTerms: enrichedTerms
        )
        let isHinted = hintedIDs.contains(entry.id)

        return (
            entry: entry,
            score: entry.priority + reliabilityBoost(for: entry) + hintBoost(for: entry, isHinted: isHinted) + fit,
            fitScore: fit,
            isHinted: isHinted
        )
    }

    private func fitScore(
        entry: TrustedDataset,
        directTerms: Set<String>,
        enrichedTerms: Set<String>
    ) -> Double {
        guard !directTerms.isEmpty else {
            return 0
        }

        let titleTerms = Self.tokenize(entry.title)
        let disciplineTerms = Self.tokenize(entry.disciplines.joined(separator: " "))
        let searchTerms = entry.searchTerms
        let expansionOnlyTerms = enrichedTerms.subtracting(directTerms)

        let directSearchScore = Self.semanticSimilarityScore(
            sourceTerms: directTerms,
            candidateTerms: searchTerms,
            exactWeight: 2.6,
            fuzzyWeight: 1.55
        )
        let expansionSearchScore = Self.semanticSimilarityScore(
            sourceTerms: expansionOnlyTerms,
            candidateTerms: searchTerms,
            exactWeight: 1.3,
            fuzzyWeight: 0.8
        )
        let titleScore = Self.semanticSimilarityScore(
            sourceTerms: directTerms,
            candidateTerms: titleTerms,
            exactWeight: 1.4,
            fuzzyWeight: 0.85
        )
        let disciplineScore = Self.semanticSimilarityScore(
            sourceTerms: enrichedTerms,
            candidateTerms: disciplineTerms,
            exactWeight: 1.1,
            fuzzyWeight: 0.7
        )

        return directSearchScore
            + expansionSearchScore
            + titleScore
            + disciplineScore
    }

    private func selectSource(
        datasetIDs: [String],
        noteTexts: [String],
        limit: Int
    ) -> TrustedSourceSelection {
        let terms = Self.tokenize(noteTexts.joined(separator: " "))
        let enrichedTerms = Self.enrichedTerms(from: terms)
        let directSources = catalog.entries.filter(\.isTrustedDirectSource)
        let hintedIDs = Set(datasetIDs)

        let scored = directSources
            .map { entry in
                scoredEntry(
                    entry: entry,
                    directTerms: terms,
                    enrichedTerms: enrichedTerms,
                    hintedIDs: hintedIDs
                )
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

        guard let best = scored.first else {
            let exploratoryCatalogs = exploratoryCatalogSelection(
                directTerms: terms,
                enrichedTerms: enrichedTerms,
                limit: limit
            )
            if !exploratoryCatalogs.isEmpty {
                return TrustedSourceSelection(
                    datasets: exploratoryCatalogs,
                    primaryDataset: exploratoryCatalogs.first,
                    supportTier: .experimental,
                    isAutoStartEligible: false,
                    allowsExploratoryAutoStart: true,
                    message: "Exploratory paper queued. Sidekick will scout a few public source families and keep the first tractable one."
                )
            }

            return TrustedSourceSelection(
                datasets: [],
                primaryDataset: nil,
                supportTier: .disabled,
                isAutoStartEligible: false,
                allowsExploratoryAutoStart: false,
                message: "Queued until Sidekick finds a reliable source family for these notes."
            )
        }

        let minimumFit = minimumFitScore(for: best.entry, hinted: best.isHinted)
        guard best.fitScore >= minimumFit else {
            let exploratoryCatalogs = exploratoryCatalogSelection(
                directTerms: terms,
                enrichedTerms: enrichedTerms,
                limit: limit
            )
            if !exploratoryCatalogs.isEmpty {
                return TrustedSourceSelection(
                    datasets: exploratoryCatalogs,
                    primaryDataset: exploratoryCatalogs.first,
                    supportTier: .experimental,
                    isAutoStartEligible: false,
                    allowsExploratoryAutoStart: true,
                    message: "Exploratory paper queued. Sidekick could not find a strong approved fit, so it will scout a few public source families instead of waiting indefinitely."
                )
            }

            return TrustedSourceSelection(
                datasets: [best.entry],
                primaryDataset: best.entry,
                supportTier: best.entry.resolvedSupportTier,
                isAutoStartEligible: false,
                allowsExploratoryAutoStart: false,
                message: "Queued until Sidekick finds a stronger reliable source-family fit for this paper."
            )
        }

        let selected = Array(
            scored
                .filter { candidate in
                    candidate.entry.id == best.entry.id
                        || candidate.fitScore >= max(best.fitScore * 0.72, minimumDiscoveryCandidateFitScore(for: candidate.entry))
                        || (candidate.isHinted && candidate.fitScore >= 0.95)
                }
                .prefix(max(1, limit))
                .map(\.entry)
        )

        let tier = best.entry.resolvedSupportTier
        let message: String?
        let isAutoStartEligible: Bool

        switch tier {
        case .supported:
            if selected.count > 1 {
                message = "Research queued. Sidekick will compare the best-fit source families before inspecting data."
            } else {
                message = "Research queued. Sidekick will confirm the best-fit source family before inspecting data."
            }
            isAutoStartEligible = true
        case .experimental:
            message = "Exploratory paper queued. Sidekick will try the best-fit public source family first, then pivot quickly if it is too thin or blocked."
            isAutoStartEligible = false
        case .disabled:
            let exploratoryCatalogs = exploratoryCatalogSelection(
                directTerms: terms,
                enrichedTerms: enrichedTerms,
                limit: limit
            )
            if !exploratoryCatalogs.isEmpty {
                return TrustedSourceSelection(
                    datasets: exploratoryCatalogs,
                    primaryDataset: exploratoryCatalogs.first,
                    supportTier: .experimental,
                    isAutoStartEligible: false,
                    allowsExploratoryAutoStart: true,
                    message: "Exploratory paper queued. The direct source fit is disabled, so Sidekick will scout alternative public sources instead."
                )
            }

            message = "This source family is disabled for automatic paper generation."
            isAutoStartEligible = false
        }

        return TrustedSourceSelection(
            datasets: selected,
            primaryDataset: best.entry,
            supportTier: tier,
            isAutoStartEligible: isAutoStartEligible,
            allowsExploratoryAutoStart: tier == .experimental,
            message: message
        )
    }

    private func exploratoryCatalogSelection(
        directTerms: Set<String>,
        enrichedTerms: Set<String>,
        limit: Int
    ) -> [TrustedDataset] {
        let catalogs = catalog.entries.filter { entry in
            entry.entryType == .discoveryCatalog
                && entry.status == .trusted
                && !entry.requiresAuth
        }

        let scored = catalogs
            .map { entry in
                scoredEntry(
                    entry: entry,
                    directTerms: directTerms,
                    enrichedTerms: enrichedTerms,
                    hintedIDs: []
                )
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

        let positiveMatches = scored.filter { $0.fitScore >= 0.6 }
        let pool = positiveMatches.isEmpty ? scored : positiveMatches
        return Array(pool.prefix(max(1, min(limit, 2))).map(\.entry))
    }

    private func reliabilityBoost(for entry: TrustedDataset) -> Double {
        officialBoost(for: entry) + supportTierBoost(for: entry.resolvedSupportTier)
    }

    private func hintBoost(for entry: TrustedDataset, isHinted: Bool) -> Double {
        guard isHinted else {
            return 0
        }

        switch entry.resolvedSupportTier {
        case .supported:
            return 0.55
        case .experimental:
            return 0.3
        case .disabled:
            return 0
        }
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

    private func supportTierBoost(for tier: TrustedDatasetSupportTier) -> Double {
        switch tier {
        case .supported:
            return 1.15
        case .experimental:
            return 0.0
        case .disabled:
            return -50
        }
    }

    private func minimumFitScore(for entry: TrustedDataset, hinted: Bool) -> Double {
        if hinted {
            return entry.resolvedSupportTier == .supported ? 1.0 : 0.85
        }

        switch entry.resolvedSupportTier {
        case .supported:
            return 1.3
        case .experimental:
            return 1.7
        case .disabled:
            return .greatestFiniteMagnitude
        }
    }

    private func minimumDiscoveryCandidateFitScore(for entry: TrustedDataset) -> Double {
        switch entry.resolvedSupportTier {
        case .supported:
            return 1.0
        case .experimental:
            return 1.35
        case .disabled:
            return .greatestFiniteMagnitude
        }
    }

    private static func loadInitialCatalog() -> TrustedDatasetCatalog {
        let cached = loadCatalog(from: cacheFileURL())
        let bundled = loadCatalog(from: Bundle.main.url(forResource: "trusted_datasets", withExtension: "json"))

        if let cached, let bundled {
            return bundled.version >= cached.version ? bundled : cached
        }

        if let bundled {
            return bundled
        }

        if let cached {
            return cached
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

    private static func semanticOverlapBreakdown(
        sourceTerms: Set<String>,
        candidateTerms: Set<String>
    ) -> (exact: Int, fuzzy: Int) {
        guard !sourceTerms.isEmpty, !candidateTerms.isEmpty else {
            return (exact: 0, fuzzy: 0)
        }

        var unmatchedCandidates = Array(candidateTerms).sorted()
        var exact = 0
        var fuzzy = 0

        for sourceTerm in sourceTerms.sorted() {
            if let exactIndex = unmatchedCandidates.firstIndex(of: sourceTerm) {
                unmatchedCandidates.remove(at: exactIndex)
                exact += 1
                continue
            }

            guard let fuzzyIndex = unmatchedCandidates.firstIndex(where: {
                semanticTokensLikelyMatch(sourceTerm, $0)
            }) else {
                continue
            }

            unmatchedCandidates.remove(at: fuzzyIndex)
            fuzzy += 1
        }

        return (exact: exact, fuzzy: fuzzy)
    }

    private static func semanticTokensLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs != rhs else {
            return true
        }

        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        guard shorter.count >= 4 else {
            return false
        }

        if longer.hasPrefix(shorter), longer.count - shorter.count <= 6 {
            return true
        }

        let maxDistance = shorter.count >= 8 ? 2 : 1
        return boundedEditDistance(lhs, rhs, maxDistance: maxDistance) != nil
    }

    private static func boundedEditDistance(
        _ lhs: String,
        _ rhs: String,
        maxDistance: Int
    ) -> Int? {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        guard abs(lhsCharacters.count - rhsCharacters.count) <= maxDistance else {
            return nil
        }

        var previousRow = Array(0 ... rhsCharacters.count)

        for (lhsIndex, lhsCharacter) in lhsCharacters.enumerated() {
            var currentRow = Array(repeating: 0, count: rhsCharacters.count + 1)
            currentRow[0] = lhsIndex + 1
            var rowMinimum = currentRow[0]

            for (rhsIndex, rhsCharacter) in rhsCharacters.enumerated() {
                let substitutionCost = lhsCharacter == rhsCharacter ? 0 : 1
                currentRow[rhsIndex + 1] = min(
                    previousRow[rhsIndex + 1] + 1,
                    min(
                        currentRow[rhsIndex] + 1,
                        previousRow[rhsIndex] + substitutionCost
                    )
                )
                rowMinimum = min(rowMinimum, currentRow[rhsIndex + 1])
            }

            guard rowMinimum <= maxDistance else {
                return nil
            }

            previousRow = currentRow
        }

        let distance = previousRow[rhsCharacters.count]
        return distance <= maxDistance ? distance : nil
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
