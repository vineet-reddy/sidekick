import Foundation

enum PaperHTMLBuilder {
    static func html(for paper: Paper) -> String {
        let normalizedMarkdown = PaperContentNormalizer.normalize(markdown: paper.markdown)
        var html = MarkdownHTMLRenderer.render(markdown: normalizedMarkdown)
        for (index, data) in paper.figureData.enumerated() {
            let filename = "figure_\(index + 1).png"
            let replacement = "data:image/png;base64,\(data.base64EncodedString())"
            html = html.replacingOccurrences(of: filename, with: replacement)
        }
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
              margin: 0.8in 0.75in;
            }
            :root {
              color-scheme: light only;
              --page: #ffffff;
              --canvas: #eef2f6;
              --ink: #16181d;
              --muted: #4d5562;
              --rule: #c8ced8;
              --accent: #1f4f8c;
              --accent-soft: #e8f0fb;
            }
            body {
              margin: 0;
              padding: 24px 14px 48px;
              background: var(--canvas);
              color: var(--ink);
              font-family: "Iowan Old Style", "Palatino Linotype", "Book Antiqua", Georgia, serif;
            }
            article {
              box-sizing: border-box;
              width: min(100%, 820px);
              min-height: calc(100vh - 72px);
              margin: 0 auto;
              padding: 62px 68px 72px;
              background: var(--page);
              border: 1px solid rgba(17, 24, 39, 0.08);
              box-shadow: 0 28px 80px rgba(16, 24, 40, 0.14);
            }
            h1, h2, h3 {
              font-family: "Times New Roman", "Iowan Old Style", Georgia, serif;
              font-weight: 700;
              color: var(--ink);
              line-height: 1.15;
            }
            h1 {
              margin: 0 0 24px;
              text-align: center;
              font-size: 2rem;
              letter-spacing: -0.02em;
            }
            h2 {
              margin: 30px 0 12px;
              padding-top: 8px;
              border-top: 1px solid var(--rule);
              font-size: 1.05rem;
              letter-spacing: 0.08em;
              text-transform: uppercase;
            }
            h3 {
              margin: 22px 0 10px;
              font-size: 1rem;
            }
            p, li {
              color: var(--ink);
              font-size: 1rem;
              line-height: 1.62;
            }
            p { margin: 0 0 1em; }
            ul, ol { margin: 0.35em 0 1em 1.35em; padding: 0; }
            li { margin: 0.2em 0; }
            code, pre {
              font-family: "SFMono-Regular", Menlo, Consolas, monospace;
            }
            code {
              font-size: 0.92em;
              background: rgba(15, 23, 42, 0.05);
              padding: 0.08em 0.32em;
              border-radius: 4px;
            }
            pre {
              margin: 1.2em 0;
              background: #f8fafc;
              border: 1px solid #d9e1ea;
              border-radius: 10px;
              padding: 14px 16px;
              overflow-x: auto;
            }
            blockquote {
              margin: 1.2em 0;
              padding: 0.2em 0 0.2em 16px;
              border-left: 3px solid #cbd5e1;
              color: var(--muted);
            }
            a {
              color: var(--accent);
              text-decoration: none;
            }
            a:hover { text-decoration: underline; }
            .abstract {
              margin: 0 auto 28px;
              padding: 16px 20px 18px;
              background: var(--accent-soft);
              border: 1px solid rgba(31, 79, 140, 0.14);
            }
            .abstract h2 {
              border-top: none;
              margin: 0 0 10px;
              padding-top: 0;
              text-align: center;
            }
            .abstract p:last-child { margin-bottom: 0; }
            figure.paper-figure,
            figure.missing-figure {
              margin: 1.6em auto;
              text-align: center;
            }
            figure.paper-figure img {
              display: block;
              max-width: 100%;
              max-height: 460px;
              margin: 0 auto 10px;
              border: 1px solid #d5dbe3;
            }
            figcaption {
              color: var(--muted);
              font-size: 0.92rem;
              line-height: 1.45;
            }
            .missing-figure__box {
              display: flex;
              align-items: center;
              justify-content: center;
              min-height: 160px;
              margin-bottom: 10px;
              border: 1px dashed #b8c2cf;
              background: #f8fafc;
              color: var(--muted);
              font-size: 0.95rem;
            }
            .equation {
              margin: 1.4em auto;
              padding: 0.8em 1em;
              max-width: 100%;
              overflow-x: auto;
              background: #f7f9fc;
              border-left: 3px solid #ccd6e2;
              color: var(--ink);
              font-family: "Times New Roman", "Cambria Math", Georgia, serif;
              font-size: 1rem;
              line-height: 1.5;
              text-align: center;
              white-space: pre-wrap;
            }
            table.paper-table {
              width: 100%;
              margin: 1.4em 0;
              border-collapse: collapse;
              font-size: 0.96rem;
            }
            table.paper-table th,
            table.paper-table td {
              padding: 8px 10px;
              border: 1px solid #d5dbe3;
              text-align: left;
              vertical-align: top;
            }
            table.paper-table thead th {
              background: #f3f6fa;
              font-weight: 700;
            }
            table.paper-table tbody tr:nth-child(even) {
              background: #fafbfd;
            }
            @media print {
              body {
                padding: 0;
                background: #ffffff;
              }
              article {
                width: auto;
                min-height: auto;
                margin: 0;
                padding: 0;
                border: none;
                box-shadow: none;
              }
            }
            @media (max-width: 700px) {
              article {
                min-height: auto;
                padding: 28px 22px 36px;
              }
              h1 {
                font-size: 1.55rem;
              }
            }
          </style>
        </head>
        <body>
          <article>
            \(html)
          </article>
        </body>
        </html>
        """
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
}

enum PaperContentNormalizer {
    static func normalize(markdown: String) -> String {
        var value = markdown

        if let decoded = decodeJSONStringFragment(markdown) {
            value = decoded
        } else {
            value = value
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }

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
            html.append(#"<div class="equation">\#(escape(mathLines.joined(separator: "\n")))</div>"#)
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
