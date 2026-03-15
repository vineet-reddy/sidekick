import Foundation
import zlib

nonisolated enum ResearchStageFallbackKind: String, Codable {
    case gbmCBioPortal = "gbm_cbioportal"
    case mastObservations = "mast_observations"
    case cellxgeneAtlas = "cellxgene_atlas"

    var prefersPrimaryExecution: Bool {
        switch self {
        case .gbmCBioPortal, .mastObservations:
            return true
        case .cellxgeneAtlas:
            return false
        }
    }
}

nonisolated struct ResearchStageFallbackInput {
    let kind: ResearchStageFallbackKind
    let providerLabel: String
    let promptJSON: String
}

actor ResearchStageFallbackService {
    enum FallbackError: LocalizedError {
        case invalidResponse
        case unsupported
        case httpFailure(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The public dataset fallback returned an invalid response."
            case .unsupported:
                return "No staged fallback is available for this research slice yet."
            case let .httpFailure(statusCode, message):
                return "Public dataset fetch failed with HTTP \(statusCode): \(message)"
            }
        }
    }

    private let session: URLSession
    private var cachedGBMBundle: GBMCBioPortalBundle?
    private var cachedMastBundle: MASTObservationBundle?
    private var cachedCellxgeneCollections: [CellxgeneCollectionSummary]?
    private var cachedCellxgeneBundles: [String: CellxgeneAtlasBundle] = [:]
    private var cachedCellxgeneSelections: [String: String] = [:]
    private var cachedCellxgeneSelectionMisses = Set<String>()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func supportsFallback(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) async -> Bool {
        do {
            return try await fallbackKindForRouting(
                datasetIDs: datasetIDs,
                noteTexts: noteTexts,
                theme: theme
            ) != nil
        } catch {
            print("[ResearchFallback] support check failed: \(error.localizedDescription)")
            return false
        }
    }

    func prefersPrimaryFallback(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) async -> Bool {
        do {
            guard let kind = try await fallbackKindForRouting(
                datasetIDs: datasetIDs,
                noteTexts: noteTexts,
                theme: theme
            ) else {
                return false
            }

            return kind.prefersPrimaryExecution
        } catch {
            print("[ResearchFallback] primary-preference check failed: \(error.localizedDescription)")
            return false
        }
    }

    func inspectionInput(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) async throws -> ResearchStageFallbackInput? {
        switch try await fallbackKindForInput(datasetIDs: datasetIDs, noteTexts: noteTexts, theme: theme) {
        case .gbmCBioPortal:
            let bundle = try await gbmBundle()
            let inspection = GBMCBioPortalInspectionInput(from: bundle, selectedDatasetIDs: datasetIDs)
            return ResearchStageFallbackInput(
                kind: .gbmCBioPortal,
                providerLabel: "cBioPortal TCGA-GBM public cohort",
                promptJSON: try encodeCompactJSON(inspection)
            )

        case .mastObservations:
            let inspection = try await mastInspectionInput(selectedDatasetIDs: datasetIDs)
            return ResearchStageFallbackInput(
                kind: .mastObservations,
                providerLabel: "MAST HST/WFC3-UVIS observation metadata",
                promptJSON: try encodeCompactJSON(inspection)
            )

        case .cellxgeneAtlas:
            guard let collectionID = try await preferredCellxgeneCollectionID(noteTexts: noteTexts, theme: theme) else {
                return nil
            }

            let bundle = try await cellxgeneBundle(collectionID: collectionID)
            let inspection = CellxgeneAtlasInspectionInput(from: bundle, selectedDatasetIDs: datasetIDs)
            return ResearchStageFallbackInput(
                kind: .cellxgeneAtlas,
                providerLabel: "CZ CELLxGENE Discover collection \(bundle.collectionID)",
                promptJSON: try encodeCompactJSON(inspection)
            )

        case nil:
            return nil
        }
    }

    func analysisInput(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) async throws -> ResearchStageFallbackInput? {
        switch try await fallbackKindForInput(datasetIDs: datasetIDs, noteTexts: noteTexts, theme: theme) {
        case .gbmCBioPortal:
            let bundle = try await gbmBundle()
            let analysis = GBMCBioPortalAnalysisInput(from: bundle, selectedDatasetIDs: datasetIDs)
            return ResearchStageFallbackInput(
                kind: .gbmCBioPortal,
                providerLabel: "cBioPortal TCGA-GBM public cohort",
                promptJSON: try encodeCompactJSON(analysis)
            )

        case .mastObservations:
            let bundle = try await mastBundle()
            let promptText = try mastBundledAnalysisPromptText(
                from: bundle,
                selectedDatasetIDs: datasetIDs
            )
            return ResearchStageFallbackInput(
                kind: .mastObservations,
                providerLabel: "MAST HST/WFC3-UVIS observation metadata",
                promptJSON: promptText
            )

        case .cellxgeneAtlas:
            guard let collectionID = try await preferredCellxgeneCollectionID(noteTexts: noteTexts, theme: theme) else {
                return nil
            }

            let bundle = try await cellxgeneBundle(collectionID: collectionID)
            let analysis = CellxgeneAtlasAnalysisInput(from: bundle, selectedDatasetIDs: datasetIDs)
            return ResearchStageFallbackInput(
                kind: .cellxgeneAtlas,
                providerLabel: "CZ CELLxGENE Discover collection \(bundle.collectionID)",
                promptJSON: try encodeCompactJSON(analysis)
            )

        case nil:
            return nil
        }
    }

    func bundledAnalysisInput(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) async throws -> ResearchStageFallbackInput? {
        switch try await fallbackKindForInput(datasetIDs: datasetIDs, noteTexts: noteTexts, theme: theme) {
        case .gbmCBioPortal:
            let bundle = try await gbmBundle()
            let metadata = GBMCBioPortalBundledAnalysisMetadata(from: bundle, selectedDatasetIDs: datasetIDs)
            let csv = compactCSV(from: bundle.rows)
            let compressedCSV = try compressedBase64Zlib(csv)
            let promptText = """
            Metadata JSON:
            \(try encodeCompactJSON(metadata))

            Cohort CSV encoding: base64(zlib(utf8(csv)))
            Cohort CSV payload:
            \(compressedCSV)
            """
            print(
                "[ResearchFallback] bundledAnalysis raw_csv_chars=\(csv.count) " +
                    "compressed_chars=\(compressedCSV.count) prompt_chars=\(promptText.count)"
            )

            return ResearchStageFallbackInput(
                kind: .gbmCBioPortal,
                providerLabel: "cBioPortal TCGA-GBM public cohort",
                promptJSON: promptText
            )

        case .mastObservations:
            let bundle = try await mastBundle()
            let promptText = try mastBundledAnalysisPromptText(
                from: bundle,
                selectedDatasetIDs: datasetIDs
            )
            return ResearchStageFallbackInput(
                kind: .mastObservations,
                providerLabel: "MAST HST/WFC3-UVIS observation metadata",
                promptJSON: promptText
            )

        case .cellxgeneAtlas:
            guard let collectionID = try await preferredCellxgeneCollectionID(noteTexts: noteTexts, theme: theme) else {
                return nil
            }

            let bundle = try await cellxgeneBundle(collectionID: collectionID)
            let analysis = CellxgeneAtlasAnalysisInput(from: bundle, selectedDatasetIDs: datasetIDs)
            return ResearchStageFallbackInput(
                kind: .cellxgeneAtlas,
                providerLabel: "CZ CELLxGENE Discover collection \(bundle.collectionID)",
                promptJSON: try encodeCompactJSON(analysis)
            )

        case nil:
            return nil
        }
    }

    private func fallbackKindForRouting(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) async throws -> ResearchStageFallbackKind? {
        if supportsGlioblastomaCBioPortalBundle(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            theme: theme
        ) {
            return .gbmCBioPortal
        }

        if supportsMASTObservationBundle(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            theme: theme
        ) {
            return .mastObservations
        }

        if supportsCellxgeneAtlasCandidate(datasetIDs: datasetIDs) {
            return .cellxgeneAtlas
        }

        return nil
    }

    private func fallbackKindForInput(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) async throws -> ResearchStageFallbackKind? {
        if supportsGlioblastomaCBioPortalBundle(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            theme: theme
        ) {
            return .gbmCBioPortal
        }

        if supportsMASTObservationBundle(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            theme: theme
        ) {
            return .mastObservations
        }

        if supportsCellxgeneAtlasCandidate(datasetIDs: datasetIDs),
           try await preferredCellxgeneCollectionID(noteTexts: noteTexts, theme: theme) != nil {
            return .cellxgeneAtlas
        }

        return nil
    }

    private func supportsGlioblastomaCBioPortalBundle(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) -> Bool {
        let selectedIDs = Set(datasetIDs)
        guard !selectedIDs.isDisjoint(with: ["cbioportal-public", "nci-gdc-api"]) else {
            return false
        }

        let noteTerms = TrustedDatasetRegistry.tokenize(([theme] + noteTexts).joined(separator: " "))
        let scopeText = """
        glioblastoma gbm neuro oncology brain tumor tcga cohort survival overall survival age sex \
        idh1 egfr mgmt mutation methylation clinical molecular public cohort
        """

        return TrustedDatasetRegistry.semanticSimilarityScore(
            sourceTerms: noteTerms,
            candidateText: scopeText
        ) >= 2.5
    }

    private func supportsMASTObservationBundle(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) -> Bool {
        let selectedIDs = Set(datasetIDs)
        guard selectedIDs.contains("mast-observations") else {
            return false
        }

        let noteTerms = TrustedDatasetRegistry.tokenize(([theme] + noteTexts).joined(separator: " "))
        let scopeText = """
        mast hubble hst wfc3 uvis observation metadata exposure time filter optical ultraviolet \
        proposal target same instrument archive table
        """
        let score = TrustedDatasetRegistry.semanticSimilarityScore(
            sourceTerms: noteTerms,
            candidateText: scopeText
        )

        return score >= 2 || selectedIDs == Set(["mast-observations"])
    }

    private func supportsCellxgeneAtlasCandidate(datasetIDs: [String]) -> Bool {
        Set(datasetIDs).contains("cellxgene-discover")
    }

    private var mastUVFilters: [String] {
        ["F225W", "F275W", "F336W"]
    }

    private var mastOpticalFilters: [String] {
        ["F438W", "F555W", "F606W", "F814W"]
    }

    private func mastBundledAnalysisPromptText(
        from bundle: MASTObservationBundle,
        selectedDatasetIDs: [String]
    ) throws -> String {
        let metadata = MASTObservationAnalysisInput(from: bundle, selectedDatasetIDs: selectedDatasetIDs)
        let csv = compactCSV(from: bundle.proposalSummaries)
        let compressedCSV = try compressedBase64Zlib(csv)
        let promptText = """
        Metadata JSON:
        \(try encodeCompactJSON(metadata))

        Proposal-filter summary CSV encoding: base64(zlib(utf8(csv)))
        Proposal-filter summary CSV payload:
        \(compressedCSV)
        """
        print(
            "[ResearchFallback] mast bundledAnalysis raw_csv_chars=\(csv.count) " +
                "compressed_chars=\(compressedCSV.count) prompt_chars=\(promptText.count)"
        )
        return promptText
    }

    private func mastInspectionInput(
        selectedDatasetIDs: [String]
    ) async throws -> MASTObservationInspectionInput {
        let selectedFilters = mastUVFilters + mastOpticalFilters
        let previewPageSize = 8
        let previewPages = try await mastObservationPreviewPages(
            selectedFilters: selectedFilters,
            pageSize: previewPageSize
        )
        let previewPagesByFilter = Dictionary(uniqueKeysWithValues: previewPages)
        let previewRowsByFilter = Dictionary(uniqueKeysWithValues: previewPages.map { filterName, page in
            let rows = page.data
                .compactMap(mastObservationRow(from:))
                .filter { row in
                    let rights = row.dataRights?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
                    return rights.isEmpty || rights == "PUBLIC"
                }
            return (filterName, rows)
        })
        let previewRows = selectedFilters
            .flatMap { previewRowsByFilter[$0] ?? [] }
        let previewFilterCoverage = selectedFilters.compactMap { filterName -> MASTFilterCoverage? in
            guard let page = previewPagesByFilter[filterName] else {
                return nil
            }

            let rows = previewRowsByFilter[filterName] ?? []
            let filterBand = rows.first?.filterBand
                ?? (mastUVFilters.contains(filterName) ? "uv" : (mastOpticalFilters.contains(filterName) ? "optical" : "other"))
            return MASTFilterCoverage(
                filterName: filterName,
                filterBand: filterBand,
                observationCount: page.paging.rowsFiltered,
                proposalCount: Set(rows.map(\.proposalID)).count,
                targetCount: Set(rows.map(\.targetName)).count,
                medianExposureSeconds: median(rows.map(\.exposureSeconds)),
                meanExposureSeconds: mean(rows.map(\.exposureSeconds))
            )
        }
        let exactObservationCount = previewPages.reduce(into: 0) { partialResult, entry in
            partialResult += entry.1.paging.rowsFiltered
        }

        return MASTObservationInspectionInput(
            selectedDatasetIDs: selectedDatasetIDs,
            observationCollection: "HST",
            instrumentName: "WFC3/UVIS",
            selectedFilters: selectedFilters,
            observationCount: exactObservationCount,
            previewProposalCount: Set(previewRows.map(\.proposalID)).count,
            previewTargetCount: Set(previewRows.map(\.targetName)).count,
            previewFilterCoverage: previewFilterCoverage,
            previewRows: Array(previewRows.prefix(12)),
            notes: [
                "This inspection bundle uses one small per-filter preview query per selected filter so task creation stays fast without issuing one giant multi-filter pull.",
                "observation_count is the exact sum of MAST paging row counts across the selected WFC3/UVIS filters.",
                "preview_proposal_count, preview_target_count, and the proposal or target subtotals inside preview_filter_coverage summarize only the returned preview sample; the full proposal-aware summary is fetched during the analysis bundle stage.",
                "No image products or pixel-level reductions are included in this inspection pass."
            ]
        )
    }

    private func mastBundle() async throws -> MASTObservationBundle {
        if let cachedMastBundle {
            return cachedMastBundle
        }

        let selectedFilters = mastUVFilters + mastOpticalFilters
        let pageSize = 10_000
        let rowsByFilter = try await mastObservationRowsByFilter(
            selectedFilters: selectedFilters,
            pageSize: pageSize
        )
        let allRows = selectedFilters
            .flatMap { rowsByFilter[$0] ?? [] }

        let publicRows = allRows.filter { row in
            let rights = row.dataRights?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
            return rights == "PUBLIC"
        }
        let selectedRows = publicRows.isEmpty ? allRows : publicRows

        let filterCoverage = Dictionary(grouping: selectedRows, by: \.filterName)
            .map { filterName, rows in
                MASTFilterCoverage(
                    filterName: filterName,
                    filterBand: rows.first?.filterBand ?? "other",
                    observationCount: rows.count,
                    proposalCount: Set(rows.map(\.proposalID)).count,
                    targetCount: Set(rows.map(\.targetName)).count,
                    medianExposureSeconds: median(rows.map(\.exposureSeconds)),
                    meanExposureSeconds: mean(rows.map(\.exposureSeconds))
                )
            }
            .sorted { lhs, rhs in
                if lhs.filterBand != rhs.filterBand {
                    return lhs.filterBand < rhs.filterBand
                }
                return lhs.filterName < rhs.filterName
            }

        let proposalSummaries = Dictionary(
            grouping: selectedRows,
            by: { row in
                "\(row.proposalID)\u{1F}|\u{1F}\(row.filterName)\u{1F}|\u{1F}\(row.filterBand)"
            }
        )
        .map { key, rows -> MASTProposalFilterSummary in
            let components = key.components(separatedBy: "\u{1F}|\u{1F}")
            let exposures = rows.map(\.exposureSeconds)
            let proposalID = components.indices.contains(0) ? components[0] : "unknown"
            let filterName = components.indices.contains(1) ? components[1] : (rows.first?.filterName ?? "")
            let filterBand = components.indices.contains(2) ? components[2] : (rows.first?.filterBand ?? "other")
            return MASTProposalFilterSummary(
                proposalID: proposalID,
                filterName: filterName,
                filterBand: filterBand,
                observationCount: rows.count,
                medianExposureSeconds: median(exposures),
                meanExposureSeconds: mean(exposures),
                minExposureSeconds: exposures.min() ?? 0,
                maxExposureSeconds: exposures.max() ?? 0,
                targetCount: Set(rows.map(\.targetName)).count
            )
        }
        .sorted { lhs, rhs in
            if lhs.filterBand != rhs.filterBand {
                return lhs.filterBand < rhs.filterBand
            }
            if lhs.filterName != rhs.filterName {
                return lhs.filterName < rhs.filterName
            }
            return lhs.proposalID < rhs.proposalID
        }

        var notes = [
            "This fallback uses public MAST observation metadata for HST/WFC3-UVIS only; it does not download image products or run pixel-level reductions.",
            "UV filters are defined here as \(mastUVFilters.joined(separator: ", ")); optical filters are defined here as \(mastOpticalFilters.joined(separator: ", ")).",
            "The proposal-filter summary table is derived from observation-level metadata so the analysis can compare UV and optical exposure times while partially accounting for proposal context."
        ]
        if !publicRows.isEmpty, publicRows.count != allRows.count {
            notes.append("The local bundle restricts the analysis to rows marked PUBLIC in the returned MAST metadata.")
        }

        let bundle = MASTObservationBundle(
            observationCollection: "HST",
            instrumentName: "WFC3/UVIS",
            selectedFilters: selectedFilters,
            retainedObservationCount: selectedRows.count,
            originalObservationCount: allRows.count,
            proposalCount: Set(selectedRows.map(\.proposalID)).count,
            targetCount: Set(selectedRows.map(\.targetName)).count,
            filterCoverage: filterCoverage,
            proposalSummaries: proposalSummaries,
            previewRows: Array(selectedRows.prefix(12)),
            notes: notes
        )

        cachedMastBundle = bundle
        return bundle
    }

    private func mastObservationPreviewPages(
        selectedFilters: [String],
        pageSize: Int
    ) async throws -> [(String, MASTFilteredResponse)] {
        let session = session
        return try await withThrowingTaskGroup(of: (String, MASTFilteredResponse).self) { group in
            for filterName in selectedFilters {
                group.addTask {
                    let page = try await Self.fetchMASTObservationPage(
                        page: 1,
                        pageSize: pageSize,
                        selectedFilters: [filterName],
                        session: session
                    )
                    return (filterName, page)
                }
            }

            var results: [(String, MASTFilteredResponse)] = []
            for try await result in group {
                results.append(result)
            }

            return results.sorted { lhs, rhs in
                guard let lhsIndex = selectedFilters.firstIndex(of: lhs.0),
                      let rhsIndex = selectedFilters.firstIndex(of: rhs.0) else {
                    return lhs.0 < rhs.0
                }
                return lhsIndex < rhsIndex
            }
        }
    }

    private func mastObservationRowsByFilter(
        selectedFilters: [String],
        pageSize: Int
    ) async throws -> [String: [MASTObservationRow]] {
        let session = session
        let rawResults = try await withThrowingTaskGroup(of: (String, [MASTObservationAPIRecord]).self) { group in
            for filterName in selectedFilters {
                group.addTask {
                    let records = try await Self.fetchAllMASTObservationRecords(
                        selectedFilter: filterName,
                        pageSize: pageSize,
                        session: session
                    )
                    return (filterName, records)
                }
            }

            var results: [(String, [MASTObservationAPIRecord])] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        return Dictionary(uniqueKeysWithValues: rawResults.map { filterName, records in
            (filterName, records.compactMap(mastObservationRow(from:)))
        })
    }

    private func preferredCellxgeneCollectionID(
        noteTexts: [String],
        theme: String
    ) async throws -> String? {
        let cacheKey = cellxgeneSelectionCacheKey(noteTexts: noteTexts, theme: theme)
        if let cached = cachedCellxgeneSelections[cacheKey] {
            return cached
        }
        if cachedCellxgeneSelectionMisses.contains(cacheKey) {
            return nil
        }

        let noteTerms = TrustedDatasetRegistry.tokenize(([theme] + noteTexts).joined(separator: " "))
        guard !noteTerms.isEmpty else {
            cachedCellxgeneSelectionMisses.insert(cacheKey)
            return nil
        }

        let collections = try await cellxgeneCollections()
        let scoredCollections = collections
            .map { summary in
                (
                    summary: summary,
                    score: baseCellxgeneCollectionScore(summary: summary, noteTerms: noteTerms)
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.summary.name < rhs.summary.name
                }
                return lhs.score > rhs.score
            }
        let positiveCollections = scoredCollections.filter { $0.score > 0 }

        guard let topCandidate = positiveCollections.first else {
            cachedCellxgeneSelectionMisses.insert(cacheKey)
            return nil
        }

        let runnerUpScore = positiveCollections.dropFirst().first?.score ?? .leastNormalMagnitude
        let shouldUseSummaryWinnerDirectly = topCandidate.score >= 12
            || positiveCollections.count == 1
            || topCandidate.score >= runnerUpScore + 4

        if shouldUseSummaryWinnerDirectly {
            cachedCellxgeneSelections[cacheKey] = topCandidate.summary.collectionID
            return topCandidate.summary.collectionID
        }

        var bestMatch: (collectionID: String, score: Double)?
        let refinedCandidates = Array(positiveCollections.prefix(2))

        for candidate in refinedCandidates {
            let detail = try await fetchCellxgeneCollectionDetail(collectionID: candidate.summary.collectionID)
            let score = candidate.score + refinedCellxgeneCollectionScore(detail: detail, noteTerms: noteTerms)

            if let bestMatch, score <= bestMatch.score {
                continue
            }

            bestMatch = (detail.collectionID, score)
        }

        guard let bestMatch, bestMatch.score > 0 else {
            cachedCellxgeneSelectionMisses.insert(cacheKey)
            return nil
        }

        cachedCellxgeneSelections[cacheKey] = bestMatch.collectionID
        return bestMatch.collectionID
    }

    private func cellxgeneSelectionCacheKey(noteTexts: [String], theme: String) -> String {
        ([theme] + noteTexts)
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func cellxgeneCollections() async throws -> [CellxgeneCollectionSummary] {
        if let cachedCellxgeneCollections {
            return cachedCellxgeneCollections
        }

        let url = URL(string: "https://api.cellxgene.cziscience.com/curation/v1/collections")!
        let collections = try await fetchJSON(
            url: url,
            method: "GET",
            body: nil,
            responseType: [CellxgeneCollectionSummary].self
        )
        cachedCellxgeneCollections = collections
        return collections
    }

    private func cellxgeneBundle(collectionID: String) async throws -> CellxgeneAtlasBundle {
        if let cached = cachedCellxgeneBundles[collectionID] {
            return cached
        }

        let detail = try await fetchCellxgeneCollectionDetail(collectionID: collectionID)
        guard let primaryDataset = primaryCellxgeneDataset(from: detail),
              let explorerURL = primaryDataset.explorerURL else {
            throw FallbackError.unsupported
        }

        let schema = try await fetchCellxgeneSchema(explorerURL: explorerURL)
        let config = try await fetchCellxgeneConfig(explorerURL: explorerURL)
        let columnsByName = Dictionary(uniqueKeysWithValues: schema.annotations.obs.columns.map { ($0.name, $0) })

        let subdatasets = detail.datasets.map { dataset in
            CellxgeneAtlasDatasetRow(
                title: dataset.title,
                datasetID: dataset.datasetID,
                datasetVersionID: dataset.datasetVersionID,
                cellCount: dataset.cellCount ?? 0,
                primaryCellCount: dataset.primaryCellCount,
                meanGenesPerCell: dataset.meanGenesPerCell,
                featureCount: dataset.featureCount,
                donorCount: dataset.donorID.count,
                diseaseLabels: ontologyLabels(from: dataset.disease),
                tissueLabels: tissueLabels(from: dataset.tissue),
                organismLabels: ontologyLabels(from: dataset.organism),
                sexLabels: ontologyLabels(from: dataset.sex),
                developmentStageLabels: ontologyLabels(from: dataset.developmentStage),
                cellTypeLabels: ontologyLabels(from: dataset.cellType),
                explorerURL: dataset.explorerURL
            )
        }
        .sorted { lhs, rhs in
            if lhs.cellCount != rhs.cellCount {
                return lhs.cellCount > rhs.cellCount
            }
            return lhs.title < rhs.title
        }

        let fineLabels = columnsByName["cluster_assignment_fine"]?.categories ?? []
        let coarseLabels = columnsByName["cluster_assignment_coarse"]?.categories ?? []
        let timepointLabels = columnsByName["Description"]?.categories ?? []
        let schemaDiseaseLabels = columnsByName["disease"]?.categories ?? []
        let schemaSexLabels = columnsByName["sex"]?.categories ?? []

        let bundle = CellxgeneAtlasBundle(
            collectionID: detail.collectionID,
            collectionName: detail.name,
            collectionDescription: detail.description,
            doi: detail.doi,
            citation: config.corporaProps.citation,
            rawDataLinks: detail.links.map(\.linkURL),
            primaryDatasetTitle: primaryDataset.title,
            primaryDatasetID: primaryDataset.datasetID,
            primaryDatasetVersionID: primaryDataset.datasetVersionID,
            donorCount: primaryDataset.donorID.count,
            diseaseLabels: ontologyLabels(from: primaryDataset.disease),
            tissueLabels: tissueLabels(from: primaryDataset.tissue),
            organismLabels: ontologyLabels(from: primaryDataset.organism),
            sexLabels: ontologyLabels(from: primaryDataset.sex),
            timepointLabels: timepointLabels,
            coarseLabels: coarseLabels,
            fineLabels: fineLabels,
            glialFineLabels: glialFineLabels(from: fineLabels),
            schemaDiseaseLabels: schemaDiseaseLabels,
            schemaSexLabels: schemaSexLabels,
            subdatasets: subdatasets,
            notes: [
                "This fallback uses CELLxGENE collection metadata, curated subdataset counts, explorer config metadata, and schema categories only.",
                "The local bundle does not download raw matrices or run gene-level differential expression; it supports a first-pass atlas composition and label-coverage analysis.",
                "Interpret any biology findings as atlas coverage or composition statements unless the supplied bundle explicitly contains expression statistics, which it does not."
            ]
        )

        cachedCellxgeneBundles[collectionID] = bundle
        return bundle
    }

    private func fetchCellxgeneCollectionDetail(collectionID: String) async throws -> CellxgeneCollectionDetail {
        let url = URL(string: "https://api.cellxgene.cziscience.com/curation/v1/collections/\(collectionID)")!
        return try await fetchJSON(
            url: url,
            method: "GET",
            body: nil,
            responseType: CellxgeneCollectionDetail.self
        )
    }

    private func fetchCellxgeneConfig(explorerURL: String) async throws -> CellxgeneConfig {
        let baseURL = try await cellxgeneRewrittenAPIBase(from: explorerURL)
        let response = try await fetchJSON(
            url: baseURL.appendingPathComponent("config"),
            method: "GET",
            body: nil,
            responseType: CellxgeneConfigResponse.self
        )
        return response.config
    }

    private func fetchCellxgeneSchema(explorerURL: String) async throws -> CellxgeneSchema {
        let baseURL = try await cellxgeneRewrittenAPIBase(from: explorerURL)
        let response = try await fetchJSON(
            url: baseURL.appendingPathComponent("schema"),
            method: "GET",
            body: nil,
            responseType: CellxgeneSchemaResponse.self
        )
        return response.schema
    }

    private func cellxgeneRewrittenAPIBase(from explorerURL: String) async throws -> URL {
        guard let deploymentID = cellxgeneDeploymentID(from: explorerURL) else {
            throw FallbackError.unsupported
        }

        let initialBase = URL(
            string: "https://api.cellxgene.cziscience.com/cellxgene/e/\(deploymentID).cxg/api/v0.3/"
        )!
        let s3URI = try await fetchJSON(
            url: initialBase.appendingPathComponent("s3_uri"),
            method: "GET",
            body: nil,
            responseType: String.self
        )
        let encoded = doublePercentEncodedPathComponent(s3URI)
        guard let url = URL(
            string: "https://api.cellxgene.cziscience.com/cellxgene/s3_uri/\(encoded)/api/v0.3/"
        ) else {
            throw FallbackError.invalidResponse
        }

        return url
    }

    private func cellxgeneDeploymentID(from explorerURL: String) -> String? {
        guard let range = explorerURL.range(of: "/e/") else {
            return nil
        }

        let suffix = explorerURL[range.upperBound...]
        guard let endRange = suffix.range(of: ".cxg") else {
            return nil
        }

        let deploymentID = suffix[..<endRange.lowerBound]
        let trimmed = deploymentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func doublePercentEncodedPathComponent(_ raw: String) -> String {
        percentEncodedPathComponent(percentEncodedPathComponent(raw))
    }

    private func percentEncodedPathComponent(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    private func primaryCellxgeneDataset(from detail: CellxgeneCollectionDetail) -> CellxgeneDatasetDetail? {
        detail.datasets.sorted { lhs, rhs in
            let lhsIsAllCells = lhs.title.lowercased().contains("all cells")
            let rhsIsAllCells = rhs.title.lowercased().contains("all cells")
            if lhsIsAllCells != rhsIsAllCells {
                return lhsIsAllCells && !rhsIsAllCells
            }

            let lhsCount = lhs.cellCount ?? 0
            let rhsCount = rhs.cellCount ?? 0
            if lhsCount != rhsCount {
                return lhsCount > rhsCount
            }

            return lhs.title < rhs.title
        }
        .first
    }

    private func glialFineLabels(from fineLabels: [String]) -> [String] {
        fineLabels.filter { label in
            let normalized = label.lowercased()
            return normalized.contains("astro")
                || normalized.contains("oligodend")
                || normalized.contains("opc")
                || normalized.contains("cop")
                || normalized.contains("nfol")
                || normalized.contains("mfol")
                || normalized.contains("mol")
        }
    }

    private func ontologyLabels(from labels: [CellxgeneOntologyLabel]) -> [String] {
        labels.map { $0.label }
    }

    private func tissueLabels(from labels: [CellxgeneTissueLabel]) -> [String] {
        labels.map { $0.label }
    }

    private func baseCellxgeneCollectionScore(
        summary: CellxgeneCollectionSummary,
        noteTerms: Set<String>
    ) -> Double {
        let datasetTerms = summary.datasets.map { dataset -> String in
            let parts = ontologyLabels(from: dataset.disease)
                + ontologyLabels(from: dataset.organism)
                + tissueLabels(from: dataset.tissue)
                + ontologyLabels(from: dataset.assay)
                + dataset.suspensionType
            return parts.joined(separator: " ")
        }
        .joined(separator: " ")
        let candidateText = [summary.name, summary.description ?? "", datasetTerms]
            .joined(separator: " ")
            .lowercased()

        return weightedSemanticTokenScore(text: candidateText, noteTerms: noteTerms)
    }

    private func refinedCellxgeneCollectionScore(
        detail: CellxgeneCollectionDetail,
        noteTerms: Set<String>
    ) -> Double {
        let datasetTitles = detail.datasets.map { $0.title }.joined(separator: " ")
        let datasetTerms = detail.datasets.map { dataset -> String in
            let parts = ontologyLabels(from: dataset.cellType)
                + ontologyLabels(from: dataset.disease)
                + tissueLabels(from: dataset.tissue)
                + ontologyLabels(from: dataset.organism)
            return parts.joined(separator: " ")
        }
        .joined(separator: " ")
        let detailText = [detail.name, detail.description ?? "", datasetTitles, datasetTerms]
            .joined(separator: " ")
            .lowercased()

        return weightedSemanticTokenScore(text: detailText, noteTerms: noteTerms)
    }

    private func weightedSemanticTokenScore(text: String, noteTerms: Set<String>) -> Double {
        TrustedDatasetRegistry.semanticSimilarityScore(
            sourceTerms: noteTerms,
            candidateText: text,
            exactWeight: 4,
            fuzzyWeight: 2.5
        )
    }

    private func mastObservationRow(from record: MASTObservationAPIRecord) -> MASTObservationRow? {
        guard let obsid = record.obsid,
              let filterName = record.filters?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filterName.isEmpty,
              let exposureSeconds = record.exposureSeconds else {
            return nil
        }

        let filterBand: String
        if mastUVFilters.contains(filterName) {
            filterBand = "uv"
        } else if mastOpticalFilters.contains(filterName) {
            filterBand = "optical"
        } else {
            filterBand = "other"
        }

        return MASTObservationRow(
            observationID: String(obsid),
            filterName: filterName,
            filterBand: filterBand,
            exposureSeconds: exposureSeconds,
            proposalID: normalizedOptionalString(record.proposalID) ?? "unknown",
            targetName: normalizedOptionalString(record.targetName) ?? "unknown",
            dataRights: normalizedOptionalString(record.dataRights)
        )
    }

    private static func fetchMASTObservationPage(
        page: Int,
        pageSize: Int,
        selectedFilters: [String],
        session: URLSession
    ) async throws -> MASTFilteredResponse {
        let payload: [String: Any] = [
            "service": "Mast.Caom.Filtered",
            "params": [
                "columns": "obsid,obs_collection,instrument_name,filters,t_exptime,proposal_id,target_name,dataRights",
                "filters": [
                    [
                        "paramName": "obs_collection",
                        "values": ["HST"]
                    ],
                    [
                        "paramName": "instrument_name",
                        "values": ["WFC3/UVIS"]
                    ],
                    [
                        "paramName": "filters",
                        "values": selectedFilters
                    ]
                ]
            ],
            "format": "json",
            "pagesize": pageSize,
            "page": page
        ]

        return try await fetchMASTJSON(
            session: session,
            payload: payload,
            responseType: MASTFilteredResponse.self
        )
    }

    private static func fetchAllMASTObservationRecords(
        selectedFilter: String,
        pageSize: Int,
        session: URLSession
    ) async throws -> [MASTObservationAPIRecord] {
        let firstPage = try await fetchMASTObservationPage(
            page: 1,
            pageSize: pageSize,
            selectedFilters: [selectedFilter],
            session: session
        )
        let totalPages = max(firstPage.paging.pagesFiltered, 1)
        var pageRows: [(Int, [MASTObservationAPIRecord])] = [(1, firstPage.data)]

        if totalPages > 1 {
            try await withThrowingTaskGroup(of: (Int, [MASTObservationAPIRecord]).self) { group in
                for page in 2 ... totalPages {
                    group.addTask {
                        let response = try await fetchMASTObservationPage(
                            page: page,
                            pageSize: pageSize,
                            selectedFilters: [selectedFilter],
                            session: session
                        )
                        return (page, response.data)
                    }
                }

                for try await result in group {
                    pageRows.append(result)
                }
            }
        }

        return pageRows
            .sorted { $0.0 < $1.0 }
            .flatMap(\.1)
    }

    private func gbmBundle() async throws -> GBMCBioPortalBundle {
        if let cachedGBMBundle {
            return cachedGBMBundle
        }

        let studyID = "gbm_tcga"
        let clinicalAttributeIDs = [
            "AGE",
            "SEX",
            "OS_MONTHS",
            "OS_STATUS",
            "HISTOLOGICAL_DIAGNOSIS"
        ]

        async let study = fetchStudy(studyID: studyID)
        async let clinicalAttributes = fetchClinicalAttributes(studyID: studyID)
        async let molecularProfiles = fetchMolecularProfiles(studyID: studyID)
        async let patientIDs = fetchPatientIDs(studyID: studyID)
        async let sequencedPatientIDs = fetchPatientIDs(forSampleListID: "gbm_tcga_sequenced")
        async let cnaPatientIDs = fetchPatientIDs(forSampleListID: "gbm_tcga_cna")
        async let hm27PatientIDs = fetchPatientIDs(forSampleListID: "gbm_tcga_methylation_hm27")
        async let hm450PatientIDs = fetchPatientIDs(forSampleListID: "gbm_tcga_methylation_hm450")

        let resolvedPatientIDs = try await patientIDs

        async let clinicalData = fetchClinicalData(
            studyID: studyID,
            patientIDs: resolvedPatientIDs,
            attributeIDs: clinicalAttributeIDs
        )
        async let idh1Mutations = fetchMutations(
            molecularProfileID: "gbm_tcga_mutations",
            sampleListID: "gbm_tcga_sequenced",
            entrezGeneID: 3417
        )
        async let egfrDiscreteCNA = fetchDiscreteCopyNumber(
            molecularProfileID: "gbm_tcga_gistic",
            sampleListID: "gbm_tcga_cna",
            entrezGeneID: 1956
        )
        async let mgmtHM27 = fetchNumericMolecularData(
            molecularProfileID: "gbm_tcga_methylation_hm27",
            sampleListID: "gbm_tcga_methylation_hm27",
            entrezGeneID: 4255
        )
        async let mgmtHM450 = fetchNumericMolecularData(
            molecularProfileID: "gbm_tcga_methylation_hm450",
            sampleListID: "gbm_tcga_methylation_hm450",
            entrezGeneID: 4255
        )

        let studySummary = try await study
        let relevantClinicalAttributes = try await clinicalAttributes
        let relevantMolecularProfiles = try await molecularProfiles
        let mutationPatients = try await sequencedPatientIDs
        let cnaPatients = try await cnaPatientIDs
        let hm27Patients = try await hm27PatientIDs
        let hm450Patients = try await hm450PatientIDs
        let allClinicalData = try await clinicalData
        let allIDH1Mutations = try await idh1Mutations
        let allEGFRCNA = try await egfrDiscreteCNA
        let allMGMTHM27 = try await mgmtHM27
        let allMGMTHM450 = try await mgmtHM450

        let clinicalByPatient = clinicalValuesByPatient(from: allClinicalData)
        let idh1ChangesByPatient = mutationChangesByPatient(from: allIDH1Mutations)
        let egfrCallsByPatient = discreteValuesByPatient(from: allEGFRCNA)
        let hm27ByPatient = averagedValuesByPatient(from: allMGMTHM27)
        let hm450ByPatient = averagedValuesByPatient(from: allMGMTHM450)

        let rows = resolvedPatientIDs.sorted().map { patientID in
            let clinical = clinicalByPatient[patientID] ?? [:]
            let mutationChanges = idh1ChangesByPatient[patientID] ?? []
            let sequenced = mutationPatients.contains(patientID)
            let cnaAvailable = cnaPatients.contains(patientID)
            let hm27Available = hm27Patients.contains(patientID)
            let hm450Available = hm450Patients.contains(patientID)

            return GBMCBioPortalCohortRow(
                patientID: patientID,
                ageYears: intValue(from: clinical["AGE"]),
                sex: clinical["SEX"],
                overallSurvivalMonths: doubleValue(from: clinical["OS_MONTHS"]),
                overallSurvivalStatus: clinical["OS_STATUS"],
                histologicalDiagnosis: clinical["HISTOLOGICAL_DIAGNOSIS"],
                idh1Sequenced: sequenced,
                idh1MutationPresent: sequenced ? !mutationChanges.isEmpty : nil,
                idh1ProteinChanges: mutationChanges,
                egfrCNAProfileAvailable: cnaAvailable,
                egfrGisticCall: cnaAvailable ? (egfrCallsByPatient[patientID] ?? 0) : nil,
                mgmtHM27Available: hm27Available,
                mgmtMethylationHM27: hm27ByPatient[patientID],
                mgmtHM450Available: hm450Available,
                mgmtMethylationHM450: hm450ByPatient[patientID]
            )
        }

        let bundle = GBMCBioPortalBundle(
            study: studySummary,
            clinicalAttributes: relevantClinicalAttributes
                .filter { clinicalAttributeIDs.contains($0.clinicalAttributeID) }
                .sorted { $0.clinicalAttributeID < $1.clinicalAttributeID },
            molecularProfiles: relevantMolecularProfiles
                .filter {
                    [
                        "gbm_tcga_mutations",
                        "gbm_tcga_gistic",
                        "gbm_tcga_methylation_hm27",
                        "gbm_tcga_methylation_hm450"
                    ].contains($0.molecularProfileID)
                }
                .sorted { $0.molecularProfileID < $1.molecularProfileID },
            coverage: GBMCBioPortalCoverage(
                patientCount: rows.count,
                patientsWithSurvivalMonths: rows.filter { $0.overallSurvivalMonths != nil }.count,
                patientsWithSurvivalStatus: rows.filter { $0.overallSurvivalStatus != nil }.count,
                patientsWithAge: rows.filter { $0.ageYears != nil }.count,
                patientsWithSex: rows.filter { $0.sex != nil }.count,
                sequencedPatients: mutationPatients.count,
                idh1MutantPatients: rows.filter { $0.idh1MutationPresent == true }.count,
                cnaProfilePatients: cnaPatients.count,
                egfrAmplifiedPatients: rows.filter { ($0.egfrGisticCall ?? 0) >= 2 }.count,
                hm27Patients: hm27Patients.count,
                hm450Patients: hm450Patients.count,
                patientsWithAnyMGMTMethylation: rows.filter {
                    $0.mgmtMethylationHM27 != nil || $0.mgmtMethylationHM450 != nil
                }.count
            ),
            rows: rows,
            notes: [
                "This fallback keeps the cohort inside one public cBioPortal study: gbm_tcga.",
                "IDH1 mutation status is null when the patient was not in the sequenced sample list; false means sequenced with no returned IDH1 mutation event.",
                "EGFR GISTIC calls use 0 for CNA-profile patients with no returned EGFR event record, and null when the patient lacks CNA coverage.",
                "MGMT values are public gene-level methylation measurements from HM27 and HM450 profiles, not a guaranteed binary promoter methylation annotation."
            ]
        )

        cachedGBMBundle = bundle
        return bundle
    }

    private func clinicalValuesByPatient(from entries: [CBioPortalClinicalData]) -> [String: [String: String]] {
        var values: [String: [String: String]] = [:]

        for entry in entries {
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                continue
            }

            values[entry.patientID, default: [:]][entry.clinicalAttributeID] = value
        }

        return values
    }

    private func mutationChangesByPatient(from entries: [CBioPortalMutation]) -> [String: [String]] {
        var values: [String: Set<String>] = [:]

        for entry in entries {
            let label = [
                entry.proteinChange?.trimmingCharacters(in: .whitespacesAndNewlines),
                entry.mutationType?.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
            .compactMap { value in
                guard let value, !value.isEmpty else {
                    return nil
                }

                return value
            }
            .joined(separator: " ")

            guard !label.isEmpty else {
                continue
            }

            values[entry.patientID, default: []].insert(label)
        }

        return values.mapValues { Array($0).sorted() }
    }

    private func discreteValuesByPatient(from entries: [CBioPortalDiscreteCopyNumber]) -> [String: Int] {
        Dictionary(grouping: entries, by: \.patientID)
            .compactMapValues { rows in
                rows.compactMap(\.alteration).max()
            }
    }

    private func averagedValuesByPatient(from entries: [CBioPortalNumericMolecularData]) -> [String: Double] {
        Dictionary(grouping: entries, by: \.patientID)
            .compactMapValues { rows in
                let values = rows.compactMap(\.value)
                guard !values.isEmpty else {
                    return nil
                }

                let total = values.reduce(0, +)
                return total / Double(values.count)
            }
    }

    private func fetchStudy(studyID: String) async throws -> CBioPortalStudy {
        let url = URL(string: "https://www.cbioportal.org/api/studies/\(studyID)?projection=DETAILED")!
        return try await fetchJSON(url: url, method: "GET", body: nil, responseType: CBioPortalStudy.self)
    }

    private func fetchClinicalAttributes(studyID: String) async throws -> [CBioPortalClinicalAttribute] {
        let url = URL(string: "https://www.cbioportal.org/api/studies/\(studyID)/clinical-attributes?projection=SUMMARY")!
        return try await fetchJSON(url: url, method: "GET", body: nil, responseType: [CBioPortalClinicalAttribute].self)
    }

    private func fetchMolecularProfiles(studyID: String) async throws -> [CBioPortalMolecularProfile] {
        let url = URL(string: "https://www.cbioportal.org/api/studies/\(studyID)/molecular-profiles?projection=SUMMARY")!
        return try await fetchJSON(url: url, method: "GET", body: nil, responseType: [CBioPortalMolecularProfile].self)
    }

    private func fetchPatientIDs(studyID: String) async throws -> [String] {
        let url = URL(string: "https://www.cbioportal.org/api/studies/\(studyID)/patients?projection=ID&pageSize=10000&pageNumber=0")!
        let entries = try await fetchJSON(url: url, method: "GET", body: nil, responseType: [CBioPortalPatient].self)
        return entries.map(\.patientID)
    }

    private func fetchPatientIDs(forSampleListID sampleListID: String) async throws -> Set<String> {
        let url = URL(string: "https://www.cbioportal.org/api/sample-lists/\(sampleListID)/sample-ids")!
        let sampleIDs = try await fetchJSON(url: url, method: "GET", body: nil, responseType: [String].self)
        let patientIDs = sampleIDs.map(Self.patientID(fromSampleID:))
        return Set(patientIDs.filter { !$0.isEmpty })
    }

    private func fetchClinicalData(
        studyID: String,
        patientIDs: [String],
        attributeIDs: [String]
    ) async throws -> [CBioPortalClinicalData] {
        let url = URL(
            string: "https://www.cbioportal.org/api/studies/\(studyID)/clinical-data/fetch?clinicalDataType=PATIENT&projection=SUMMARY"
        )!
        let body: [String: Any] = [
            "ids": patientIDs,
            "attributeIds": attributeIDs
        ]

        return try await fetchJSON(url: url, method: "POST", body: body, responseType: [CBioPortalClinicalData].self)
    }

    private func fetchMutations(
        molecularProfileID: String,
        sampleListID: String,
        entrezGeneID: Int
    ) async throws -> [CBioPortalMutation] {
        let url = URL(
            string: "https://www.cbioportal.org/api/molecular-profiles/\(molecularProfileID)/mutations/fetch?projection=SUMMARY&pageSize=10000"
        )!
        let body: [String: Any] = [
            "sampleListId": sampleListID,
            "entrezGeneIds": [entrezGeneID]
        ]

        return try await fetchJSON(url: url, method: "POST", body: body, responseType: [CBioPortalMutation].self)
    }

    private func fetchDiscreteCopyNumber(
        molecularProfileID: String,
        sampleListID: String,
        entrezGeneID: Int
    ) async throws -> [CBioPortalDiscreteCopyNumber] {
        let url = URL(
            string: "https://www.cbioportal.org/api/molecular-profiles/\(molecularProfileID)/discrete-copy-number/fetch?projection=SUMMARY"
        )!
        let body: [String: Any] = [
            "sampleListId": sampleListID,
            "entrezGeneIds": [entrezGeneID]
        ]

        return try await fetchJSON(url: url, method: "POST", body: body, responseType: [CBioPortalDiscreteCopyNumber].self)
    }

    private func fetchNumericMolecularData(
        molecularProfileID: String,
        sampleListID: String,
        entrezGeneID: Int
    ) async throws -> [CBioPortalNumericMolecularData] {
        let url = URL(
            string: "https://www.cbioportal.org/api/molecular-profiles/\(molecularProfileID)/molecular-data/fetch?projection=SUMMARY"
        )!
        let body: [String: Any] = [
            "sampleListId": sampleListID,
            "entrezGeneIds": [entrezGeneID]
        ]

        return try await fetchJSON(url: url, method: "POST", body: body, responseType: [CBioPortalNumericMolecularData].self)
    }

    private func fetchJSON<T: Decodable>(
        url: URL,
        method: String,
        body: [String: Any]?,
        responseType: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FallbackError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown response body"
            throw FallbackError.httpFailure(httpResponse.statusCode, message)
        }

        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
            throw FallbackError.invalidResponse
        }
    }

    private static func fetchMASTJSON<T: Decodable>(
        session: URLSession,
        payload: [String: Any],
        responseType: T.Type
    ) async throws -> T {
        var request = URLRequest(url: URL(string: "https://mast.stsci.edu/api/v0/invoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw FallbackError.invalidResponse
        }

        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "request", value: payloadJSON)]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FallbackError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown response body"
            throw FallbackError.httpFailure(httpResponse.statusCode, message)
        }

        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
            throw FallbackError.invalidResponse
        }
    }

    private func encodeCompactJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw FallbackError.invalidResponse
        }

        return string
    }

    private func compactCSV(from rows: [GBMCBioPortalCohortRow]) -> String {
        var lines = ["pid,age,sex,os_m,os_s,idh1_cov,idh1_mut,egfr_cov,egfr_g,hm27,hm450"]
        lines.reserveCapacity(rows.count + 1)

        for row in rows {
            let values = [
                csvField(row.patientID),
                row.ageYears.map(String.init) ?? "",
                csvField(row.sex ?? ""),
                formatDouble(row.overallSurvivalMonths),
                csvField(row.overallSurvivalStatus ?? ""),
                row.idh1Sequenced ? "1" : "0",
                row.idh1MutationPresent.map { $0 ? "1" : "0" } ?? "",
                row.egfrCNAProfileAvailable ? "1" : "0",
                row.egfrGisticCall.map(String.init) ?? "",
                formatDouble(row.mgmtMethylationHM27),
                formatDouble(row.mgmtMethylationHM450)
            ]

            lines.append(values.joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    private func compactCSV(from rows: [MASTProposalFilterSummary]) -> String {
        var lines = ["proposal_id,filter_name,filter_band,observation_count,median_exposure_s,mean_exposure_s,min_exposure_s,max_exposure_s,target_count"]
        lines.reserveCapacity(rows.count + 1)

        for row in rows {
            let values = [
                csvField(row.proposalID),
                csvField(row.filterName),
                csvField(row.filterBand),
                String(row.observationCount),
                formatDouble(row.medianExposureSeconds),
                formatDouble(row.meanExposureSeconds),
                formatDouble(row.minExposureSeconds),
                formatDouble(row.maxExposureSeconds),
                String(row.targetCount)
            ]

            lines.append(values.joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    private func normalizedOptionalString(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }

        return values.reduce(0, +) / Double(values.count)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }

        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }

        return sorted[middle]
    }

    private func compressedBase64Zlib(_ string: String) throws -> String {
        guard let input = string.data(using: .utf8) else {
            throw FallbackError.invalidResponse
        }

        let destinationCapacity = Int(compressBound(uLong(input.count)))
        var output = Data(count: destinationCapacity)
        var outputLength = uLongf(destinationCapacity)

        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                guard let outputBase = outputBytes.bindMemory(to: Bytef.self).baseAddress,
                      let inputBase = inputBytes.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_MEM_ERROR
                }

                return compress2(
                    outputBase,
                    &outputLength,
                    inputBase,
                    uLong(input.count),
                    Z_BEST_COMPRESSION
                )
            }
        }

        guard status == Z_OK else {
            throw FallbackError.invalidResponse
        }

        output.removeSubrange(Int(outputLength) ..< output.count)
        return output.base64EncodedString()
    }

    private func formatDouble(_ value: Double?) -> String {
        guard let value else {
            return ""
        }

        return String(format: "%.6g", value)
    }

    private func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }

        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func intValue(from raw: String?) -> Int? {
        guard let raw else {
            return nil
        }

        return Int(raw)
    }

    private func doubleValue(from raw: String?) -> Double? {
        guard let raw else {
            return nil
        }

        return Double(raw)
    }

    private static func patientID(fromSampleID sampleID: String) -> String {
        let components = sampleID.split(separator: "-")
        guard components.count >= 3 else {
            return sampleID
        }

        return components.prefix(3).joined(separator: "-")
    }
}

