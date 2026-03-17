import Foundation
import UIKit

enum ExportService {
    static func exportLaTeX(for paper: Paper) async throws -> URL {
        let sourceURL = try await PaperDocumentService.ensureLaTeX(for: paper)
        return try exportedCopy(of: sourceURL, paperTitle: paper.title, fallbackBasename: "sidekick-paper", fileExtension: "tex")
    }

    static func exportPDF(for paper: Paper) async throws -> URL {
        let sourceURL = try await PaperDocumentService.ensurePDF(for: paper)
        return try exportedCopy(of: sourceURL, paperTitle: paper.title, fallbackBasename: "sidekick-paper", fileExtension: "pdf")
    }

    static func latexDocument(
        for paper: Paper,
        figureCaptions: [String] = [],
        plan: ResearchPlanArtifact? = nil,
        analysis: ResearchAnalysisArtifact? = nil
    ) -> String {
        let title = paper.title.replacingOccurrences(of: "\\", with: "\\\\")
        let normalizedMarkdown = PaperContentNormalizer.normalize(
            markdown: paper.markdown,
            title: paper.title,
            figureCaptions: figureCaptions,
            plan: plan,
            analysis: analysis
        )
        let body = LatexRenderer.render(
            markdown: LatexRenderer.strippingLeadingTitle(from: normalizedMarkdown, title: paper.title)
        )
        return """
        \\documentclass[11pt]{article}
        \\usepackage[margin=1in]{geometry}
        \\usepackage[utf8]{inputenc}
        \\usepackage{graphicx}
        \\usepackage{amsmath}
        \\usepackage{amssymb}
        \\usepackage[hidelinks]{hyperref}
        \\usepackage{booktabs}
        \\usepackage{enumitem}
        \\title{\(title)}
        \\date{}
        \\begin{document}
        \\maketitle
        \(body)
        \\end{document}
        """
    }

    private static func exportedCopy(
        of sourceURL: URL,
        paperTitle: String,
        fallbackBasename: String,
        fileExtension: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let exportsDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "SidekickExports",
            isDirectory: true
        )
        try fileManager.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)

        let basename = sanitizedExportBasename(
            from: paperTitle,
            fallback: fallbackBasename
        )
        let destinationURL = exportsDirectory
            .appendingPathComponent(basename)
            .appendingPathExtension(fileExtension)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private static func sanitizedExportBasename(from title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? fallback : trimmed

        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
        let cleanedScalars = raw.unicodeScalars.map { scalar in
            invalidCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()

        let collapsedWhitespace = cleanedScalars
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let limited = String(collapsedWhitespace.prefix(120))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return limited.isEmpty ? fallback : limited
    }
}

private enum LatexRenderer {
    nonisolated static func strippingLeadingTitle(from markdown: String, title: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstLine = lines.first else {
            return markdown
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if firstLine.trimmingCharacters(in: .whitespacesAndNewlines) == "# \(trimmedTitle)" {
            return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return markdown
    }

    nonisolated static func render(markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rendered: [String] = []
        var isMathBlock = false
        var mathLines: [String] = []
        var tableLines: [String] = []

        func flushMathBlock() {
            guard !mathLines.isEmpty else { return }
            rendered.append("\\[")
            rendered.append(contentsOf: mathLines)
            rendered.append("\\]")
            mathLines.removeAll()
        }

        func flushTable() {
            guard !tableLines.isEmpty else {
                return
            }

            let rows = tableLines.map(parseTableRow)
            guard let header = rows.first, !header.isEmpty else {
                tableLines.removeAll()
                return
            }

            let bodyRows = rows.dropFirst().filter { !$0.isEmpty && !isTableSeparatorRow($0) }
            let columnSpec = Array(repeating: "l", count: header.count).joined()

            rendered.append("\\begin{table}[h]")
            rendered.append("\\centering")
            rendered.append("\\begin{tabular}{\(columnSpec)}")
            rendered.append("\\toprule")
            rendered.append(header.map(escape).joined(separator: " & ") + " \\\\")

            if !bodyRows.isEmpty {
                rendered.append("\\midrule")
                for row in bodyRows {
                    rendered.append(row.map(escape).joined(separator: " & ") + " \\\\")
                }
            }

            rendered.append("\\bottomrule")
            rendered.append("\\end{tabular}")
            rendered.append("\\end{table}")
            tableLines.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed == "\\[" {
                flushTable()
                isMathBlock = true
                continue
            }

            if isMathBlock {
                if trimmed == "\\]" {
                    flushMathBlock()
                    isMathBlock = false
                } else {
                    mathLines.append(line)
                }
                continue
            }

            if isTableRow(trimmed) {
                tableLines.append(trimmed)
                continue
            }

            flushTable()

            rendered.append(render(line: line))
        }

        flushTable()
        flushMathBlock()
        return rendered.joined(separator: "\n")
    }

    nonisolated private static func render(line: String) -> String {
        let text = line
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")

        if text.hasPrefix("# ") {
            return "\\section*{\(escape(text.dropFirst(2)))}"
        }

        if text.hasPrefix("## ") {
            return "\\section{\(escape(text.dropFirst(3)))}"
        }

        if text.hasPrefix("### ") {
            return "\\subsection{\(escape(text.dropFirst(4)))}"
        }

        if let image = parseImageMarkdown(text) {
            return """
            \\begin{figure}[h]
            \\centering
            \\includegraphics[width=\\linewidth]{\(escape(image.path))}
            \\caption{\(escape(image.caption))}
            \\end{figure}
            """
        }

        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return ""
        }

        return escape(text)
    }

    nonisolated private static func parseImageMarkdown(_ text: String) -> (caption: String, path: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\n]+)\)"#) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let captionRange = Range(match.range(at: 1), in: text),
              let pathRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        return (String(text[captionRange]), String(text[pathRange]))
    }

    nonisolated private static func escape<S: StringProtocol>(_ text: S) -> String {
        let placeholder = "\u{0000}BACKSLASH\u{0000}"
        return String(text)
            .replacingOccurrences(of: "\\", with: placeholder)
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "&", with: "\\&")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "^", with: "\\textasciicircum{}")
            .replacingOccurrences(of: "~", with: "\\textasciitilde{}")
            .replacingOccurrences(of: placeholder, with: "\\textbackslash{}")
    }

    nonisolated private static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.hasSuffix("|") && line.contains("|")
    }

    nonisolated private static func isTableSeparatorRow(_ columns: [String]) -> Bool {
        let stripped = columns
            .joined()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty
    }

    nonisolated private static func parseTableRow(_ line: String) -> [String] {
        line
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
