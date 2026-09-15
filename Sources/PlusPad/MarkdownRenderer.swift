import AppKit

/// Turns Markdown into an attributed string for the preview pane.
///
/// Written against CommonMark plus the GitHub extensions people actually use --
/// tables, strikethrough, task list items, autolinks -- rather than any one spec
/// in full. The shortfall is deliberate and listed in the README: this renders a
/// document so you can read it while you write it, and is not a conformance
/// implementation.
///
/// Two rules it does not bend:
///
/// **It performs no networking.** A remote image is drawn as its alt text and a
/// link rather than fetched. PlusPad contains no networking code at all, and a
/// preview that quietly requested whatever a file happened to reference would be
/// the one place that changed -- opening someone else's Markdown would tell that
/// someone you had opened it. Local images are read from disk, resolved against
/// the document.
///
/// **It renders no HTML.** Embedded tags are shown as the literal text they are.
/// Executing them would need a web view, which is both a second rendering engine
/// to keep in step with the first and a way for a file to run script with the
/// app's file access. The preview shows you what the document says, never what
/// it would like to do.
enum MarkdownRenderer {

    struct Options {
        var theme: Theme
        /// Prose is proportional even though the editor is monospaced: the
        /// preview exists to show the document as a reader meets it.
        var proseFont: NSFont
        /// Code spans and fenced blocks, which stay in the editor's own face.
        var codeFont: NSFont
        /// The document's folder, for resolving relative image and link paths.
        var baseURL: URL?

        init(theme: Theme, editorFont: NSFont, baseURL: URL?) {
            self.theme = theme
            let size = editorFont.pointSize + 1
            self.proseFont = NSFont.systemFont(ofSize: size)
            self.codeFont = NSFont(name: editorFont.fontName, size: size - 1)
                ?? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
            self.baseURL = baseURL
        }
    }

    static func render(_ markdown: String, options: Options) -> NSAttributedString {
        var parser = BlockParser(markdown: markdown, options: options)
        return parser.run()
    }
}

// MARK: - Blocks

private struct BlockParser {
    let lines: [String]
    let opt: MarkdownRenderer.Options
    /// Link reference definitions, collected before rendering so a `[text][id]`
    /// can resolve against a definition further down the file.
    let references: [String: String]

    private var index = 0
    private let out = NSMutableAttributedString()

    init(markdown: String, options: MarkdownRenderer.Options) {
        self.lines = markdown.components(separatedBy: .newlines)
        self.opt = options
        var refs: [String: String] = [:]
        for line in lines {
            guard let (id, url) = Self.referenceDefinition(line) else { continue }
            refs[id.lowercased()] = url
        }
        self.references = refs
    }

    mutating func run() -> NSAttributedString {
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) { index += 1; continue }
            if Self.referenceDefinition(line) != nil { index += 1; continue }

            if let fence = Self.fenceOpener(line) { appendFencedCode(fence); continue }
            if Self.isHorizontalRule(line) { appendHorizontalRule(); index += 1; continue }
            if let heading = Self.atxHeading(line) {
                append(paragraph: inline(heading.text), style: headingStyle(heading.level),
                       font: headingFont(heading.level), color: opt.theme.color(.heading))
                index += 1
                continue
            }
            if let level = Self.setextUnderline(next()), !Self.isHorizontalRule(line) {
                append(paragraph: inline(line.trimmed), style: headingStyle(level),
                       font: headingFont(level), color: opt.theme.color(.heading))
                index += 2
                continue
            }
            if line.trimmedLeading.hasPrefix(">") { appendBlockquote(); continue }
            if Self.listItem(line) != nil { appendList(); continue }
            if let table = tableRows(at: index) { appendTable(table.rows); index = table.next; continue }