private nonisolated struct GBMCBioPortalBundle {
    let study: CBioPortalStudy
    let clinicalAttributes: [CBioPortalClinicalAttribute]
    let molecularProfiles: [CBioPortalMolecularProfile]
    let coverage: GBMCBioPortalCoverage
    let rows: [GBMCBioPortalCohortRow]
    let notes: [String]
}

private nonisolated struct GBMCBioPortalInspectionInput: Encodable {
    let provider = "cbioportal-public"
    let selectedDatasetIDs: [String]
    let study: CBioPortalStudy
    let clinicalAttributes: [CBioPortalClinicalAttribute]
    let molecularProfiles: [CBioPortalMolecularProfile]
    let coverage: GBMCBioPortalCoverage
    let variableInterpretation: [String]
    let previewRows: [GBMCBioPortalCohortRow]
    let notes: [String]

    init(from bundle: GBMCBioPortalBundle, selectedDatasetIDs: [String]) {
        self.selectedDatasetIDs = selectedDatasetIDs
        study = bundle.study
        clinicalAttributes = bundle.clinicalAttributes
        molecularProfiles = bundle.molecularProfiles
        coverage = bundle.coverage
        variableInterpretation = [
            "`idh1_mutation_present` is `true` when a mutation event was returned, `false` when the patient was sequenced with no returned IDH1 event, and `null` when sequencing coverage was unavailable.",
            "`egfr_gistic_call` uses cBioPortal GISTIC discrete CNA values for EGFR. A value of `0` means the patient had CNA coverage with no returned EGFR event; `null` means no CNA profile coverage.",
            "`mgmt_methylation_hm27` and `mgmt_methylation_hm450` are continuous gene-level methylation measurements, not a guaranteed binary promoter methylation label."
        ]
        previewRows = Array(bundle.rows.prefix(8))
        notes = bundle.notes
    }
}

