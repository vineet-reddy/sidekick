import Foundation
import UIKit

enum ExportService {
    static func exportLaTeX(for paper: Paper) async throws -> URL {
        try await PaperDocumentService.ensureLaTeX(for: paper)
    }

    static func exportPDF(for paper: Paper) async throws -> URL {
        try await PaperDocumentService.ensurePDF(for: paper)
    }

    static func latexDocument(for paper: Paper) -> String {
        let title = paper.title.replacingOccurrences(of: "\\", with: "\\\\")
        let normalizedMarkdown = PaperContentNormalizer.normalize(markdown: paper.markdown)
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

        if text.hasPrefix("!["),
           let altStart = text.firstIndex(of: "["),
           let altEnd = text.firstIndex(of: "]"),
           let pathStart = text.firstIndex(of: "("),
           let pathEnd = text.lastIndex(of: ")") {
            let caption = text[text.index(after: altStart) ..< altEnd]
            let path = text[text.index(after: pathStart) ..< pathEnd]
            return """
            \\begin{figure}[h]
            \\centering
            \\includegraphics[width=\\linewidth]{\(escape(path))}
            \\caption{\(escape(caption))}
            \\end{figure}
            """
        }

        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return ""
        }

        return escape(text)
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