            appendParagraph()
        }
        return out
    }

    // MARK: line classification

    private func next() -> String { index + 1 < lines.count ? lines[index + 1] : "" }

    private func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `[id]: https://example.com "Title"`
    static func referenceDefinition(_ line: String) -> (id: String, url: String)? {
        let text = line.trimmedLeading
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        let after = text.index(after: close)
        guard after < text.endIndex, text[after] == ":" else { return nil }
        let id = String(text[text.index(after: text.startIndex)..<close])
        guard !id.isEmpty else { return nil }
        let rest = text[text.index(after: after)...].trimmingCharacters(in: .whitespaces)
        let url = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard !url.isEmpty else { return nil }
        return (id, url)
    }

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        let text = line.trimmedLeading
        var level = 0
        var i = text.startIndex
        while i < text.endIndex, text[i] == "#", level < 7 { level += 1; i = text.index(after: i) }
        guard (1...6).contains(level) else { return nil }
        // A run of hashes with no space after it is not a heading, which is what
        // keeps a line of "###" from swallowing the document.
        guard i == text.endIndex || text[i] == " " || text[i] == "\t" else { return nil }
        var body = String(text[i...]).trimmingCharacters(in: .whitespaces)
        while body.hasSuffix("#") { body.removeLast() }
        return (level, body.trimmingCharacters(in: .whitespaces))
    }

    /// `===` or `---` under a line of text promotes it to a heading.
    static func setextUnderline(_ line: String) -> Int? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return nil }
        if text.allSatisfy({ $0 == "=" }) { return 1 }
        if text.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    static func isHorizontalRule(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard text.count >= 3 else { return false }
        return text.allSatisfy { $0 == "-" } || text.allSatisfy { $0 == "*" } || text.allSatisfy { $0 == "_" }
    }

    static func fenceOpener(_ line: String) -> (marker: Character, indent: Int, info: String)? {
        let indent = line.leadingSpaces
        let text = line.trimmedLeading
        guard text.hasPrefix("```") || text.hasPrefix("~~~") else { return nil }
        let marker = text.first!
        let info = text.drop { $0 == marker }.trimmingCharacters(in: .whitespaces)
        return (marker, indent, info)
    }

    struct ListItem {
        var indent: Int
        var ordered: Bool
        var number: Int
        var content: String
        /// nil when the item is not a task item.
        var checked: Bool?
    }

    static func listItem(_ line: String) -> ListItem? {
        let indent = line.leadingSpaces
        let text = line.trimmedLeading
        guard let first = text.first else { return nil }
        var rest: Substring
        var ordered = false
        var number = 1

        if first == "-" || first == "*" || first == "+" {
            let after = text.index(after: text.startIndex)
            guard after < text.endIndex, text[after] == " " || text[after] == "\t" else { return nil }
            rest = text[text.index(after: after)...]
        } else if first.isNumber {
            var i = text.startIndex
            var digits = ""
            while i < text.endIndex, text[i].isNumber { digits.append(text[i]); i = text.index(after: i) }
            guard i < text.endIndex, text[i] == "." || text[i] == ")" else { return nil }
            let after = text.index(after: i)
            guard after < text.endIndex, text[after] == " " || text[after] == "\t" else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            rest = text[text.index(after: after)...]
        } else {
            return nil
        }

        var content = String(rest).trimmingCharacters(in: .whitespaces)
        var checked: Bool? = nil
        if content.hasPrefix("[ ] ") || content == "[ ]" {
            checked = false
            content = String(content.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if content.lowercased().hasPrefix("[x] ") || content.lowercased() == "[x]" {
            checked = true
            content = String(content.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return ListItem(indent: indent, ordered: ordered, number: number,
                        content: content, checked: checked)
    }

    // MARK: block rendering

    private mutating func appendParagraph() {
        var text = ""
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) || Self.atxHeading(line) != nil || Self.fenceOpener(line) != nil
                || Self.isHorizontalRule(line) || Self.listItem(line) != nil
                || line.trimmedLeading.hasPrefix(">") || Self.setextUnderline(line) != nil {
                break
            }
            if !text.isEmpty { text += " " }
            text += line.trimmingCharacters(in: .whitespaces)
            index += 1
        }
        guard !text.isEmpty else { return }
        append(paragraph: inline(text), style: bodyStyle(), font: opt.proseFont,
               color: opt.theme.foreground)
    }

    private mutating func appendFencedCode(_ fence: (marker: Character, indent: Int, info: String)) {
        index += 1
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmedLeading
            if trimmed.hasPrefix(String(repeating: String(fence.marker), count: 3)) {
                index += 1
                break
            }
            body.append(line)
            index += 1
        }

        let code = body.joined(separator: "\n")
        let attributed = NSMutableAttributedString(string: code.isEmpty ? " " : code)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 10
        style.headIndent = 10
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = spacing
        style.lineBreakMode = .byCharWrapping
        attributed.addAttributes([
            .font: opt.codeFont,
            .foregroundColor: opt.theme.foreground,
            .paragraphStyle: style,
            .backgroundColor: codeBackground,
        ], range: NSRange(location: 0, length: attributed.length))

        colourCode(attributed, language: fence.info)
        out.append(attributed)
        out.append(NSAttributedString(string: "\n"))
    }

    /// Run the editor's own scanners over a fenced block, so a Swift fence in a
    /// README is coloured by exactly the code that colours a Swift file. The
    /// fence's info string names the language: "swift", "python", "json".
    private func colourCode(_ attributed: NSMutableAttributedString, language info: String) {
        let tag = info.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        guard !tag.isEmpty else { return }
        let language = LanguageRegistry.named(tag)
            ?? LanguageRegistry.all.first { $0.extensions.contains(tag) }
            ?? LanguageRegistry.all.first { $0.name.lowercased() == tag }
        guard let language, !isPlain(language) else { return }

        let text = attributed.string as NSString
        let lineIndex = LineIndex()
        lineIndex.rebuild(text)
        let highlighter = SyntaxHighlighter(language: language)
        let tokens = highlighter.tokens(in: text, index: lineIndex,
                                        firstLine: 0, lastLine: lineIndex.lineCount - 1)
        for token in tokens {
            guard token.range.location >= 0,
                  NSMaxRange(token.range) <= attributed.length else { continue }
            attributed.addAttribute(.foregroundColor, value: opt.theme.color(token.kind),
                                    range: token.range)
            if opt.theme.isBold(token.kind) {
                let bold = NSFontManager.shared.convert(opt.codeFont, toHaveTrait: .boldFontMask)
                attributed.addAttribute(.font, value: bold, range: token.range)
            }
        }
    }

    private func isPlain(_ language: LanguageDef) -> Bool {
        if case .plain = language.flavor { return true }
        return false
    }

    private mutating func appendBlockquote() {
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmedLeading
            if trimmed.hasPrefix(">") {
                var content = String(trimmed.dropFirst())
                if content.hasPrefix(" ") { content.removeFirst() }
                body.append(content)
                index += 1
            } else if !isBlank(line) && !body.isEmpty {
                // Lazy continuation: a quote runs on until a blank line.
                body.append(line.trimmingCharacters(in: .whitespaces))
                index += 1
            } else {
                break
            }
        }

        // The quote's own content is Markdown, so it is rendered by a nested
        // parser rather than by a second, simpler copy of the block rules.
        var nested = BlockParser(markdown: body.joined(separator: "\n"), options: opt)
        let inner = NSMutableAttributedString(attributedString: nested.run())
        let full = NSRange(location: 0, length: inner.length)
        inner.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let style = (value as? NSParagraphStyle).flatMap { $0.mutableCopy() as? NSMutableParagraphStyle }
                ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent += 18
            style.headIndent += 18
            inner.addAttribute(.paragraphStyle, value: style, range: range)
        }
        inner.addAttribute(.foregroundColor, value: opt.theme.color(.comment), range: full)
        inner.addAttribute(.markdownQuoteBar, value: true, range: full)
        out.append(inner)
    }

    private mutating func appendList() {
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) {
                // A blank line inside a list only ends it if the next line is
                // not another item.
                if index + 1 < lines.count, Self.listItem(lines[index + 1]) != nil {
                    index += 1
                    continue
                }
                index += 1
                break
            }
            guard var item = Self.listItem(line) else { break }
            index += 1

            // Continuation lines belong to the item they are indented under.
            while index < lines.count, !isBlank(lines[index]), Self.listItem(lines[index]) == nil,
                  lines[index].leadingSpaces > item.indent {
                item.content += " " + lines[index].trimmingCharacters(in: .whitespaces)
                index += 1
            }
            appendListItem(item)
        }
    }

    private func appendListItem(_ item: ListItem) {
        let level = min(item.indent / 2, 4)
        let indent = CGFloat(level) * 18 + 18

        let marker: String
        if let checked = item.checked {
            // Literal brackets rather than a symbol font: it mirrors what the
            // source actually says, and stays legible in every theme.
            marker = checked ? "[x]  " : "[ ]  "
        } else if item.ordered {
            marker = "\(item.number).  "
        } else {
            marker = "\u{2022}  "
        }

        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = indent - 14
        style.paragraphSpacing = 2
        style.lineSpacing = 1

        let text = NSMutableAttributedString(string: marker)
        text.addAttributes([
            .font: item.checked != nil ? opt.codeFont : opt.proseFont,
            .foregroundColor: opt.theme.color(.keyword),
        ], range: NSRange(location: 0, length: text.length))
        text.append(inline(item.content))
        text.append(NSAttributedString(string: "\n"))
        text.addAttribute(.paragraphStyle, value: style,
                          range: NSRange(location: 0, length: text.length))
        out.append(text)
    }

    private mutating func appendHorizontalRule() {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = RuleCell(color: opt.theme.chromeBorder)
        let text = NSMutableAttributedString(attachment: attachment)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = spacing
        text.addAttribute(.paragraphStyle, value: style,
                          range: NSRange(location: 0, length: text.length))
        out.append(text)
        out.append(NSAttributedString(string: "\n"))
    }

    // MARK: tables

    /// A table is a header row of pipes followed by a delimiter row such as
    /// `| --- | :-: |`. Without the delimiter row it is just a paragraph that
    /// happens to contain pipes, which is why both are required.
    private func tableRows(at start: Int) -> (rows: [[String]], next: Int)? {
        guard start + 1 < lines.count else { return nil }
        let header = lines[start], delimiter = lines[start + 1]
        guard header.contains("|"), delimiter.contains("-") else { return nil }
        let delimiterCells = Self.tableCells(delimiter)
        guard !delimiterCells.isEmpty else { return nil }
        guard delimiterCells.allSatisfy({ cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }) else { return nil }

        var rows = [Self.tableCells(header)]
        var i = start + 2
        while i < lines.count, lines[i].contains("|"), !isBlank(lines[i]) {
            rows.append(Self.tableCells(lines[i]))
            i += 1
        }
        return (rows, i)
    }

    static func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func appendTable(_ rows: [[String]]) {
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true

        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)
                block.setBorderColor(opt.theme.chromeBorder)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(5, type: .absoluteValueType, for: .padding)
                if rowIndex == 0 { block.backgroundColor = codeBackground }

                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let cell = NSMutableAttributedString(
                    attributedString: inline(column < row.count ? row[column] : ""))
                cell.append(NSAttributedString(string: "\n"))
                cell.addAttribute(.paragraphStyle, value: style,
                                  range: NSRange(location: 0, length: cell.length))
                if rowIndex == 0 {
                    let bold = NSFontManager.shared.convert(opt.proseFont, toHaveTrait: .boldFontMask)
                    cell.addAttribute(.font, value: bold,
                                      range: NSRange(location: 0, length: cell.length))
                }
                out.append(cell)
            }
        }
    }

    // MARK: styling

    private var spacing: CGFloat { opt.proseFont.pointSize * 0.6 }

    private var codeBackground: NSColor {
        opt.theme.isDark
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor.black.withAlphaComponent(0.05)
    }

    private func bodyStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        style.lineSpacing = 2
        return style
    }

    private func headingStyle(_ level: Int) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacing * (level <= 2 ? 1.8 : 1.4)
        style.paragraphSpacing = spacing * 0.6
        return style
    }

    private func headingFont(_ level: Int) -> NSFont {
        let scale: [CGFloat] = [1.9, 1.55, 1.3, 1.15, 1.05, 1.0]
        let size = opt.proseFont.pointSize * scale[max(0, min(5, level - 1))]
        return NSFont.systemFont(ofSize: size, weight: .bold)
    }

    private func append(paragraph: NSAttributedString, style: NSParagraphStyle,
                        font: NSFont, color: NSColor) {
        let text = NSMutableAttributedString(attributedString: paragraph)
        text.append(NSAttributedString(string: "\n"))
        let full = NSRange(location: 0, length: text.length)
        text.addAttribute(.paragraphStyle, value: style, range: full)
        // Only fill in what the inline pass did not already decide, or bold and
        // code spans inside a heading would be flattened back to plain text.
        text.enumerateAttribute(.font, in: full) { value, range, _ in
            guard value == nil else { return }
            text.addAttribute(.font, value: font, range: range)
        }
        text.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard value == nil else { return }
            text.addAttribute(.foregroundColor, value: color, range: range)
        }
        out.append(text)
    }

    // MARK: inline

    private func inline(_ text: String) -> NSAttributedString {
        InlineParser(text: text, options: opt, references: references).run()
    }
}