private nonisolated struct GBMCBioPortalAnalysisInput: Encodable {
    let provider = "cbioportal-public"
    let selectedDatasetIDs: [String]
    let study: CBioPortalStudy
    let coverage: GBMCBioPortalCoverage
    let variableInterpretation: [String]
    let cohortRows: [GBMCBioPortalCohortRow]
    let notes: [String]

    init(from bundle: GBMCBioPortalBundle, selectedDatasetIDs: [String]) {
        self.selectedDatasetIDs = selectedDatasetIDs
        study = bundle.study
        coverage = bundle.coverage
        variableInterpretation = [
            "Use `overall_survival_months` and `overall_survival_status` for survival summaries.",
            "Use `idh1_mutation_present` only after respecting nulls for patients without sequencing coverage.",
            "Treat `egfr_gistic_call >= 2` as EGFR amplification and `egfr_gistic_call <= 0` as not amplified only within patients with CNA profile coverage.",
            "Treat MGMT methylation as continuous HM27/HM450 measurements or use a transparent study-specific split; do not relabel it as a binary promoter annotation unless the data support that wording."
        ]
        cohortRows = bundle.rows
        notes = bundle.notes
    }
}

private nonisolated struct GBMCBioPortalBundledAnalysisMetadata: Encodable {
    let provider = "cbioportal-public"
    let selectedDatasetIDs: [String]
    let study: CBioPortalStudy
    let coverage: GBMCBioPortalCoverage
    let csvColumnGuide: [String: String]
    let notes: [String]

    init(from bundle: GBMCBioPortalBundle, selectedDatasetIDs: [String]) {
        self.selectedDatasetIDs = selectedDatasetIDs
        study = bundle.study
        coverage = bundle.coverage
        csvColumnGuide = [
            "pid": "TCGA patient identifier",
            "age": "age at diagnosis in years",
            "sex": "reported sex",
            "os_m": "overall survival in months",
            "os_s": "overall survival status",
            "idh1_cov": "1 when the patient had sequencing coverage for IDH1, else 0",
            "idh1_mut": "1 when an IDH1 mutation event was returned, 0 when sequenced with no returned event, blank when no sequencing coverage",
            "egfr_cov": "1 when the patient had CNA coverage for EGFR, else 0",
            "egfr_g": "EGFR GISTIC discrete CNA call; 0 means CNA coverage with no returned EGFR event, blank means no CNA coverage",
            "hm27": "MGMT HM27 methylation value; blank when unavailable",
            "hm450": "MGMT HM450 methylation value; blank when unavailable"
        ]
        notes = bundle.notes
    }
}

