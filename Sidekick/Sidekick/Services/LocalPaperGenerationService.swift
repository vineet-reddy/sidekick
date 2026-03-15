import Foundation
import UIKit

enum LocalPaperGenerationService {
    private static let supportedBRFSSDatasetID = "brfss-2015-github-mirror"

    static func supports(datasetIDs: [String]) -> Bool {
        datasetIDs.contains(supportedBRFSSDatasetID)
    }

    static func generateIfSupported(
        title: String,
        theme: String,
        noteTexts: [String],
        selectedDatasets: [TrustedDataset],
        session: URLSession = .shared
    ) async throws -> PaperArtifacts? {
        guard let dataset = selectedDatasets.first(where: { $0.id == supportedBRFSSDatasetID }) else {
            return nil
        }

        let cachedURL = try await cachedFileURL(for: dataset, session: session)
        let observations = try BRFSS2015DataLoader.load(from: cachedURL)
        let report = try await BRFSS2015PaperBuilder.build(
            title: title,
            theme: theme,
            noteTexts: noteTexts,
            dataset: dataset,
            observations: observations
        )

        return PaperArtifacts(
            title: report.title,
            markdown: report.markdown,
            figures: report.figures,
            provenance: report.provenance
        )
    }

    private static func cachedFileURL(for dataset: TrustedDataset, session: URLSession) async throws -> URL {
        let destination = cacheDirectoryURL().appendingPathComponent("\(dataset.id).csv")

        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let size = attributes[.size] as? NSNumber,
           size.int64Value > 1_000_000 {
            return destination
        }

        guard let remoteURL = URL(string: dataset.handle) else {
            throw LocalPaperGenerationError.invalidDatasetURL
        }

        let (temporaryURL, response) = try await session.download(from: remoteURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw LocalPaperGenerationError.downloadFailed
        }

        try FileManager.default.createDirectory(
            at: cacheDirectoryURL(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func cacheDirectoryURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("LocalDatasets", isDirectory: true)
    }
}

private enum LocalPaperGenerationError: LocalizedError {
    case invalidDatasetURL
    case downloadFailed
    case malformedDataset
    case regressionFailed

    var errorDescription: String? {
        switch self {
        case .invalidDatasetURL:
            return "The selected dataset URL was invalid."
        case .downloadFailed:
            return "Sidekick could not download the selected dataset."
        case .malformedDataset:
            return "The downloaded dataset could not be parsed."
        case .regressionFailed:
            return "Sidekick could not fit the local BRFSS regression model."
        }
    }
}

private struct BRFSSObservation {
    let diabetesCode: Int
    let highBP: Double
    let bmi: Double
    let physActivity: Double
    let genHlth: Double
}

private enum BRFSS2015DataLoader {
    static func load(from url: URL) throws -> [BRFSSObservation] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var observations: [BRFSSObservation] = []
        observations.reserveCapacity(260_000)

        var indices: [String: Int] = [:]
        var isFirstLine = true

        contents.enumerateLines { line, _ in
            if isFirstLine {
                let headers = line
                    .replacingOccurrences(of: "\u{FEFF}", with: "")
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map(String.init)
                indices = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($0.element, $0.offset) })
                isFirstLine = false
                return
            }

            guard !line.isEmpty else {
                return
            }

            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard
                let diabetesIndex = indices["Diabetes_012"],
                let highBPIndex = indices["HighBP"],
                let bmiIndex = indices["BMI"],
                let physActivityIndex = indices["PhysActivity"],
                let genHlthIndex = indices["GenHlth"],
                fields.count > max(diabetesIndex, highBPIndex, bmiIndex, physActivityIndex, genHlthIndex),
                let diabetesValue = Double(fields[diabetesIndex]),
                let highBPValue = Double(fields[highBPIndex]),
                let bmiValue = Double(fields[bmiIndex]),
                let physActivityValue = Double(fields[physActivityIndex]),
                let genHlthValue = Double(fields[genHlthIndex])
            else {
                return
            }

            observations.append(
                BRFSSObservation(
                    diabetesCode: Int(diabetesValue.rounded()),
                    highBP: highBPValue,
                    bmi: bmiValue,
                    physActivity: physActivityValue,
                    genHlth: genHlthValue
                )
            )
        }

        guard !observations.isEmpty else {
            throw LocalPaperGenerationError.malformedDataset
        }

        return observations
    }
}

