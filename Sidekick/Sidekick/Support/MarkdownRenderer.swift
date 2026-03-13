import Foundation

enum PaperHTMLBuilder {
    static func html(for paper: Paper) -> String {
        var html = MarkdownHTMLRenderer.render(markdown: paper.markdown)
        for (index, data) in paper.figureData.enumerated() {
            let filename = "figure_\(index + 1).png"
            let replacement = "data:image/png;base64,\(data.base64EncodedString())"
            html = html.replacingOccurrences(of: filename, with: replacement)
        }

        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            :root {
              color-scheme: light;
              --ink: #142032;
              --muted: #4d6072;
              --surface: rgba(255,255,255,0.84);
              --border: rgba(255,255,255,0.60);
              --accent: #4b9ed3;
            }
            body {
              margin: 0;
              padding: 24px;
              background:
                radial-gradient(circle at top left, rgba(253,232,217,0.75), transparent 36%),
                linear-gradient(180deg, #f7fbfe 0%, #eaf3fa 100%);
              color: var(--ink);
              font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
            }
            article {
              max-width: 780px;
              margin: 0 auto;
              padding: 28px;
              border-radius: 28px;
              background: var(--surface);
              border: 1px solid var(--border);
              backdrop-filter: blur(18px);
              box-shadow: 0 24px 72px rgba(20, 32, 50, 0.10);
            }
            h1, h2, h3 {
              font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif;
              line-height: 1.15;
            }
            h1 { font-size: 2rem; margin-bottom: 0.5rem; }
            h2 { font-size: 1.35rem; margin-top: 2rem; }
            h3 { font-size: 1.1rem; margin-top: 1.5rem; }
            p, li {
              color: var(--muted);
              font-size: 1rem;
              line-height: 1.68;
            }
            code, pre {
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            }
            pre {
              background: rgba(20,32,50,0.05);
              border-radius: 16px;
              padding: 16px;
              overflow-x: auto;
            }
            img {
              display: block;
              max-width: 100%;
              margin: 20px auto 12px auto;
              border-radius: 18px;
              box-shadow: 0 18px 40px rgba(20, 32, 50, 0.12);
            }
            blockquote {
              margin: 1rem 0;
              padding-left: 16px;
              border-left: 3px solid rgba(75, 158, 211, 0.35);
              color: var(--muted);
            }
            a {
              color: var(--accent);
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
}

private enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var html: [String] = []
        var paragraph: [String] = []
        var unorderedList: [String] = []
        var orderedList: [String] = []
        var isCodeBlock = false
        var codeLines: [String] = []

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

        func flushCodeBlock() {
            guard !codeLines.isEmpty else { return }
            html.append("<pre><code>\(escape(codeLines.joined(separator: "\n")))</code></pre>")
            codeLines.removeAll()
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
                    isCodeBlock = true
                }
                continue
            }

            if isCodeBlock {
                codeLines.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                continue
            }

            if line.hasPrefix("# ") {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                html.append("<h1>\(inline(String(line.dropFirst(2))))</h1>")
                continue
            }

            if line.hasPrefix("## ") {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                html.append("<h2>\(inline(String(line.dropFirst(3))))</h2>")
                continue
            }

            if line.hasPrefix("### ") {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                html.append("<h3>\(inline(String(line.dropFirst(4))))</h3>")
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                flushOrderedList()
                unorderedList.append(String(line.dropFirst(2)))
                continue
            }

            if let dotIndex = line.firstIndex(of: "."),
               line[..<dotIndex].allSatisfy(\.isNumber),
               line[line.index(after: dotIndex)...].hasPrefix(" ") {
                flushParagraph()
                flushUnorderedList()
                orderedList.append(String(line[line.index(dotIndex, offsetBy: 2)...]))
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                html.append("<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>")
                continue
            }

            paragraph.append(trimmed)
        }

        flushParagraph()
        flushUnorderedList()
        flushOrderedList()
        flushCodeBlock()

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
}