private nonisolated struct GBMCBioPortalCoverage: Encodable {
    let patientCount: Int
    let patientsWithSurvivalMonths: Int
    let patientsWithSurvivalStatus: Int
    let patientsWithAge: Int
    let patientsWithSex: Int
    let sequencedPatients: Int
    let idh1MutantPatients: Int
    let cnaProfilePatients: Int
    let egfrAmplifiedPatients: Int
    let hm27Patients: Int
    let hm450Patients: Int
    let patientsWithAnyMGMTMethylation: Int
}

private nonisolated struct GBMCBioPortalCohortRow: Encodable {
    let patientID: String
    let ageYears: Int?
    let sex: String?
    let overallSurvivalMonths: Double?
    let overallSurvivalStatus: String?
    let histologicalDiagnosis: String?
    let idh1Sequenced: Bool
    let idh1MutationPresent: Bool?
    let idh1ProteinChanges: [String]
    let egfrCNAProfileAvailable: Bool
    let egfrGisticCall: Int?
    let mgmtHM27Available: Bool
    let mgmtMethylationHM27: Double?
    let mgmtHM450Available: Bool
    let mgmtMethylationHM450: Double?

    enum CodingKeys: String, CodingKey {
        case patientID = "patient_id"
        case ageYears = "age_years"
        case sex
        case overallSurvivalMonths = "overall_survival_months"
        case overallSurvivalStatus = "overall_survival_status"
        case histologicalDiagnosis = "histological_diagnosis"
        case idh1Sequenced = "idh1_sequenced"
        case idh1MutationPresent = "idh1_mutation_present"
        case idh1ProteinChanges = "idh1_protein_changes"
        case egfrCNAProfileAvailable = "egfr_cna_profile_available"
        case egfrGisticCall = "egfr_gistic_call"
        case mgmtHM27Available = "mgmt_hm27_available"
        case mgmtMethylationHM27 = "mgmt_methylation_hm27"
        case mgmtHM450Available = "mgmt_hm450_available"
        case mgmtMethylationHM450 = "mgmt_methylation_hm450"
    }
}