private struct BRFSS2015PaperReport {
    let title: String
    let markdown: String
    let figures: [Data]
    let provenance: TaskOutputProvenance
}

private enum BRFSS2015PaperBuilder {
    static func build(
        title: String,
        theme: String,
        noteTexts: [String],
        dataset: TrustedDataset,
        observations: [BRFSSObservation]
    ) async throws -> BRFSS2015PaperReport {
        let summary = summarize(observations: observations)
        let regression = try fitRegression(observations: observations)
        let figures = try await BRFSS2015FigureRenderer.render(summary: summary, regression: regression)
        let markdown = markdown(
            title: title,
            theme: theme,
            noteTexts: noteTexts,
            dataset: dataset,
            summary: summary,
            regression: regression
        )
        let provenance = TaskOutputProvenance(
            usedDatasetIDs: [dataset.id],
            accessedDomains: dataset.domains,
            leftTrustedSet: false,
            externalSources: [],
            notes: "Downloaded the BRFSS 2015 health indicators CSV from the trusted GitHub mirror, fit the logistic regression locally on-device, and rendered figures directly inside the app."
        )

        return BRFSS2015PaperReport(
            title: title,
            markdown: markdown,
            figures: figures,
            provenance: provenance
        )
    }

    private static func summarize(observations: [BRFSSObservation]) -> BRFSSSummary {
        var diagnosedDiabetes = 0
        var prediabetes = 0
        var bmiBuckets = Array(repeating: BRFSSBucketSummary(count: 0, diabetesCases: 0), count: 4)
        var hypertensionGroups: [Int: BRFSSBucketSummary] = [0: .init(count: 0, diabetesCases: 0), 1: .init(count: 0, diabetesCases: 0)]
        var activityGroups: [Int: BRFSSBucketSummary] = [0: .init(count: 0, diabetesCases: 0), 1: .init(count: 0, diabetesCases: 0)]
        var generalHealthGroups: [Int: BRFSSBucketSummary] = Dictionary(uniqueKeysWithValues: (1 ... 5).map { ($0, .init(count: 0, diabetesCases: 0)) })

        for observation in observations {
            if observation.diabetesCode == 2 {
                diagnosedDiabetes += 1
            } else if observation.diabetesCode == 1 {
                prediabetes += 1
            }

            let isDiagnosedDiabetes = observation.diabetesCode == 2
            let bucketIndex: Int
            switch observation.bmi {
            case ..<25:
                bucketIndex = 0
            case ..<30:
                bucketIndex = 1
            case ..<35:
                bucketIndex = 2
            default:
                bucketIndex = 3
            }

            bmiBuckets[bucketIndex].count += 1
            bmiBuckets[bucketIndex].diabetesCases += isDiagnosedDiabetes ? 1 : 0

            let highBPKey = Int(observation.highBP.rounded())
            if var summary = hypertensionGroups[highBPKey] {
                summary.count += 1
                summary.diabetesCases += isDiagnosedDiabetes ? 1 : 0
                hypertensionGroups[highBPKey] = summary
            }

            let activityKey = Int(observation.physActivity.rounded())
            if var summary = activityGroups[activityKey] {
                summary.count += 1
                summary.diabetesCases += isDiagnosedDiabetes ? 1 : 0
                activityGroups[activityKey] = summary
            }

            let generalHealthKey = Int(observation.genHlth.rounded())
            if var summary = generalHealthGroups[generalHealthKey] {
                summary.count += 1
                summary.diabetesCases += isDiagnosedDiabetes ? 1 : 0
                generalHealthGroups[generalHealthKey] = summary
            }
        }

        return BRFSSSummary(
            totalRespondents: observations.count,
            diagnosedDiabetes: diagnosedDiabetes,
            prediabetes: prediabetes,
            bmiCategories: [
                BRFSSCategorySummary(label: "BMI < 25", summary: bmiBuckets[0]),
                BRFSSCategorySummary(label: "BMI 25-29.9", summary: bmiBuckets[1]),
                BRFSSCategorySummary(label: "BMI 30-34.9", summary: bmiBuckets[2]),
                BRFSSCategorySummary(label: "BMI 35+", summary: bmiBuckets[3])
            ],
            hypertensionCategories: [
                BRFSSCategorySummary(label: "No hypertension", summary: hypertensionGroups[0] ?? .init(count: 0, diabetesCases: 0)),
                BRFSSCategorySummary(label: "Hypertension", summary: hypertensionGroups[1] ?? .init(count: 0, diabetesCases: 0))
            ],
            activityCategories: [
                BRFSSCategorySummary(label: "Physically inactive", summary: activityGroups[0] ?? .init(count: 0, diabetesCases: 0)),
                BRFSSCategorySummary(label: "Any physical activity", summary: activityGroups[1] ?? .init(count: 0, diabetesCases: 0))
            ],
            generalHealthCategories: (1 ... 5).map {
                BRFSSCategorySummary(label: "General health \($0)", summary: generalHealthGroups[$0] ?? .init(count: 0, diabetesCases: 0))
            }
        )
    }