// MARK: - Inline spans

private struct InlineParser {
    let text: [Character]
    let opt: MarkdownRenderer.Options
    let references: [String: String]

    init(text: String, options: MarkdownRenderer.Options, references: [String: String]) {
        self.text = Array(text)
        self.opt = options
        self.references = references
    }

    func run() -> NSAttributedString {
        let out = NSMutableAttributedString()
        var plain = ""
        var i = 0

        func flush() {
            guard !plain.isEmpty else { return }
            out.append(NSAttributedString(string: plain))
            plain = ""
        }

        while i < text.count {
            let c = text[i]

            if c == "\\", i + 1 < text.count, text[i + 1].isMarkdownPunctuation {
                plain.append(text[i + 1])
                i += 2
                continue
            }

            if c == "`" {
                let ticks = run(of: "`", from: i)
                if let close = find(String(repeating: "`", count: ticks), from: i + ticks) {
                    flush()
                    let code = String(text[(i + ticks)..<close])
                    out.append(NSAttributedString(string: code, attributes: [
                        .font: opt.codeFont,
                        .foregroundColor: opt.theme.color(.string),
                        .backgroundColor: opt.theme.isDark
                            ? NSColor.white.withAlphaComponent(0.07)
                            : NSColor.black.withAlphaComponent(0.05),
                    ]))
                    i = close + ticks
                    continue
                }
            }

            if c == "!", i + 1 < text.count, text[i + 1] == "[", let link = linkAt(i + 1) {
                flush()
                out.append(image(alt: link.label, source: link.destination))
                i = link.end
                continue
            }

            if c == "[", let link = linkAt(i) {
                flush()
                out.append(anchor(label: link.label, destination: link.destination))
                i = link.end
                continue
            }

            if c == "<", let close = find(">", from: i), Self.isAutolink(String(text[(i + 1)..<close])) {
                flush()
                let url = String(text[(i + 1)..<close])
                out.append(anchor(label: url, destination: url))
                i = close + 1
                continue
            }

            if c == "~", run(of: "~", from: i) >= 2, let close = find("~~", from: i + 2) {
                flush()
                let inner = InlineParser(text: String(text[(i + 2)..<close]), options: opt,
                                         references: references).run()
                let struck = NSMutableAttributedString(attributedString: inner)
                struck.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                    range: NSRange(location: 0, length: struck.length))
                out.append(struck)
                i = close + 2
                continue
            }

            if c == "*" || c == "_" {
                let count = min(run(of: c, from: i), 3)
                let marker = String(repeating: String(c), count: count)
                if let close = find(marker, from: i + count) {
                    flush()
                    let inner = InlineParser(text: String(text[(i + count)..<close]), options: opt,
                                             references: references).run()
                    out.append(emphasise(inner, level: count))
                    i = close + count
                    continue
                }
            }

            plain.append(c)
            i += 1
        }
        flush()
        return out
    }

    // MARK: helpers

    private func run(of character: Character, from start: Int) -> Int {
        var count = 0
        var i = start
        while i < text.count, text[i] == character { count += 1; i += 1 }
        return count
    }

    private func find(_ needle: String, from start: Int) -> Int? {
        let chars = Array(needle)
        guard !chars.isEmpty, start >= 0 else { return nil }
        var i = start
        while i + chars.count <= text.count {
            if Array(text[i..<(i + chars.count)]) == chars { return i }
            i += 1
        }
        return nil
    }

    /// `[label](destination)` or `[label][reference]` or `[reference]`.
    private func linkAt(_ start: Int) -> (label: String, destination: String, end: Int)? {
        guard start < text.count, text[start] == "[" else { return nil }
        var depth = 0
        var i = start
        var close: Int? = nil
        while i < text.count {
            if text[i] == "[" { depth += 1 }
            if text[i] == "]" {
                depth -= 1
                if depth == 0 { close = i; break }
            }
            i += 1
        }
        guard let labelEnd = close else { return nil }
        let label = String(text[(start + 1)..<labelEnd])

        var cursor = labelEnd + 1
        if cursor < text.count, text[cursor] == "(" {
            guard let paren = find(")", from: cursor) else { return nil }
            var destination = String(text[(cursor + 1)..<paren])
            // Strip an optional title: [x](url "Title")
            if let space = destination.firstIndex(of: " ") {
                destination = String(destination[..<space])
            }
            return (label, destination.trimmingCharacters(in: .whitespaces), paren + 1)
        }
        if cursor < text.count, text[cursor] == "[" {
            guard let refEnd = find("]", from: cursor) else { return nil }
            let id = String(text[(cursor + 1)..<refEnd])
            let key = (id.isEmpty ? label : id).lowercased()
            guard let destination = references[key] else { return nil }
            return (label, destination, refEnd + 1)
        }
        if let destination = references[label.lowercased()] {
            cursor = labelEnd + 1
            return (label, destination, cursor)
        }
        return nil
    }

    static func isAutolink(_ text: String) -> Bool {
        guard !text.contains(" "), text.contains(":") || text.contains("@") else { return false }
        return text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("mailto:")
            || (text.contains("@") && !text.contains("/"))
    }

    private func emphasise(_ inner: NSAttributedString, level: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: inner)
        let full = NSRange(location: 0, length: result.length)
        let traits: NSFontTraitMask = level >= 3 ? [.boldFontMask, .italicFontMask]
            : (level == 2 ? .boldFontMask : .italicFontMask)
        result.enumerateAttribute(.font, in: full) { value, range, _ in
            let base = (value as? NSFont) ?? opt.proseFont
            result.addAttribute(.font, value: NSFontManager.shared.convert(base, toHaveTrait: traits),
                                range: range)
        }
        if result.attribute(.font, at: 0, effectiveRange: nil) == nil {
            result.addAttribute(.font, value: NSFontManager.shared.convert(opt.proseFont,
                                                                          toHaveTrait: traits),
                                range: full)
        }
        return result
    }

    private func anchor(label: String, destination: String) -> NSAttributedString {
        let inner = InlineParser(text: label, options: opt, references: references).run()
        let result = NSMutableAttributedString(attributedString: inner)
        let full = NSRange(location: 0, length: result.length)
        result.addAttributes([
            .foregroundColor: opt.theme.color(.link),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ], range: full)
        if let url = resolve(destination) {
            result.addAttribute(.link, value: url, range: full)
        }
        result.addAttribute(.toolTip, value: destination, range: full)
        return result
    }

    /// Local images are read from disk. A remote one is shown as its alt text
    /// and link, never fetched -- see the note on MarkdownRenderer.
    private func image(alt: String, source: String) -> NSAttributedString {
        if let url = resolve(source), url.isFileURL,
           let image = NSImage(contentsOf: url) {
            let attachment = NSTextAttachment()
            let cell = NSTextAttachmentCell(imageCell: image)
            attachment.attachmentCell = cell
            return NSAttributedString(attachment: attachment)
        }
        let placeholder = alt.isEmpty ? source : alt
        let result = NSMutableAttributedString(attributedString:
            anchor(label: placeholder, destination: source))
        result.addAttribute(.toolTip, value: "Image: \(source)",
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    private func resolve(_ destination: String) -> URL? {
        guard !destination.isEmpty else { return nil }
        if destination.hasPrefix("#") { return nil }
        if let url = URL(string: destination), let scheme = url.scheme?.lowercased() {
            // Only schemes a preview has any business following. Anything else,
            // including javascript: and data:, is shown as text and not linked.
            guard ["http", "https", "mailto", "file"].contains(scheme) else { return nil }
            return url
        }
        guard let base = opt.baseURL else { return nil }
        return URL(fileURLWithPath: destination, relativeTo: base).standardizedFileURL
    }
}

// MARK: - Drawing

/// The horizontal rule. An attachment rather than a row of dashes so it spans
/// the pane's real width and follows it when the pane is resized.
private final class RuleCell: NSTextAttachmentCell {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func cellSize() -> NSSize { NSSize(width: 10_000, height: 9) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: max(10, lineFrag.width - position.x - 4), height: 9)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        color.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.midY, width: cellFrame.width, height: 1).fill()
    }
}

extension NSAttributedString.Key {
    /// Marks the runs a blockquote bar is drawn beside. The bar itself is
    /// painted by the preview's text view, which is the only thing that knows
    /// where the lines ended up.
    static let markdownQuoteBar = NSAttributedString.Key("PlusPadMarkdownQuoteBar")
}

// MARK: - Small string helpers

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }

    var trimmedLeading: String {
        guard let first = firstIndex(where: { $0 != " " && $0 != "\t" }) else { return "" }
        return String(self[first...])
    }

    /// Tabs count as two, which is what makes a tab-indented nested list line up
    /// with a space-indented one.
    var leadingSpaces: Int {
        var count = 0
        for character in self {
            if character == " " { count += 1 }
            else if character == "\t" { count += 2 }
            else { break }
        }
        return count
    }
}

private extension Character {
    var isMarkdownPunctuation: Bool {
        "\\`*_{}[]()#+-.!|~<>".contains(self)
    }
}