private nonisolated struct CBioPortalStudy: Codable {
    let studyID: String
    let name: String
    let description: String?

    enum CodingKeys: String, CodingKey {
        case studyID = "studyId"
        case name
        case description
    }
}

private nonisolated struct CBioPortalClinicalAttribute: Codable {
    let clinicalAttributeID: String
    let displayName: String?
    let datatype: String?
    let patientAttribute: Bool?

    enum CodingKeys: String, CodingKey {
        case clinicalAttributeID = "clinicalAttributeId"
        case displayName
        case datatype
        case patientAttribute
    }
}

private nonisolated struct CBioPortalMolecularProfile: Codable {
    let molecularProfileID: String
    let name: String?
    let molecularAlterationType: String?
    let datatype: String?

    enum CodingKeys: String, CodingKey {
        case molecularProfileID = "molecularProfileId"
        case name
        case molecularAlterationType
        case datatype
    }
}

private nonisolated struct CBioPortalPatient: Decodable {
    let patientID: String

    enum CodingKeys: String, CodingKey {
        case patientID = "patientId"
    }
}

private nonisolated struct CBioPortalClinicalData: Decodable {
    let patientID: String
    let clinicalAttributeID: String
    let value: String

    enum CodingKeys: String, CodingKey {
        case patientID = "patientId"
        case clinicalAttributeID = "clinicalAttributeId"
        case value
    }
}