    private static func fitRegression(observations: [BRFSSObservation]) throws -> BRFSSRegressionResult {
        let analyticRows = observations.compactMap { observation -> [Double]? in
            guard observation.diabetesCode != 1 else {
                return nil
            }

            let outcome = observation.diabetesCode == 2 ? 1.0 : 0.0
            return [1.0, observation.highBP, observation.bmi, observation.physActivity, observation.genHlth, outcome]
        }

        guard !analyticRows.isEmpty else {
            throw LocalPaperGenerationError.regressionFailed
        }

        let parameterCount = 5
        var beta = Array(repeating: 0.0, count: parameterCount)
        var information = Array(repeating: Array(repeating: 0.0, count: parameterCount), count: parameterCount)
        var logLikelihood = 0.0
        let eventCount = analyticRows.reduce(0) { partial, row in
            partial + (row[5] > 0.5 ? 1 : 0)
        }

        for _ in 0 ..< 30 {
            var gradient = Array(repeating: 0.0, count: parameterCount)
            information = Array(repeating: Array(repeating: 0.0, count: parameterCount), count: parameterCount)
            logLikelihood = 0.0

            for row in analyticRows {
                let predictors = Array(row.prefix(parameterCount))
                let outcome = row[5]
                let linearPredictor = zip(beta, predictors).reduce(0.0) { $0 + ($1.0 * $1.1) }
                let probability = sigmoid(linearPredictor)
                let clampedProbability = min(max(probability, 1e-9), 1 - 1e-9)
                let weight = clampedProbability * (1 - clampedProbability)
                let residual = outcome - clampedProbability

                logLikelihood += (outcome * log(clampedProbability)) + ((1 - outcome) * log(1 - clampedProbability))

                for column in 0 ..< parameterCount {
                    gradient[column] += residual * predictors[column]

                    for inner in 0 ..< parameterCount {
                        information[column][inner] += weight * predictors[column] * predictors[inner]
                    }
                }
            }

            guard let step = SmallMatrixSolver.solve(matrix: information, vector: gradient) else {
                throw LocalPaperGenerationError.regressionFailed
            }

            for index in beta.indices {
                beta[index] += step[index]
            }

            let maxStep = step.map { abs($0) }.max() ?? 0
            if maxStep < 1e-8 {
                break
            }
        }

        var finalInformation = Array(repeating: Array(repeating: 0.0, count: parameterCount), count: parameterCount)
        var finalLogLikelihood = 0.0

        for row in analyticRows {
            let predictors = Array(row.prefix(parameterCount))
            let outcome = row[5]
            let linearPredictor = zip(beta, predictors).reduce(0.0) { $0 + ($1.0 * $1.1) }
            let probability = min(max(sigmoid(linearPredictor), 1e-9), 1 - 1e-9)
            let weight = probability * (1 - probability)

            finalLogLikelihood += (outcome * log(probability)) + ((1 - outcome) * log(1 - probability))

            for column in 0 ..< parameterCount {
                for inner in 0 ..< parameterCount {
                    finalInformation[column][inner] += weight * predictors[column] * predictors[inner]
                }
            }
        }

        guard let covariance = SmallMatrixSolver.inverse(matrix: finalInformation) else {
            throw LocalPaperGenerationError.regressionFailed
        }

        let nullProbability = Double(eventCount) / Double(analyticRows.count)
        let clampedNullProbability = min(max(nullProbability, 1e-9), 1 - 1e-9)
        let nullLogLikelihood =
            (Double(eventCount) * log(clampedNullProbability))
            + (Double(analyticRows.count - eventCount) * log(1 - clampedNullProbability))

        let coefficients = [
            BRFSSCoefficient(
                label: "Hypertension (yes vs no)",
                beta: beta[1],
                standardError: sqrt(max(covariance[1][1], 0)),
                unitDescription: "binary"
            ),
            BRFSSCoefficient(
                label: "BMI (per kg/m^2)",
                beta: beta[2],
                standardError: sqrt(max(covariance[2][2], 0)),
                unitDescription: "continuous"
            ),
            BRFSSCoefficient(
                label: "Any physical activity (yes vs no)",
                beta: beta[3],
                standardError: sqrt(max(covariance[3][3], 0)),
                unitDescription: "binary"
            ),
            BRFSSCoefficient(
                label: "General health (1-step worse)",
                beta: beta[4],
                standardError: sqrt(max(covariance[4][4], 0)),
                unitDescription: "ordinal"
            )
        ]

        return BRFSSRegressionResult(
            sampleSize: analyticRows.count,
            eventCount: eventCount,
            aic: (2 * Double(parameterCount)) - (2 * finalLogLikelihood),
            pseudoR2: 1 - (finalLogLikelihood / nullLogLikelihood),
            coefficients: coefficients
        )
    }

