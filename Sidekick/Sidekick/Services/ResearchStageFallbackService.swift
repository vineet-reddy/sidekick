import Foundation
import zlib

nonisolated struct ResearchStageFallbackInput {
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

    init(session: URLSession = .shared) {
        self.session = session
    }

    func supportsFallback(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) -> Bool {
        supportsGlioblastomaCBioPortalBundle(
            datasetIDs: datasetIDs,
            noteTexts: noteTexts,
            theme: theme
        )
    }

    func inspectionInput(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) async throws -> ResearchStageFallbackInput? {
        guard supportsGlioblastomaCBioPortalBundle(datasetIDs: datasetIDs, noteTexts: noteTexts, theme: theme) else {
            return nil
        }

        let bundle = try await gbmBundle()
        let inspection = GBMCBioPortalInspectionInput(from: bundle, selectedDatasetIDs: datasetIDs)
        return ResearchStageFallbackInput(
            providerLabel: "cBioPortal TCGA-GBM public cohort",
            promptJSON: try encodeCompactJSON(inspection)
        )
    }

    func analysisInput(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) async throws -> ResearchStageFallbackInput? {
        guard supportsGlioblastomaCBioPortalBundle(datasetIDs: datasetIDs, noteTexts: noteTexts, theme: theme) else {
            return nil
        }

        let bundle = try await gbmBundle()
        let analysis = GBMCBioPortalAnalysisInput(from: bundle, selectedDatasetIDs: datasetIDs)
        return ResearchStageFallbackInput(
            providerLabel: "cBioPortal TCGA-GBM public cohort",
            promptJSON: try encodeCompactJSON(analysis)
        )
    }

    func bundledAnalysisInput(
        datasetIDs: [String],
        noteTexts: [String],
        theme: String
    ) async throws -> ResearchStageFallbackInput? {
        guard supportsGlioblastomaCBioPortalBundle(datasetIDs: datasetIDs, noteTexts: noteTexts, theme: theme) else {
            return nil
        }

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
            providerLabel: "cBioPortal TCGA-GBM public cohort",
            promptJSON: promptText
        )
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

        let combinedText = ([theme] + noteTexts)
            .joined(separator: " ")
            .lowercased()

        let keywords = [
            "glioblast",
            " gbm",
            "tcga-gbm",
            "idh1",
            "egfr",
            "mgmt",
            "neuro-oncology",
            "neuro oncology"
        ]

        return keywords.contains(where: combinedText.contains)
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