private nonisolated struct CBioPortalMutation: Decodable {
    let patientID: String
    let proteinChange: String?
    let mutationType: String?

    enum CodingKeys: String, CodingKey {
        case patientID = "patientId"
        case proteinChange
        case mutationType
    }
}

private nonisolated struct CBioPortalDiscreteCopyNumber: Decodable {
    let patientID: String
    let alteration: Int?

    enum CodingKeys: String, CodingKey {
        case patientID = "patientId"
        case alteration
    }
}

private nonisolated struct CBioPortalNumericMolecularData: Decodable {
    let patientID: String
    let value: Double?

    enum CodingKeys: String, CodingKey {
        case patientID = "patientId"
        case value
    }
}

private nonisolated struct MASTFilteredResponse: Decodable {
    let data: [MASTObservationAPIRecord]
    let paging: MASTPaging
}

private nonisolated struct MASTPaging: Decodable {
    let page: Int
    let pageSize: Int
    let pagesFiltered: Int
    let rowsFiltered: Int
}

private nonisolated struct MASTObservationAPIRecord: Decodable {
    let obsid: Int?
    let filters: String?
    let exposureSeconds: Double?
    let proposalID: String?
    let targetName: String?
    let dataRights: String?

    enum CodingKeys: String, CodingKey {
        case obsid
        case filters
        case exposureSeconds = "t_exptime"
        case proposalID = "proposal_id"
        case targetName = "target_name"
        case dataRights
    }
}