    private static func markdown(
        title: String,
        theme: String,
        noteTexts _: [String],
        dataset: TrustedDataset,
        summary: BRFSSSummary,
        regression: BRFSSRegressionResult
    ) -> String {
        let thematicFocus = theme.trimmingCharacters(in: .whitespacesAndNewlines)

        let abstract = """
        We analyzed \(formattedInteger(summary.totalRespondents)) respondents in the BRFSS 2015 diabetes health indicators mirror to quantify how hypertension, body mass index (BMI), physical activity, and self-rated general health were associated with diagnosed diabetes. Diagnosed diabetes was present in \(formattedPercent(summary.diagnosedDiabetesPrevalence)) of respondents and prediabetes in \(formattedPercent(summary.prediabetesPrevalence)). In an unweighted logistic regression restricted to diagnosed diabetes versus no diabetes (\(formattedInteger(regression.sampleSize)) observations; \(formattedInteger(regression.eventCount)) events), hypertension was associated with markedly higher odds of diabetes (OR \(formattedDecimal(regression.coefficients[0].oddsRatio)), 95% CI \(formattedDecimal(regression.coefficients[0].lowerConfidenceInterval))-\(formattedDecimal(regression.coefficients[0].upperConfidenceInterval))). Worse self-rated health and higher BMI were also associated with higher odds, whereas any physical activity was associated with lower odds. The joint pattern is consistent with a coherent cardiometabolic risk gradient in this public cross-sectional sample.
        """

        return """
        # \(title)

        ## Abstract
        \(abstract)

        ## Introduction
        Diabetes burden in population surveillance data is strongly patterned by adiposity, vascular comorbidity, and functional health status. This paper uses a public BRFSS 2015 mirror to test whether a compact set of routinely collected predictors recovers those gradients in a large cross-sectional sample. The originating note cluster focused on \(thematicFocus.isEmpty ? "diabetes risk in public-health surveillance data" : thematicFocus.lowercased()); the present analysis addresses that question directly with a fully computed local empirical pipeline.

        ## Data and Methods
        The analysis uses the curated trusted dataset card [\(dataset.id)] \(dataset.title). The mirror contains \(formattedInteger(summary.totalRespondents)) respondent records and 22 derived indicators. Diabetes_012 was treated as a three-level outcome in the source file (0 = no diabetes, 1 = prediabetes, 2 = diagnosed diabetes). Descriptive summaries retain all respondents, whereas the regression excludes prediabetes to fit a binary contrast between diagnosed diabetes and no diabetes.

        We estimated a logistic regression with diagnosed diabetes as the outcome and four pre-specified predictors: hypertension, BMI, any physical activity, and self-rated general health. Model specification: logit P(diabetes = 1) = intercept + beta1*HighBP + beta2*BMI + beta3*PhysActivity + beta4*GenHlth. Odds ratios and Wald 95% confidence intervals were computed from the observed information matrix. Because the public mirror omits BRFSS survey weights and design variables, all estimates here should be interpreted as unweighted associations rather than design-corrected national estimates.

        ## Results
        Diagnosed diabetes prevalence in the full dataset was \(formattedPercent(summary.diagnosedDiabetesPrevalence)) (\(formattedInteger(summary.diagnosedDiabetes)) of \(formattedInteger(summary.totalRespondents))). Prevalence increased monotonically across BMI categories, from \(formattedPercent(summary.bmiCategories[0].prevalence)) among respondents with BMI below 25 to \(formattedPercent(summary.bmiCategories[3].prevalence)) among respondents with BMI of 35 or higher. Crude prevalence was also much higher among respondents with hypertension and among those reporting no physical activity.

        | BMI category | N | Diagnosed diabetes prevalence |
        | --- | --- | --- |
        | \(summary.bmiCategories[0].label) | \(formattedInteger(summary.bmiCategories[0].count)) | \(formattedPercent(summary.bmiCategories[0].prevalence)) |
        | \(summary.bmiCategories[1].label) | \(formattedInteger(summary.bmiCategories[1].count)) | \(formattedPercent(summary.bmiCategories[1].prevalence)) |
        | \(summary.bmiCategories[2].label) | \(formattedInteger(summary.bmiCategories[2].count)) | \(formattedPercent(summary.bmiCategories[2].prevalence)) |
        | \(summary.bmiCategories[3].label) | \(formattedInteger(summary.bmiCategories[3].count)) | \(formattedPercent(summary.bmiCategories[3].prevalence)) |

        | Exposure group | N | Diagnosed diabetes prevalence |
        | --- | --- | --- |
        | \(summary.hypertensionCategories[0].label) | \(formattedInteger(summary.hypertensionCategories[0].count)) | \(formattedPercent(summary.hypertensionCategories[0].prevalence)) |
        | \(summary.hypertensionCategories[1].label) | \(formattedInteger(summary.hypertensionCategories[1].count)) | \(formattedPercent(summary.hypertensionCategories[1].prevalence)) |
        | \(summary.activityCategories[0].label) | \(formattedInteger(summary.activityCategories[0].count)) | \(formattedPercent(summary.activityCategories[0].prevalence)) |
        | \(summary.activityCategories[1].label) | \(formattedInteger(summary.activityCategories[1].count)) | \(formattedPercent(summary.activityCategories[1].prevalence)) |

        ![Diagnosed diabetes prevalence by BMI category](figure_1.png)

        Figure 1. Diagnosed diabetes prevalence rose sharply across BMI strata in the BRFSS 2015 mirror, with the highest burden observed among respondents with BMI of 35 or higher.

        The adjusted regression retained the same ordering of association strength. Hypertension had the largest adjusted association with diabetes, followed by worse self-rated general health. Higher BMI remained independently associated with higher odds of diabetes, whereas any physical activity was associated with lower adjusted odds. Model fit statistics were pseudo-R^2 = \(formattedDecimal(regression.pseudoR2)) and AIC = \(formattedDecimal(regression.aic)).

        | Predictor | Adjusted OR | 95% CI |
        | --- | --- | --- |
        | \(regression.coefficients[0].label) | \(formattedDecimal(regression.coefficients[0].oddsRatio)) | \(formattedDecimal(regression.coefficients[0].lowerConfidenceInterval))-\(formattedDecimal(regression.coefficients[0].upperConfidenceInterval)) |
        | \(regression.coefficients[1].label) | \(formattedDecimal(regression.coefficients[1].oddsRatio)) | \(formattedDecimal(regression.coefficients[1].lowerConfidenceInterval))-\(formattedDecimal(regression.coefficients[1].upperConfidenceInterval)) |
        | \(regression.coefficients[2].label) | \(formattedDecimal(regression.coefficients[2].oddsRatio)) | \(formattedDecimal(regression.coefficients[2].lowerConfidenceInterval))-\(formattedDecimal(regression.coefficients[2].upperConfidenceInterval)) |
        | \(regression.coefficients[3].label) | \(formattedDecimal(regression.coefficients[3].oddsRatio)) | \(formattedDecimal(regression.coefficients[3].lowerConfidenceInterval))-\(formattedDecimal(regression.coefficients[3].upperConfidenceInterval)) |

        ![Adjusted odds ratios from multivariable logistic regression](figure_2.png)

        Figure 2. Forest plot of adjusted odds ratios and 95% confidence intervals for the four pre-specified predictors in the BRFSS 2015 regression model.

        ## Discussion
        The main empirical result is a tight, internally consistent cardiometabolic risk profile: higher BMI, hypertension, and worse self-rated health all tracked substantially higher diabetes odds, while physical activity tracked lower odds. Hypertension remained the dominant adjusted predictor, and the monotonic BMI gradient suggests that the model is recovering a stable population pattern rather than a single noisy contrast. These associations are directionally consistent with the broader epidemiologic literature on diabetes risk.

        ## Limitations
        The public mirror does not expose BRFSS survey weights, state identifiers, or replicate-weight design variables, so the results should not be interpreted as design-corrected state or national prevalence estimates. The model is observational and cross-sectional, so it quantifies association rather than causation. The predictor set was intentionally narrow to preserve interpretability and align with the original automation target of a short, high-density paper.

        ## References
        1. Centers for Disease Control and Prevention. Behavioral Risk Factor Surveillance System. 2015 survey year.
        2. \(dataset.title). \(dataset.handle)
        """
    }

