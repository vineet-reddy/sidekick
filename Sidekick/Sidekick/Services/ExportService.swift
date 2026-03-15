import Foundation
import UIKit
import WebKit

enum ExportService {
    static func exportLaTeX(for paper: Paper) throws -> URL {
        let title = paper.title.replacingOccurrences(of: "\\", with: "\\\\")
        let body = LatexRenderer.render(markdown: PaperContentNormalizer.normalize(markdown: paper.markdown))
        let document = """
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

        let url = temporaryURL(for: paper, pathExtension: "tex")
        try document.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func exportPDF(for paper: Paper, webView: WKWebView) async throws -> URL {
        let configuration = WKPDFConfiguration()
        let data = try await webView.pdf(configuration: configuration)
        let url = temporaryURL(for: paper, pathExtension: "pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func temporaryURL(for paper: Paper, pathExtension: String) -> URL {
        let name = paper.title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return FileManager.default.temporaryDirectory.appendingPathComponent("\(name).\(pathExtension)")
    }
}

private extension WKWebView {
    func pdf(configuration: WKPDFConfiguration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            createPDF(configuration: configuration) { result in
                continuation.resume(with: result)
            }
        }
    }
}

private enum LatexRenderer {
    static func render(markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rendered: [String] = []
        var isMathBlock = false
        var mathLines: [String] = []

        func flushMathBlock() {
            guard !mathLines.isEmpty else { return }
            rendered.append("\\[")
            rendered.append(contentsOf: mathLines)
            rendered.append("\\]")
            mathLines.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed == "\\[" {
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

            rendered.append(render(line: line))
        }

        flushMathBlock()
        return rendered.joined(separator: "\n")
    }

    private static func render(line: String) -> String {
        let text = line

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

    private static func escape<S: StringProtocol>(_ text: S) -> String {
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
            .replacingOccurrences(of: placeholder, with: "\\textbackslash{}")
    }
}