private nonisolated struct MASTObservationBundle {
    let observationCollection: String
    let instrumentName: String
    let selectedFilters: [String]
    let retainedObservationCount: Int
    let originalObservationCount: Int
    let proposalCount: Int
    let targetCount: Int
    let filterCoverage: [MASTFilterCoverage]
    let proposalSummaries: [MASTProposalFilterSummary]
    let previewRows: [MASTObservationRow]
    let notes: [String]
}

private nonisolated struct MASTObservationRow: Encodable {
    let observationID: String
    let filterName: String
    let filterBand: String
    let exposureSeconds: Double
    let proposalID: String
    let targetName: String
    let dataRights: String?

    enum CodingKeys: String, CodingKey {
        case observationID = "observation_id"
        case filterName = "filter_name"
        case filterBand = "filter_band"
        case exposureSeconds = "exposure_seconds"
        case proposalID = "proposal_id"
        case targetName = "target_name"
        case dataRights = "data_rights"
    }
}

private nonisolated struct MASTFilterCoverage: Encodable {
    let filterName: String
    let filterBand: String
    let observationCount: Int
    let proposalCount: Int
    let targetCount: Int
    let medianExposureSeconds: Double
    let meanExposureSeconds: Double

    enum CodingKeys: String, CodingKey {
        case filterName = "filter_name"
        case filterBand = "filter_band"
        case observationCount = "observation_count"
        case proposalCount = "proposal_count"
        case targetCount = "target_count"
        case medianExposureSeconds = "median_exposure_seconds"
        case meanExposureSeconds = "mean_exposure_seconds"
    }
}

private nonisolated struct MASTProposalFilterSummary: Encodable {
    let proposalID: String
    let filterName: String
    let filterBand: String
    let observationCount: Int
    let medianExposureSeconds: Double
    let meanExposureSeconds: Double
    let minExposureSeconds: Double
    let maxExposureSeconds: Double
    let targetCount: Int

    enum CodingKeys: String, CodingKey {
        case proposalID = "proposal_id"
        case filterName = "filter_name"
        case filterBand = "filter_band"
        case observationCount = "observation_count"
        case medianExposureSeconds = "median_exposure_seconds"
        case meanExposureSeconds = "mean_exposure_seconds"
        case minExposureSeconds = "min_exposure_seconds"
        case maxExposureSeconds = "max_exposure_seconds"
        case targetCount = "target_count"
    }
}

private nonisolated struct MASTObservationInspectionInput: Encodable {
    let provider = "mast-observations"
    let selectedDatasetIDs: [String]
    let observationCollection: String
    let instrumentName: String
    let selectedFilters: [String]
    let observationCount: Int
    let previewProposalCount: Int
    let previewTargetCount: Int
    let previewFilterCoverage: [MASTFilterCoverage]
    let previewRows: [MASTObservationRow]
    let notes: [String]

    enum CodingKeys: String, CodingKey {
        case provider
        case selectedDatasetIDs = "selected_dataset_ids"
        case observationCollection = "observation_collection"
        case instrumentName = "instrument_name"
        case selectedFilters = "selected_filters"
        case observationCount = "observation_count"
        case previewProposalCount = "preview_proposal_count"
        case previewTargetCount = "preview_target_count"
        case previewFilterCoverage = "preview_filter_coverage"
        case previewRows = "preview_rows"
        case notes
    }

    init(
        selectedDatasetIDs: [String],
        observationCollection: String,
        instrumentName: String,
        selectedFilters: [String],
        observationCount: Int,
        previewProposalCount: Int,
        previewTargetCount: Int,
        previewFilterCoverage: [MASTFilterCoverage],
        previewRows: [MASTObservationRow],
        notes: [String]
    ) {
        self.selectedDatasetIDs = selectedDatasetIDs
        self.observationCollection = observationCollection
        self.instrumentName = instrumentName
        self.selectedFilters = selectedFilters
        self.observationCount = observationCount
        self.previewProposalCount = previewProposalCount
        self.previewTargetCount = previewTargetCount
        self.previewFilterCoverage = previewFilterCoverage
        self.previewRows = previewRows
        self.notes = notes
    }
}

private nonisolated struct MASTObservationAnalysisInput: Encodable {
    let provider = "mast-observations"
    let selectedDatasetIDs: [String]
    let observationCollection: String
    let instrumentName: String
    let selectedFilters: [String]
    let retainedObservationCount: Int
    let originalObservationCount: Int
    let proposalCount: Int
    let targetCount: Int
    let filterCoverage: [MASTFilterCoverage]
    let csvColumnGuide: [String: String]
    let notes: [String]

    enum CodingKeys: String, CodingKey {
        case provider
        case selectedDatasetIDs = "selected_dataset_ids"
        case observationCollection = "observation_collection"
        case instrumentName = "instrument_name"
        case selectedFilters = "selected_filters"
        case retainedObservationCount = "retained_observation_count"
        case originalObservationCount = "original_observation_count"
        case proposalCount = "proposal_count"
        case targetCount = "target_count"
        case filterCoverage = "filter_coverage"
        case csvColumnGuide = "csv_column_guide"
        case notes
    }

    init(from bundle: MASTObservationBundle, selectedDatasetIDs: [String]) {
        self.selectedDatasetIDs = selectedDatasetIDs
        observationCollection = bundle.observationCollection
        instrumentName = bundle.instrumentName
        selectedFilters = bundle.selectedFilters
        retainedObservationCount = bundle.retainedObservationCount
        originalObservationCount = bundle.originalObservationCount
        proposalCount = bundle.proposalCount
        targetCount = bundle.targetCount
        filterCoverage = bundle.filterCoverage
        csvColumnGuide = [
            "proposal_id": "HST proposal identifier or `unknown` when the returned MAST row lacked it",
            "filter_name": "WFC3/UVIS filter name",
            "filter_band": "Derived group label: `uv` for F225W/F275W/F336W and `optical` for F438W/F555W/F606W/F814W",
            "observation_count": "Number of retained observations for that proposal-filter combination",
            "median_exposure_s": "Median exposure time in seconds across retained observations for that proposal-filter combination",
            "mean_exposure_s": "Mean exposure time in seconds across retained observations for that proposal-filter combination",
            "min_exposure_s": "Minimum exposure time in seconds across retained observations for that proposal-filter combination",
            "max_exposure_s": "Maximum exposure time in seconds across retained observations for that proposal-filter combination",
            "target_count": "Count of unique target_name values for that proposal-filter combination"
        ]
        notes = bundle.notes
    }
}

private nonisolated struct CellxgeneOntologyLabel: Codable {
    let label: String
    let ontologyTermID: String?

    enum CodingKeys: String, CodingKey {
        case label
        case ontologyTermID = "ontology_term_id"
    }
}

private nonisolated struct CellxgeneTissueLabel: Codable {
    let label: String
    let ontologyTermID: String?
    let tissueType: String?

    enum CodingKeys: String, CodingKey {
        case label
        case ontologyTermID = "ontology_term_id"
        case tissueType = "tissue_type"
    }
}

private nonisolated struct CellxgeneLink: Codable {
    let linkName: String
    let linkType: String
    let linkURL: String

    enum CodingKeys: String, CodingKey {
        case linkName = "link_name"
        case linkType = "link_type"
        case linkURL = "link_url"
    }
}

private nonisolated struct CellxgeneCollectionSearchDataset: Codable {
    let assay: [CellxgeneOntologyLabel]
    let disease: [CellxgeneOntologyLabel]
    let organism: [CellxgeneOntologyLabel]
    let suspensionType: [String]
    let tissue: [CellxgeneTissueLabel]

    enum CodingKeys: String, CodingKey {
        case assay
        case disease
        case organism
        case suspensionType = "suspension_type"
        case tissue
    }
}

private nonisolated struct CellxgeneCollectionSummary: Codable {
    let collectionID: String
    let name: String
    let description: String?
    let datasets: [CellxgeneCollectionSearchDataset]

    enum CodingKeys: String, CodingKey {
        case collectionID = "collection_id"
        case name
        case description
        case datasets
    }
}