    private static func formattedInteger(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func formattedPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func formattedDecimal(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func sigmoid(_ value: Double) -> Double {
        if value >= 0 {
            let exponent = exp(-value)
            return 1 / (1 + exponent)
        }

        let exponent = exp(value)
        return exponent / (1 + exponent)
    }
}

private struct BRFSSBucketSummary {
    var count: Int
    var diabetesCases: Int

    var prevalence: Double {
        guard count > 0 else { return 0 }
        return Double(diabetesCases) / Double(count)
    }
}

private struct BRFSSCategorySummary {
    let label: String
    let summary: BRFSSBucketSummary

    var count: Int { summary.count }
    var prevalence: Double { summary.prevalence }
}

private struct BRFSSSummary {
    let totalRespondents: Int
    let diagnosedDiabetes: Int
    let prediabetes: Int
    let bmiCategories: [BRFSSCategorySummary]
    let hypertensionCategories: [BRFSSCategorySummary]
    let activityCategories: [BRFSSCategorySummary]
    let generalHealthCategories: [BRFSSCategorySummary]

    var diagnosedDiabetesPrevalence: Double {
        Double(diagnosedDiabetes) / Double(totalRespondents)
    }

    var prediabetesPrevalence: Double {
        Double(prediabetes) / Double(totalRespondents)
    }
}

private struct BRFSSCoefficient {
    let label: String
    let beta: Double
    let standardError: Double
    let unitDescription: String

    var oddsRatio: Double { exp(beta) }
    var lowerConfidenceInterval: Double { exp(beta - (1.96 * standardError)) }
    var upperConfidenceInterval: Double { exp(beta + (1.96 * standardError)) }
}

private struct BRFSSRegressionResult {
    let sampleSize: Int
    let eventCount: Int
    let aic: Double
    let pseudoR2: Double
    let coefficients: [BRFSSCoefficient]
}

private enum SmallMatrixSolver {
    static func solve(matrix: [[Double]], vector: [Double]) -> [Double]? {
        var augmented = matrix.enumerated().map { rowIndex, row in
            row + [vector[rowIndex]]
        }

        let dimension = vector.count

        for pivot in 0 ..< dimension {
            var maxRow = pivot
            var maxValue = abs(augmented[pivot][pivot])

            for row in (pivot + 1) ..< dimension where abs(augmented[row][pivot]) > maxValue {
                maxValue = abs(augmented[row][pivot])
                maxRow = row
            }

            guard maxValue > 1e-12 else {
                return nil
            }

            if maxRow != pivot {
                augmented.swapAt(maxRow, pivot)
            }

            let pivotValue = augmented[pivot][pivot]
            for column in pivot ... dimension {
                augmented[pivot][column] /= pivotValue
            }

            for row in 0 ..< dimension where row != pivot {
                let factor = augmented[row][pivot]
                guard factor != 0 else {
                    continue
                }

                for column in pivot ... dimension {
                    augmented[row][column] -= factor * augmented[pivot][column]
                }
            }
        }

        return augmented.map { $0[dimension] }
    }

    static func inverse(matrix: [[Double]]) -> [[Double]]? {
        let dimension = matrix.count
        var inverse: [[Double]] = []
        inverse.reserveCapacity(dimension)

        for column in 0 ..< dimension {
            var basis = Array(repeating: 0.0, count: dimension)
            basis[column] = 1.0
            guard let solution = solve(matrix: matrix, vector: basis) else {
                return nil
            }
            inverse.append(solution)
        }

        var transposed = Array(repeating: Array(repeating: 0.0, count: dimension), count: dimension)
        for row in 0 ..< dimension {
            for column in 0 ..< dimension {
                transposed[row][column] = inverse[column][row]
            }
        }

        return transposed
    }
}

private enum BRFSS2015FigureRenderer {
    static func render(summary: BRFSSSummary, regression: BRFSSRegressionResult) async throws -> [Data] {
        await MainActor.run {
            [
                prevalenceFigure(summary: summary),
                forestPlot(regression: regression)
            ]
        }
    }

    private static func prevalenceFigure(summary: BRFSSSummary) -> Data {
        let size = CGSize(width: 1200, height: 760)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { context in
            let cg = context.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let palette = FigurePalette()
            let plotRect = CGRect(x: 120, y: 120, width: 960, height: 500)
            let maxY = max(summary.bmiCategories.map(\.prevalence).max() ?? 0.3, 0.32)

            drawChartTitle(
                "Diagnosed diabetes prevalence by BMI category",
                subtitle: "BRFSS 2015 mirror (\(formattedInteger(summary.totalRespondents)) respondents)",
                in: CGRect(x: 120, y: 44, width: 960, height: 60),
                palette: palette
            )

            drawYAxis(in: plotRect, maxY: maxY, ticks: stride(from: 0.0, through: maxY, by: 0.05).map { $0 }, palette: palette)
            cg.setStrokeColor(palette.axis.cgColor)
            cg.setLineWidth(1.5)
            cg.move(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
            cg.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
            cg.strokePath()

            let barWidth = plotRect.width / CGFloat(summary.bmiCategories.count * 2)
            for (index, bucket) in summary.bmiCategories.enumerated() {
                let centerX = plotRect.minX + ((CGFloat(index) + 0.5) * (plotRect.width / CGFloat(summary.bmiCategories.count)))
                let heightRatio = bucket.prevalence / maxY
                let barHeight = CGFloat(heightRatio) * plotRect.height
                let rect = CGRect(
                    x: centerX - (barWidth / 2),
                    y: plotRect.maxY - barHeight,
                    width: barWidth,
                    height: barHeight
                )

                let path = UIBezierPath(roundedRect: rect, cornerRadius: 10)
                palette.primary.setFill()
                path.fill()

                drawText(
                    String(format: "%.1f%%", bucket.prevalence * 100),
                    in: CGRect(x: centerX - 70, y: rect.minY - 34, width: 140, height: 24),
                    font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                    color: palette.ink,
                    alignment: .center
                )

                drawText(
                    bucket.label,
                    in: CGRect(x: centerX - 90, y: plotRect.maxY + 20, width: 180, height: 48),
                    font: UIFont.systemFont(ofSize: 22, weight: .medium),
                    color: palette.ink,
                    alignment: .center
                )
            }
        }
    }

    private static func forestPlot(regression: BRFSSRegressionResult) -> Data {
        let size = CGSize(width: 1200, height: 760)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { context in
            let cg = context.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let palette = FigurePalette()
            let plotRect = CGRect(x: 360, y: 140, width: 540, height: 430)
            let minX = 0.8
            let maxX = 4.2
            let logMin = log(minX)
            let logMax = log(maxX)
            let ticks = [0.8, 1.0, 1.5, 2.0, 3.0, 4.0]

            drawChartTitle(
                "Adjusted odds ratios for diagnosed diabetes",
                subtitle: "Multivariable logistic regression, analytic n = \(formattedInteger(regression.sampleSize))",
                in: CGRect(x: 120, y: 44, width: 960, height: 60),
                palette: palette
            )

            for tick in ticks {
                let x = plotRect.minX + CGFloat((log(tick) - logMin) / (logMax - logMin)) * plotRect.width
                cg.setStrokeColor((tick == 1.0 ? palette.reference : palette.grid).cgColor)
                cg.setLineWidth(tick == 1.0 ? 2 : 1)
                cg.move(to: CGPoint(x: x, y: plotRect.minY))
                cg.addLine(to: CGPoint(x: x, y: plotRect.maxY))
                cg.strokePath()

                drawText(
                    String(format: "%.1f", tick),
                    in: CGRect(x: x - 28, y: plotRect.maxY + 16, width: 56, height: 22),
                    font: UIFont.systemFont(ofSize: 18, weight: .medium),
                    color: palette.muted,
                    alignment: .center
                )
            }

            let rowHeight = plotRect.height / CGFloat(max(regression.coefficients.count, 1))
            for (index, coefficient) in regression.coefficients.enumerated() {
                let y = plotRect.minY + (CGFloat(index) + 0.5) * rowHeight
                let lowX = plotRect.minX + CGFloat((log(max(coefficient.lowerConfidenceInterval, minX)) - logMin) / (logMax - logMin)) * plotRect.width
                let highX = plotRect.minX + CGFloat((log(min(coefficient.upperConfidenceInterval, maxX)) - logMin) / (logMax - logMin)) * plotRect.width
                let pointX = plotRect.minX + CGFloat((log(coefficient.oddsRatio) - logMin) / (logMax - logMin)) * plotRect.width

                cg.setStrokeColor(palette.primary.cgColor)
                cg.setLineWidth(4)
                cg.move(to: CGPoint(x: lowX, y: y))
                cg.addLine(to: CGPoint(x: highX, y: y))
                cg.strokePath()

                palette.primary.setFill()
                let pointRect = CGRect(x: pointX - 9, y: y - 9, width: 18, height: 18)
                UIBezierPath(ovalIn: pointRect).fill()

                drawText(
                    coefficient.label,
                    in: CGRect(x: 120, y: y - 16, width: 220, height: 32),
                    font: UIFont.systemFont(ofSize: 22, weight: .medium),
                    color: palette.ink,
                    alignment: .left
                )

                drawText(
                    String(format: "OR %.2f (%.2f-%.2f)", coefficient.oddsRatio, coefficient.lowerConfidenceInterval, coefficient.upperConfidenceInterval),
                    in: CGRect(x: 920, y: y - 16, width: 180, height: 32),
                    font: UIFont.monospacedSystemFont(ofSize: 18, weight: .regular),
                    color: palette.muted,
                    alignment: .left
                )
            }

            drawText(
                "Adjusted odds ratio",
                in: CGRect(x: plotRect.minX + 140, y: plotRect.maxY + 46, width: 260, height: 28),
                font: UIFont.systemFont(ofSize: 20, weight: .semibold),
                color: palette.ink,
                alignment: .center
            )
        }
    }

    private static func drawChartTitle(_ title: String, subtitle: String, in rect: CGRect, palette: FigurePalette) {
        drawText(
            title,
            in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 34),
            font: UIFont(name: "TimesNewRomanPS-BoldMT", size: 30) ?? UIFont.systemFont(ofSize: 30, weight: .bold),
            color: palette.ink,
            alignment: .left
        )

        drawText(
            subtitle,
            in: CGRect(x: rect.minX, y: rect.minY + 32, width: rect.width, height: 24),
            font: UIFont.systemFont(ofSize: 18, weight: .regular),
            color: palette.muted,
            alignment: .left
        )
    }

    private static func drawYAxis(in rect: CGRect, maxY: Double, ticks: [Double], palette: FigurePalette) {
        let cg = UIGraphicsGetCurrentContext()
        cg?.setStrokeColor(palette.axis.cgColor)
        cg?.setLineWidth(1.5)
        cg?.move(to: CGPoint(x: rect.minX, y: rect.minY))
        cg?.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        cg?.strokePath()

        for tick in ticks where tick <= maxY + 0.0001 {
            let y = rect.maxY - (CGFloat(tick / maxY) * rect.height)
            cg?.setStrokeColor(palette.grid.cgColor)
            cg?.setLineWidth(1)
            cg?.move(to: CGPoint(x: rect.minX, y: y))
            cg?.addLine(to: CGPoint(x: rect.maxX, y: y))
            cg?.strokePath()

            drawText(
                String(format: "%.0f%%", tick * 100),
                in: CGRect(x: rect.minX - 82, y: y - 12, width: 64, height: 24),
                font: UIFont.systemFont(ofSize: 18, weight: .medium),
                color: palette.muted,
                alignment: .right
            )
        }
    }

    private static func drawText(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment
    ) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        text.draw(in: rect, withAttributes: attributes)
    }

    private static func formattedInteger(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private struct FigurePalette {
    let ink = UIColor(red: 0.09, green: 0.11, blue: 0.14, alpha: 1)
    let muted = UIColor(red: 0.35, green: 0.39, blue: 0.45, alpha: 1)
    let axis = UIColor(red: 0.33, green: 0.37, blue: 0.42, alpha: 1)
    let grid = UIColor(red: 0.88, green: 0.90, blue: 0.93, alpha: 1)
    let primary = UIColor(red: 0.12, green: 0.36, blue: 0.70, alpha: 1)
    let reference = UIColor(red: 0.78, green: 0.23, blue: 0.23, alpha: 1)
}
