import Foundation

enum PaperHTMLBuilder {
    static func html(
        for paper: Paper,
        figureCaptions: [String] = [],
        plan: ResearchPlanArtifact? = nil,
        analysis: ResearchAnalysisArtifact? = nil
    ) -> String {
        let normalizedMarkdown = PaperContentNormalizer.normalize(
            markdown: paper.markdown,
            title: paper.title,
            figureCaptions: figureCaptions,
            plan: plan,
            analysis: analysis
        )
        var html = MarkdownHTMLRenderer.render(markdown: normalizedMarkdown)
        html = replaceFigureSources(in: html, figures: paper.figureData)
        html = stylizeFigures(in: html)
        html = mergeFigureCaptions(in: html)
        html = stylizeAbstract(in: html)

        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            @page {
              size: 8.5in 11in;
              margin: 0.82in 0.78in 0.9in;
            }
            body {
              margin: 0;
              padding: 0;
              background: #ffffff;
              color: #000000;
              font-family: "Times New Roman", Times, serif;
              font-size: 10.5pt;
              line-height: 1.34;
            }
            article {
              margin: 0;
              padding: 0;
            }
            header.paper-header {
              margin: 0 0 18pt;
              text-align: center;
            }
            h1, h2, h3 {
              font-family: "Times New Roman", Times, serif;
              font-weight: 700;
              color: #000000;
              line-height: 1.2;
            }
            h1 {
              margin: 0;
              font-size: 16pt;
            }
            h2 {
              margin: 18pt 0 7pt;
              font-size: 11pt;
              font-variant: small-caps;
              letter-spacing: 0.03em;
            }
            h3 {
              margin: 14pt 0 6pt;
              font-size: 10.5pt;
            }
            p, li {
              color: #000000;
              font-size: 10.5pt;
              line-height: 1.34;
            }
            p {
              margin: 0 0 0.62em;
              text-align: justify;
              text-indent: 1.15em;
            }
            h2 + p,
            h3 + p,
            .abstract p,
            li p,
            figure + p,
            table + p {
              text-indent: 0;
            }
            ul, ol {
              margin: 0.28em 0 0.95em 1.25em;
              padding: 0;
            }
            li { margin: 0.2em 0; }
            code, pre {
              font-family: "SFMono-Regular", Menlo, Consolas, monospace;
            }
            code {
              font-size: 0.9em;
            }
            pre {
              margin: 0.9em 0 1.1em;
              padding: 10px 11px;
              overflow-x: auto;
              border: 0.5px solid #000000;
            }
            blockquote {
              margin: 0.9em 0;
              padding: 0 0 0 12px;
              border-left: 1px solid #444444;
              color: #222222;
            }
            a {
              color: #000000;
              text-decoration: underline;
            }
            .abstract {
              margin: 0 0 14pt;
            }
            .abstract h2 {
              margin: 0 0 6pt;
              text-align: center;
            }
            .abstract p {
              margin-bottom: 0;
              text-indent: 0;
            }
            figure.paper-figure,
            figure.missing-figure {
              margin: 1.1em auto 1.2em;
              text-align: center;
              break-inside: avoid;
              page-break-inside: avoid;
            }
            figure.paper-figure img {
              display: block;
              max-width: 100%;
              width: auto;
              height: auto;
              max-height: 3.9in;
              margin: 0 auto 6px;
              border: 0.5px solid #111111;
            }
            figcaption {
              color: #111111;
              font-size: 9pt;
              line-height: 1.28;
              text-align: left;
            }
            .missing-figure__box {
              display: flex;
              align-items: center;
              justify-content: center;
              min-height: 120px;
              margin-bottom: 6px;
              border: 0.5px dashed #666666;
              color: #444444;
              font-size: 9pt;
            }
            .equation {
              margin: 1.0em auto;
              padding: 0.4em 0.6em;
              max-width: 100%;
              overflow-x: auto;
              color: #000000;
              font-family: "Times New Roman", Times, serif;
              font-size: 10pt;
              line-height: 1.3;
              text-align: center;
              white-space: pre-wrap;
            }
            table.paper-table {
              width: 100%;
              margin: 0.85em 0 1.1em;
              border-collapse: collapse;
              border-top: 1.3px solid #000000;
              border-bottom: 1.3px solid #000000;
              font-size: 9.1pt;
            }
            table.paper-table th,
            table.paper-table td {
              padding: 4px 5px;
              border: none;
              text-align: left;
              vertical-align: top;
            }
            table.paper-table thead th {
              font-weight: 700;
              border-bottom: 0.7px solid #000000;
            }
            table.paper-table tbody tr + tr td {
              border-top: 0.35px solid rgba(0, 0, 0, 0.18);
            }
          </style>
        </head>
        <body>
          <article>
            <header class="paper-header">
              <h1>\(escapeHTML(paper.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Paper" : paper.title))</h1>
            </header>
            \(html)
          </article>
        </body>
        </html>
        """
    }

    private static func replaceFigureSources(in html: String, figures: [Data]) -> String {
        var updated = html

        for (index, data) in figures.enumerated() {
            let filename = "figure_\(index + 1).png"
            let replacement = "data:image/png;base64,\(data.base64EncodedString())"
            updated = updated.replacingOccurrences(
                of: "src=\"\(filename)\"",
                with: "src=\"\(replacement)\""
            )
        }

        return updated
    }

    private static func stylizeAbstract(in html: String) -> String {
        replacing(
            pattern: #"(?s)<h2>Abstract</h2>\s*<p>(.*?)</p>"#,
            in: html,
            template: #"<section class="abstract"><h2>Abstract</h2><p>$1</p></section>"#
        )
    }

    private static func stylizeFigures(in html: String) -> String {
        let withRealFigures = replacing(
            pattern: #"(?s)<p><img alt="([^"]*)" src="(data:image/[^"]+)" /></p>"#,
            in: html,
            template: #"<figure class="paper-figure"><img alt="$1" src="$2" /><figcaption>$1</figcaption></figure>"#
        )

        return replacing(
            pattern: #"(?s)<p><img alt="([^"]*)" src="figure_[^"]+" /></p>"#,
            in: withRealFigures,
            template: #"<figure class="missing-figure"><div class="missing-figure__box">Figure asset unavailable in this build.</div><figcaption>$1</figcaption></figure>"#
        )
    }

    private static func mergeFigureCaptions(in html: String) -> String {
        replacing(
            pattern: #"(?s)(<figure class="(?:paper-figure|missing-figure)">.*?<figcaption>)(.*?)(</figcaption></figure>)\s*<p><strong>(Figure\s+\d+\.)</strong>\s*(.*?)</p>"#,
            in: html,
            template: #"$1$4 $5$3"#
        )
    }

    private static func replacing(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum PaperContentNormalizer {
    private static let expandedManuscriptWordThreshold = 2_200

    static func normalize(
        markdown: String,
        title: String? = nil,
        figureCaptions: [String] = [],
        plan: ResearchPlanArtifact? = nil,
        analysis: ResearchAnalysisArtifact? = nil
    ) -> String {
        var value = markdown

        if let decoded = decodeJSONStringFragment(markdown) {
            value = decoded
        } else {
            value = value
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\/", with: "/")
        }

        value = strippingLeadingTitle(from: value, title: title)

        value = replacing(
            pattern: #"【[^】]+】"#,
            in: value,
            template: ""
        )

        value = replacing(
            pattern: #"(?m)^[ \t]*---[ \t]*\n?"#,
            in: value,
            template: ""
        )

        value = replacing(
            pattern: #"!\[([^\]]*)\]\((?:[^)\n]*/)?(figure_\d+\.png)\)"#,
            in: value,
            template: "![$1]($2)"
        )

        value = replacing(
            pattern: #"(?m)^Figure\s+`?(figure_\d+\.png)`?\s+shows\s+(.+?)(?:\.)?$"#,
            in: value,
            template: "![$2]($1)"
        )

        value = replacing(
            pattern: #"(?im)^(#{1,6})\s+\d+(?:\.\d+)*\.?\s+"#,
            in: value,
            template: "$1 "
        )

        value = replacing(
            pattern: #"(?i)\bthis draft\b"#,
            in: value,
            template: "this paper"
        )

        value = replacing(
            pattern: #"\[\[CITE:([A-Za-z0-9_, -]+)\]\]"#,
            in: value,
            template: "[$1]"
        )

        value = replacing(
            pattern: #"\[\[REF:fig:[^\]]+\]\]"#,
            in: value,
            template: "Figure"
        )

        value = replacing(
            pattern: #"\[\[REF:tab:[^\]]+\]\]"#,
            in: value,
            template: "Table"
        )

        value = materializeBareFigureReferences(in: value, figureCaptions: figureCaptions)
        value = enrichedMarkdownIfNeeded(
            value,
            title: title,
            plan: plan,
            analysis: analysis
        )

        value = droppingSections(
            titled: [
                "reproducibility checks",
                "execution log",
                "artifact manifest",
                "repository artifacts",
                "tool trace",
                "tool traces",
                "next steps"
            ],
            from: value
        )

        while value.contains("\n\n\n") {
            value = value.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingLeadingTitle(from markdown: String, title: String?) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return markdown
        }

        var lines = markdown.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return markdown
        }

        let normalizedFirst = first.lowercased()
        let acceptedTitles = [
            title.lowercased(),
            "# \(title)".lowercased(),
            "## \(title)".lowercased(),
            "### \(title)".lowercased()
        ]

        guard acceptedTitles.contains(normalizedFirst) else {
            return markdown
        }

        lines.removeFirst()
        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeFirst()
        }

        return lines.joined(separator: "\n")
    }

    private static func materializeBareFigureReferences(
        in markdown: String,
        figureCaptions: [String]
    ) -> String {
        guard !figureCaptions.isEmpty else {
            return markdown
        }

        let figureMetadata = figureCaptions.enumerated().map { index, caption in
            FigureReference(
                filename: "figure_\(index + 1).png",
                label: "Figure \(index + 1)",
                caption: caption.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let explicitFigureFilenames = Set(
            figureMetadata.compactMap { metadata in
                markdown.contains("](\(metadata.filename))") ? metadata.filename : nil
            }
        )

        var currentHeading: String?
        var insertedFigures = Set<String>()
        var output: [String] = []

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let heading = markdownHeadingTitle(from: trimmed) {
                currentHeading = heading.lowercased()
            }

            var processedLine = line
            var mentionedFigures: [FigureReference] = []

            for metadata in figureMetadata where !explicitFigureFilenames.contains(metadata.filename) {
                guard processedLine.contains(metadata.filename) else {
                    continue
                }

                processedLine = replaceFigureReferenceToken(
                    in: processedLine,
                    filename: metadata.filename,
                    label: metadata.label
                )
                mentionedFigures.append(metadata)
            }

            output.append(processedLine)

            guard currentHeading != "abstract" else {
                continue
            }

            for metadata in mentionedFigures where !insertedFigures.contains(metadata.filename) {
                if output.last?.isEmpty == false {
                    output.append("")
                }
                output.append("![\(metadata.altText)](\(metadata.filename))")
                output.append("")
                insertedFigures.insert(metadata.filename)
            }
        }

        for metadata in figureMetadata
        where !explicitFigureFilenames.contains(metadata.filename) && !insertedFigures.contains(metadata.filename) {
            if output.last?.isEmpty == false {
                output.append("")
            }
            output.append("![\(metadata.altText)](\(metadata.filename))")
            output.append("")
        }

        return output.joined(separator: "\n")
    }

    private static func enrichedMarkdownIfNeeded(
        _ markdown: String,
        title: String?,
        plan: ResearchPlanArtifact?,
        analysis: ResearchAnalysisArtifact?
    ) -> String {
        guard let analysis else {
            return markdown
        }

        let needsExpansion = markdownWordCount(markdown) < expandedManuscriptWordThreshold
        let needsTables = !analysis.tables.isEmpty && !containsTable(in: markdown)
        let needsLimitations = !analysis.limitations.isEmpty && !containsHeading("limitations", in: markdown)

        guard needsExpansion || needsTables || needsLimitations else {
            return markdown
        }

        var sections: [String] = []

        if needsExpansion {
            if let objectiveSection = studyObjectiveSection(from: plan) {
                sections.append(objectiveSection)
            }
            if let cohortSection = cohortDetailSection(from: analysis.datasetManifest) {
                sections.append(cohortSection)
            }
            if let dataAssemblySection = dataAssemblySection(
                from: plan,
                manifest: analysis.datasetManifest
            ) {
                sections.append(dataAssemblySection)
            }
            if let methodsSection = methodsDetailSection(from: plan, analysis: analysis) {
                sections.append(methodsSection)
            }
            if let summarySection = analysisOverviewSection(from: analysis) {
                sections.append(summarySection)
            }
            if let figureSection = figureContextSection(from: plan, analysis: analysis) {
                sections.append(figureSection)
            }
            if let findingsSection = findingsDetailSection(from: analysis.findings) {
                sections.append(findingsSection)
            }
            if let robustnessSection = robustnessSection(from: plan) {
                sections.append(robustnessSection)
            }
        }

        if needsTables, let tablesSection = tablesSection(from: analysis.tables) {
            sections.append(tablesSection)
        }

        if needsLimitations, let limitationsSection = limitationsSection(from: analysis.limitations) {
            sections.append(limitationsSection)
        }

        guard !sections.isEmpty else {
            return markdown
        }

        return insertingSupplementarySections(
            sections,
            into: markdown,
            title: title
        )
    }

    private static func cohortDetailSection(from manifest: ResearchDatasetManifest) -> String? {
        var paragraphs: [String] = []

        let sampleDescription = manifest.sampleDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sampleDescription.isEmpty {
            paragraphs.append(sampleDescription)
        }

        if let rowCount = manifest.rowCount {
            paragraphs.append("The analyzed slice contained \(formattedCount(rowCount)) records or cells in the checkpointed study population.")
        }

        if !manifest.dataSources.isEmpty {
            paragraphs.append("Primary data sources for the final manuscript were \(serialSentence(for: manifest.dataSources)).")
        }

        if !manifest.selectedVariables.isEmpty {
            paragraphs.append("Key analytic variables retained for the manuscript included \(serialSentence(for: manifest.selectedVariables)).")
        }

        let qualityNotes = manifest.qualityNotes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !qualityNotes.isEmpty {
            paragraphs.append("Important data-quality considerations included \(serialSentence(for: Array(qualityNotes.prefix(4)))).")
        }

        guard !paragraphs.isEmpty else {
            return nil
        }

        return """
        ## Cohort and Data Detail

        \(paragraphs.joined(separator: "\n\n"))
        """
    }

    private static func studyObjectiveSection(from plan: ResearchPlanArtifact?) -> String? {
        guard let plan else {
            return nil
        }

        var paragraphs: [String] = []

        let question = plan.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty {
            paragraphs.append("The study was organized around the following question: \(ensuredSentence(question))")
        }

        let hypotheses = plan.hypotheses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !hypotheses.isEmpty {
            let narrative = hypotheses.enumerated().map { index, hypothesis in
                "\(ordinalLead(index)) \(ensuredSentence(hypothesis))"
            }.joined(separator: " ")
            paragraphs.append("The prespecified working hypotheses framed the analysis before any manuscript prose was written. \(narrative)")
        }

        guard !paragraphs.isEmpty else {
            return nil
        }

        return """
        ## Study Objective and Hypotheses

        \(paragraphs.joined(separator: "\n\n"))
        """
    }

    private static func dataAssemblySection(
        from plan: ResearchPlanArtifact?,
        manifest: ResearchDatasetManifest
    ) -> String? {
        var paragraphs: [String] = []

        if let plan, !plan.datasetNeeds.isEmpty {
            paragraphs.append(contentsOf: plan.datasetNeeds.prefix(3).compactMap { need in
                var sentences: [String] = []

                let datasetID = need.datasetID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if datasetID.isEmpty {
                    sentences.append("The \(need.role) analytic source supplied the core variables required for the staged manuscript.")
                } else {
                    sentences.append("The \(need.role) analytic source was \(datasetID), which supplied the core variables required for the staged manuscript.")
                }

                if !need.variables.isEmpty {
                    sentences.append("Requested variables included \(serialSentence(for: Array(need.variables.prefix(8)))).")
                }

                let rationale = need.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rationale.isEmpty {
                    sentences.append(ensuredSentence(rationale))
                }

                guard !sentences.isEmpty else {
                    return nil
                }

                return sentences.joined(separator: " ")
            })
        }

        if paragraphs.isEmpty, !manifest.primaryDatasetIDs.isEmpty {
            paragraphs.append("The final paper drew on \(serialSentence(for: manifest.primaryDatasetIDs)) as the primary checkpointed data source.")
        }

        guard !paragraphs.isEmpty else {
            return nil
        }

        return """
        ## Data Assembly and Variable Definition

        \(paragraphs.joined(separator: "\n\n"))
        """
    }

    private static func methodsDetailSection(
        from plan: ResearchPlanArtifact?,
        analysis: ResearchAnalysisArtifact
    ) -> String? {
        var paragraphs: [String] = []

        if let executionNotes = plan?.executionNotes.trimmingCharacters(in: .whitespacesAndNewlines),
           !executionNotes.isEmpty {
            paragraphs.append(executionNotes)
        }

        if let plan, !plan.candidateMethods.isEmpty {
            paragraphs.append("The staged analysis workflow emphasized \(serialSentence(for: Array(plan.candidateMethods.prefix(4)))).")
        }

        if !analysis.tables.isEmpty {
            let tableTitles = analysis.tables.map(\.title).filter { !$0.isEmpty }
            if !tableTitles.isEmpty {
                paragraphs.append("Structured empirical outputs were checkpointed as \(serialSentence(for: tableTitles)).")
            }
        }

        guard !paragraphs.isEmpty else {
            return nil
        }

        return """
        ## Analytical Detail

        \(paragraphs.joined(separator: "\n\n"))
        """
    }

    private static func analysisOverviewSection(from analysis: ResearchAnalysisArtifact) -> String? {
        let summary = analysis.narrativeSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            return nil
        }

        return """
        ## Analysis Overview

        \(ensuredSentence(summary))
        """
    }

    private static func figureContextSection(
        from plan: ResearchPlanArtifact?,
        analysis: ResearchAnalysisArtifact
    ) -> String? {
        var paragraphs: [String] = []

        let tableTitles = analysis.tables
            .map(\.title)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for figure in analysis.figures.prefix(3) {
            var sentences: [String] = []
            let caption = figure.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchedPlan = matchingPlannedFigure(for: figure.filename, in: plan)

            if caption.isEmpty {
                sentences.append("The final manuscript includes \(figure.filename) as a retained figure artifact.")
            } else {
                sentences.append("The final manuscript includes \(figure.filename), captioned \"\(caption)\".")
            }

            if let matchedPlan {
                let title = matchedPlan.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    sentences.append("This corresponds to the planned visualization titled \"\(title)\".")
                }

                let purpose = matchedPlan.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
                if !purpose.isEmpty {
                    sentences.append(ensuredSentence(purpose))
                }
            }

            if !tableTitles.isEmpty {
                sentences.append("It should be interpreted alongside \(serialSentence(for: Array(tableTitles.prefix(2)))) so that the visual pattern can be compared with the checkpointed numeric estimates.")
            } else {
                sentences.append("Its purpose is to complement the narrative findings with a direct visual summary of the checkpointed empirical pattern.")
            }

            paragraphs.append(sentences.joined(separator: " "))
        }

        guard !paragraphs.isEmpty else {
            return nil
        }

        return """
        ## Figure Context

        \(paragraphs.joined(separator: "\n\n"))
        """
    }

    private static func findingsDetailSection(from findings: [ResearchFinding]) -> String? {
        let paragraphs = findings.compactMap { finding -> String? in
            let claim = finding.claim.trimmingCharacters(in: .whitespacesAndNewlines)
            let estimate = finding.estimate.trimmingCharacters(in: .whitespacesAndNewlines)
            let uncertainty = finding.uncertainty.trimmingCharacters(in: .whitespacesAndNewlines)
            let evidence = finding.evidence.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !claim.isEmpty else {
                return nil
            }

            var sentences = [claim]
            if !estimate.isEmpty {
                sentences.append("The staged estimate was \(estimate).")
            }
            if !uncertainty.isEmpty {
                sentences.append("Reported uncertainty was \(uncertainty).")
            }
            if !evidence.isEmpty {
                sentences.append("The underlying evidence was \(evidence).")
            }
            if let supports = finding.supportsHypothesis {
                sentences.append(
                    supports
                        ? "This checkpoint supported the corresponding working hypothesis."
                        : "This checkpoint did not support the corresponding working hypothesis."
                )
            }

            return sentences.joined(separator: " ")
        }

        guard !paragraphs.isEmpty else {
            return nil
        }

        return """
        ## Expanded Results Detail

        \(paragraphs.joined(separator: "\n\n"))
        """
    }

    private static func robustnessSection(from plan: ResearchPlanArtifact?) -> String? {
        guard let plan else {
            return nil
        }

        let cleaned = plan.risks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else {
            return nil
        }

        let intro = "The execution plan carried forward several pre-analysis risks that shape how the final estimates should be interpreted."
        let paragraphs = cleaned.prefix(4).map { ensuredSentence($0) }

        return """
        ## Robustness and Data Constraints

        \(intro)

        \(paragraphs.joined(separator: "\n\n"))
        """
    }

    private static func tablesSection(from tables: [ResearchTableArtifact]) -> String? {
        let renderedTables = tables.compactMap { table -> String? in
            guard !table.columns.isEmpty else {
                return nil
            }

            let header = "| " + table.columns.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
            let separator = "| " + Array(repeating: "---", count: table.columns.count).joined(separator: " | ") + " |"
            let rows = table.rows.prefix(20).map { row in
                let paddedRow = row + Array(repeating: "", count: max(0, table.columns.count - row.count))
                return "| " + paddedRow.prefix(table.columns.count).map {
                    $0.replacingOccurrences(of: "|", with: "\\|")
                }.joined(separator: " | ") + " |"
            }

            let notes = table.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let notesBlock = notes.isEmpty ? "" : "\n\n\(notes)"

            return """
            ### \(table.title.isEmpty ? table.identifier.capitalized : table.title)

            \(header)
            \(separator)
            \(rows.joined(separator: "\n"))\(notesBlock)
            """
        }

        guard !renderedTables.isEmpty else {
            return nil
        }

        return """
        ## Structured Tables

        \(renderedTables.joined(separator: "\n\n"))
        """
    }

    private static func limitationsSection(from limitations: [String]) -> String? {
        let cleaned = limitations
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else {
            return nil
        }

        return """
        ## Limitations

        \(cleaned.joined(separator: "\n\n"))
        """
    }

    private static func insertingSupplementarySections(
        _ sections: [String],
        into markdown: String,
        title _: String?
    ) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        let referencesIndex = lines.firstIndex { line in
            markdownHeadingTitle(from: line.trimmingCharacters(in: .whitespacesAndNewlines))?
                .lowercased() == "references"
        }

        let supplement = sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let referencesIndex else {
            return markdown + "\n\n" + supplement
        }

        let before = lines[..<referencesIndex].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let after = lines[referencesIndex...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(before)

        \(supplement)

        \(after)
        """
    }

    private static func containsHeading(_ title: String, in markdown: String) -> Bool {
        markdown
            .components(separatedBy: .newlines)
            .contains { line in
                markdownHeadingTitle(from: line.trimmingCharacters(in: .whitespacesAndNewlines))?
                    .lowercased() == title
            }
    }

    private static func containsTable(in markdown: String) -> Bool {
        markdown.contains("\n|") || markdown.hasPrefix("|")
    }

    private static func markdownWordCount(_ markdown: String) -> Int {
        markdown
            .replacingOccurrences(of: #"[#*`|_>\[\]\(\)]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .count
    }

    private static func serialSentence(for items: [String]) -> String {
        let cleaned = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        switch cleaned.count {
        case 0:
            return ""
        case 1:
            return cleaned[0]
        case 2:
            return "\(cleaned[0]) and \(cleaned[1])"
        default:
            let head = cleaned.dropLast().joined(separator: ", ")
            return "\(head), and \(cleaned.last!)"
        }
    }

    private static func formattedCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func ensuredSentence(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return cleaned
        }

        if let last = cleaned.last, ".!?".contains(last) {
            return cleaned
        }

        return cleaned + "."
    }

    private static func ordinalLead(_ index: Int) -> String {
        switch index {
        case 0:
            return "First,"
        case 1:
            return "Second,"
        case 2:
            return "Third,"
        case 3:
            return "Fourth,"
        default:
            return "Additionally,"
        }
    }

    private static func matchingPlannedFigure(
        for filename: String,
        in plan: ResearchPlanArtifact?
    ) -> ResearchFigurePlan? {
        guard let plan else {
            return nil
        }

        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent.lowercased()
        return plan.plannedFigures.first { planned in
            planned.identifier.lowercased() == stem
        }
    }

    private static func decodeJSONStringFragment(_ fragment: String) -> String? {
        let wrapped = "\"\(fragment)\""
        guard let data = wrapped.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(String.self, from: data)
    }

    private static func replacing(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func droppingSections(titled titles: [String], from markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        let blockedTitles = Set(titles.map { $0.lowercased() })

        var filtered: [String] = []
        var isDroppingSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let heading = markdownHeadingTitle(from: trimmed) {
                let normalizedHeading = heading.lowercased()
                if blockedTitles.contains(normalizedHeading) {
                    isDroppingSection = true
                    continue
                }

                isDroppingSection = false
            }

            if !isDroppingSection {
                filtered.append(line)
            }
        }

        return filtered.joined(separator: "\n")
    }

    private static func markdownHeadingTitle(from line: String) -> String? {
        guard line.hasPrefix("#") else {
            return nil
        }

        let stripped = line.drop(while: { $0 == "#" || $0.isWhitespace })
        let title = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func replaceFigureReferenceToken(
        in line: String,
        filename: String,
        label: String
    ) -> String {
        replacing(
            pattern: "`?\(NSRegularExpression.escapedPattern(for: filename))`?",
            in: line,
            template: label
        )
    }
}

private struct FigureReference {
    let filename: String
    let label: String
    let caption: String

    var altText: String {
        caption.isEmpty ? label : caption
    }
}

private enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var html: [String] = []
        var paragraph: [String] = []
        var unorderedList: [String] = []
        var orderedList: [String] = []
        var tableLines: [String] = []
        var isCodeBlock = false
        var codeLines: [String] = []
        var isMathBlock = false
        var mathLines: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }

        func flushUnorderedList() {
            guard !unorderedList.isEmpty else { return }
            let items = unorderedList.map { "<li>\(inline($0))</li>" }.joined()
            html.append("<ul>\(items)</ul>")
            unorderedList.removeAll()
        }

        func flushOrderedList() {
            guard !orderedList.isEmpty else { return }
            let items = orderedList.map { "<li>\(inline($0))</li>" }.joined()
            html.append("<ol>\(items)</ol>")
            orderedList.removeAll()
        }

        func flushTable() {
            guard !tableLines.isEmpty else { return }

            defer { tableLines.removeAll() }

            guard tableLines.count >= 2, isTableSeparatorRow(tableLines[1]) else {
                paragraph.append(contentsOf: tableLines)
                return
            }

            let headerCells = parseTableRow(tableLines[0])
            let bodyRows = tableLines.dropFirst(2).map { parseTableRow($0) }
            guard !headerCells.isEmpty else {
                return
            }

            let headerHTML = headerCells.map { "<th>\(inline($0))</th>" }.joined()
            let bodyHTML = bodyRows.map { row in
                let cells = row.map { "<td>\(inline($0))</td>" }.joined()
                return "<tr>\(cells)</tr>"
            }.joined()

            html.append("""
            <table class="paper-table">
              <thead><tr>\(headerHTML)</tr></thead>
              <tbody>\(bodyHTML)</tbody>
            </table>
            """)
        }

        func flushCodeBlock() {
            guard !codeLines.isEmpty else { return }
            html.append("<pre><code>\(escape(codeLines.joined(separator: "\n")))</code></pre>")
            codeLines.removeAll()
        }

        func flushMathBlock() {
            guard !mathLines.isEmpty else { return }
            html.append(#"<div class="equation">\#(escape(MathTextFormatter.displayText(for: mathLines.joined(separator: " "))))</div>"#)
            mathLines.removeAll()
        }

        for line in lines {
            if line.hasPrefix("```") {
                if isCodeBlock {
                    flushCodeBlock()
                    isCodeBlock = false
                } else {
                    flushParagraph()
                    flushUnorderedList()
                    flushOrderedList()
                    flushTable()
                    flushMathBlock()
                    isCodeBlock = true
                }
                continue
            }

            if isCodeBlock {
                codeLines.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "\\[" {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                flushTable()
                isMathBlock = true
                continue
            }

            if isMathBlock {
                if trimmed == "\\]" {
                    flushMathBlock()
                    isMathBlock = false
                } else {
                    mathLines.append(trimmed)
                }
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                flushTable()
                continue
            }

            if isTableRow(trimmed) {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                tableLines.append(trimmed)
                continue
            }

            if line.hasPrefix("# ") {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                flushTable()
                html.append("<h1>\(inline(String(line.dropFirst(2))))</h1>")
                continue
            }

            if line.hasPrefix("## ") {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                flushTable()
                html.append("<h2>\(inline(String(line.dropFirst(3))))</h2>")
                continue
            }

            if line.hasPrefix("### ") {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                flushTable()
                html.append("<h3>\(inline(String(line.dropFirst(4))))</h3>")
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                flushOrderedList()
                flushTable()
                unorderedList.append(String(line.dropFirst(2)))
                continue
            }

            if let dotIndex = line.firstIndex(of: "."),
               line[..<dotIndex].allSatisfy(\.isNumber),
               line[line.index(after: dotIndex)...].hasPrefix(" ") {
                flushParagraph()
                flushUnorderedList()
                flushTable()
                orderedList.append(String(line[line.index(dotIndex, offsetBy: 2)...]))
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                flushTable()
                html.append("<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>")
                continue
            }

            paragraph.append(trimmed)
        }

        flushParagraph()
        flushUnorderedList()
        flushOrderedList()
        flushTable()
        flushCodeBlock()
        flushMathBlock()

        return html.joined(separator: "\n")
    }

    private static func inline(_ text: String) -> String {
        var value = escape(text)
        value = replacing(pattern: #"\!\[(.*?)\]\((.*?)\)"#, in: value, template: #"<img alt="$1" src="$2" />"#)
        value = replacing(pattern: #"\[(.*?)\]\((.*?)\)"#, in: value, template: #"<a href="$2">$1</a>"#)
        value = replacing(pattern: #"\*\*(.*?)\*\*"#, in: value, template: #"<strong>$1</strong>"#)
        value = replacing(pattern: #"\*(.*?)\*"#, in: value, template: #"<em>$1</em>"#)
        value = replacing(pattern: #"`([^`]+)`"#, in: value, template: #"<code>$1</code>"#)
        return value
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func replacing(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.hasSuffix("|") && line.contains("|")
    }

    private static func isTableSeparatorRow(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty
    }

    private static func parseTableRow(_ line: String) -> [String] {
        line
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

private enum MathTextFormatter {
    static func displayText(for latex: String) -> String {
        var value = latex
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\left", with: "")
            .replacingOccurrences(of: "\\right", with: "")
            .replacingOccurrences(of: "\\cdot", with: " * ")
            .replacingOccurrences(of: "\\times", with: " x ")
            .replacingOccurrences(of: "\\log", with: "log")
            .replacingOccurrences(of: "\\,", with: " ")

        value = replacing(pattern: #"\\text\{([^}]*)\}"#, in: value, template: "$1")
        value = replacing(pattern: #"\\mathrm\{([^}]*)\}"#, in: value, template: "$1")

        while value.contains("\\frac") {
            let updated = replacing(pattern: #"\\frac\{([^{}]+)\}\{([^{}]+)\}"#, in: value, template: "($1) / ($2)")
            if updated == value {
                break
            }
            value = updated
        }

        value = replacing(pattern: #"\\([A-Za-z]+)_\{?([A-Za-z0-9]+)\}?"#, in: value, template: "$1_$2")
        value = replacing(pattern: #"\\([A-Za-z]+)"#, in: value, template: "$1")
        value = value
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "^", with: "")

        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