private nonisolated struct CellxgeneDatasetDetail: Codable {
    let title: String
    let datasetID: String
    let datasetVersionID: String
    let cellCount: Int?
    let primaryCellCount: Int?
    let meanGenesPerCell: Double?
    let featureCount: Int?
    let donorID: [String]
    let disease: [CellxgeneOntologyLabel]
    let tissue: [CellxgeneTissueLabel]
    let organism: [CellxgeneOntologyLabel]
    let sex: [CellxgeneOntologyLabel]
    let developmentStage: [CellxgeneOntologyLabel]
    let cellType: [CellxgeneOntologyLabel]
    let explorerURL: String?

    enum CodingKeys: String, CodingKey {
        case title
        case datasetID = "dataset_id"
        case datasetVersionID = "dataset_version_id"
        case cellCount = "cell_count"
        case primaryCellCount = "primary_cell_count"
        case meanGenesPerCell = "mean_genes_per_cell"
        case featureCount = "feature_count"
        case donorID = "donor_id"
        case disease
        case tissue
        case organism
        case sex
        case developmentStage = "development_stage"
        case cellType = "cell_type"
        case explorerURL = "explorer_url"
    }
}

private nonisolated struct CellxgeneCollectionDetail: Codable {
    let collectionID: String
    let name: String
    let description: String?
    let doi: String?
    let links: [CellxgeneLink]
    let datasets: [CellxgeneDatasetDetail]

    enum CodingKeys: String, CodingKey {
        case collectionID = "collection_id"
        case name
        case description
        case doi
        case links
        case datasets
    }
}

private nonisolated struct CellxgeneConfigResponse: Decodable {
    let config: CellxgeneConfig
}

private nonisolated struct CellxgeneConfig: Decodable {
    let corporaProps: CellxgeneCorporaProps

    enum CodingKeys: String, CodingKey {
        case corporaProps = "corpora_props"
    }
}

private nonisolated struct CellxgeneCorporaProps: Decodable {
    let citation: String?
    let title: String?
    let schemaVersion: String?

    enum CodingKeys: String, CodingKey {
        case citation
        case title
        case schemaVersion = "schema_version"
    }
}

private nonisolated struct CellxgeneSchemaResponse: Decodable {
    let schema: CellxgeneSchema
}

private nonisolated struct CellxgeneSchema: Decodable {
    let annotations: CellxgeneAnnotations
}

private nonisolated struct CellxgeneAnnotations: Decodable {
    let obs: CellxgeneAxisSchema
}

private nonisolated struct CellxgeneAxisSchema: Decodable {
    let columns: [CellxgeneSchemaColumn]
}

private nonisolated struct CellxgeneSchemaColumn: Decodable {
    let categories: [String]?
    let name: String
    let type: String?
}

private nonisolated struct CellxgeneAtlasBundle {
    let collectionID: String
    let collectionName: String
    let collectionDescription: String?
    let doi: String?
    let citation: String?
    let rawDataLinks: [String]
    let primaryDatasetTitle: String
    let primaryDatasetID: String
    let primaryDatasetVersionID: String
    let donorCount: Int
    let diseaseLabels: [String]
    let tissueLabels: [String]
    let organismLabels: [String]
    let sexLabels: [String]
    let timepointLabels: [String]
    let coarseLabels: [String]
    let fineLabels: [String]
    let glialFineLabels: [String]
    let schemaDiseaseLabels: [String]
    let schemaSexLabels: [String]
    let subdatasets: [CellxgeneAtlasDatasetRow]
    let notes: [String]
}

private nonisolated struct CellxgeneAtlasDatasetRow: Encodable {
    let title: String
    let datasetID: String
    let datasetVersionID: String
    let cellCount: Int
    let primaryCellCount: Int?
    let meanGenesPerCell: Double?
    let featureCount: Int?
    let donorCount: Int
    let diseaseLabels: [String]
    let tissueLabels: [String]
    let organismLabels: [String]
    let sexLabels: [String]
    let developmentStageLabels: [String]
    let cellTypeLabels: [String]
    let explorerURL: String?

    enum CodingKeys: String, CodingKey {
        case title
        case datasetID = "dataset_id"
        case datasetVersionID = "dataset_version_id"
        case cellCount = "cell_count"
        case primaryCellCount = "primary_cell_count"
        case meanGenesPerCell = "mean_genes_per_cell"
        case featureCount = "feature_count"
        case donorCount = "donor_count"
        case diseaseLabels = "disease_labels"
        case tissueLabels = "tissue_labels"
        case organismLabels = "organism_labels"
        case sexLabels = "sex_labels"
        case developmentStageLabels = "development_stage_labels"
        case cellTypeLabels = "cell_type_labels"
        case explorerURL = "explorer_url"
    }
}

private nonisolated struct CellxgeneAtlasInspectionInput: Encodable {
    let provider = "cellxgene-discover"
    let selectedDatasetIDs: [String]
    let collectionID: String
    let collectionName: String
    let collectionDescription: String?
    let doi: String?
    let citation: String?
    let rawDataLinks: [String]
    let primaryDatasetTitle: String
    let primaryDatasetID: String
    let primaryDatasetVersionID: String
    let donorCount: Int
    let diseaseLabels: [String]
    let tissueLabels: [String]
    let organismLabels: [String]
    let sexLabels: [String]
    let timepointLabels: [String]
    let coarseLabels: [String]
    let fineLabels: [String]
    let glialFineLabels: [String]
    let subdatasets: [CellxgeneAtlasDatasetRow]
    let notes: [String]

    enum CodingKeys: String, CodingKey {
        case provider
        case selectedDatasetIDs = "selected_dataset_ids"
        case collectionID = "collection_id"
        case collectionName = "collection_name"
        case collectionDescription = "collection_description"
        case doi
        case citation
        case rawDataLinks = "raw_data_links"
        case primaryDatasetTitle = "primary_dataset_title"
        case primaryDatasetID = "primary_dataset_id"
        case primaryDatasetVersionID = "primary_dataset_version_id"
        case donorCount = "donor_count"
        case diseaseLabels = "disease_labels"
        case tissueLabels = "tissue_labels"
        case organismLabels = "organism_labels"
        case sexLabels = "sex_labels"
        case timepointLabels = "timepoint_labels"
        case coarseLabels = "coarse_labels"
        case fineLabels = "fine_labels"
        case glialFineLabels = "glial_fine_labels"
        case subdatasets
        case notes
    }

    init(from bundle: CellxgeneAtlasBundle, selectedDatasetIDs: [String]) {
        self.selectedDatasetIDs = selectedDatasetIDs
        collectionID = bundle.collectionID
        collectionName = bundle.collectionName
        collectionDescription = bundle.collectionDescription
        doi = bundle.doi
        citation = bundle.citation
        rawDataLinks = bundle.rawDataLinks
        primaryDatasetTitle = bundle.primaryDatasetTitle
        primaryDatasetID = bundle.primaryDatasetID
        primaryDatasetVersionID = bundle.primaryDatasetVersionID
        donorCount = bundle.donorCount
        diseaseLabels = bundle.diseaseLabels
        tissueLabels = bundle.tissueLabels
        organismLabels = bundle.organismLabels
        sexLabels = bundle.sexLabels
        timepointLabels = bundle.timepointLabels
        coarseLabels = bundle.coarseLabels
        fineLabels = bundle.fineLabels
        glialFineLabels = bundle.glialFineLabels
        subdatasets = bundle.subdatasets
        notes = bundle.notes
    }
}

private nonisolated struct CellxgeneAtlasAnalysisInput: Encodable {
    let provider = "cellxgene-discover"
    let selectedDatasetIDs: [String]
    let collectionID: String
    let collectionName: String
    let primaryDatasetTitle: String
    let primaryDatasetID: String
    let primaryDatasetVersionID: String
    let donorCount: Int
    let diseaseLabels: [String]
    let tissueLabels: [String]
    let organismLabels: [String]
    let sexLabels: [String]
    let timepointLabels: [String]
    let coarseLabels: [String]
    let fineLabels: [String]
    let glialFineLabels: [String]
    let schemaDiseaseLabels: [String]
    let schemaSexLabels: [String]
    let subdatasets: [CellxgeneAtlasDatasetRow]
    let notes: [String]

    enum CodingKeys: String, CodingKey {
        case provider
        case selectedDatasetIDs = "selected_dataset_ids"
        case collectionID = "collection_id"
        case collectionName = "collection_name"
        case primaryDatasetTitle = "primary_dataset_title"
        case primaryDatasetID = "primary_dataset_id"
        case primaryDatasetVersionID = "primary_dataset_version_id"
        case donorCount = "donor_count"
        case diseaseLabels = "disease_labels"
        case tissueLabels = "tissue_labels"
        case organismLabels = "organism_labels"
        case sexLabels = "sex_labels"
        case timepointLabels = "timepoint_labels"
        case coarseLabels = "coarse_labels"
        case fineLabels = "fine_labels"
        case glialFineLabels = "glial_fine_labels"
        case schemaDiseaseLabels = "schema_disease_labels"
        case schemaSexLabels = "schema_sex_labels"
        case subdatasets
        case notes
    }

    init(from bundle: CellxgeneAtlasBundle, selectedDatasetIDs: [String]) {
        self.selectedDatasetIDs = selectedDatasetIDs
        collectionID = bundle.collectionID
        collectionName = bundle.collectionName
        primaryDatasetTitle = bundle.primaryDatasetTitle
        primaryDatasetID = bundle.primaryDatasetID
        primaryDatasetVersionID = bundle.primaryDatasetVersionID
        donorCount = bundle.donorCount
        diseaseLabels = bundle.diseaseLabels
        tissueLabels = bundle.tissueLabels
        organismLabels = bundle.organismLabels
        sexLabels = bundle.sexLabels
        timepointLabels = bundle.timepointLabels
        coarseLabels = bundle.coarseLabels
        fineLabels = bundle.fineLabels
        glialFineLabels = bundle.glialFineLabels
        schemaDiseaseLabels = bundle.schemaDiseaseLabels
        schemaSexLabels = bundle.schemaSexLabels
        subdatasets = bundle.subdatasets
        notes = bundle.notes
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }

        return self[index]
    }
}
