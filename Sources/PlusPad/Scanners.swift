import Foundation

/// Character classification helpers, kept on `unichar` rather than `Character`
/// because the scanner walks a UTF-16 buffer and converting each unit into a
/// grapheme cluster would dominate its cost.
@inline(__always) func isDigitU(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
@inline(__always) func isHexU(_ c: unichar) -> Bool {
    isDigitU(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
}
@inline(__always) func isLetterU(_ c: unichar) -> Bool {
    (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c >= 128
}
@inline(__always) func isIdentStartU(_ c: unichar) -> Bool {
    isLetterU(c) || c == 95 || c == 36   // _ and $
}
@inline(__always) func isIdentBodyU(_ c: unichar) -> Bool {
    isIdentStartU(c) || isDigitU(c)
}
@inline(__always) func isSpaceU(_ c: unichar) -> Bool {
    c == 32 || c == 9 || c == 10 || c == 13
}

extension SyntaxHighlighter {

    /// True when `chars` contains `needle` starting at `i`.
    func matches(_ chars: [unichar], _ i: Int, _ needle: [unichar]) -> Bool {
        guard !needle.isEmpty, i + needle.count <= chars.count else { return false }
        for k in 0..<needle.count where chars[i + k] != needle[k] { return false }
        return true
    }

    func units(_ s: String) -> [unichar] { Array(s.utf16) }

    func word(_ chars: [unichar], _ from: Int, _ to: Int) -> String {
        String(utf16CodeUnits: Array(chars[from..<to]), count: to - from)
    }

    @inline(__always)
    func push(_ tokens: inout [Token], _ emit: Bool, _ base: Int, _ from: Int, _ to: Int, _ kind: TokenKind) {
        guard emit, to > from, kind != .plain else { return }
        tokens.append(Token(range: NSRange(location: base + from, length: to - from), kind: kind))
    }

    // MARK: - C-like

    /// Handles braces-and-semicolons languages plus everything close enough:
    /// Python, Ruby, Shell, SQL, Lua, Make. The differences between them all live
    /// in the `LanguageDef`, not here.
    func scanCLike(_ chars: [unichar], _ base: Int, _ entry: ScanState,
                   _ tokens: inout [Token], _ emit: Bool) -> ScanState {
        let n = chars.count
        var i = 0
        var state = entry

        // Finish whatever ran over from the previous line before doing anything
        // else, otherwise a `"` inside a block comment would open a string.
        switch state {
        case .blockComment:
            if let close = language.blockComment?.close {
                let needle = units(close)
                var j = 0
                while j < n && !matches(chars, j, needle) { j += 1 }
                if j < n {
                    push(&tokens, emit, base, 0, j + needle.count, .comment)
                    i = j + needle.count
                    state = .normal
                } else {
                    push(&tokens, emit, base, 0, n, .comment)
                    return .blockComment
                }
            } else {
                state = .normal
            }
        case .multilineString(let index):
            guard index < language.multilineStrings.count else { state = .normal; break }
            let needle = units(language.multilineStrings[index].close)
            var j = 0
            while j < n && !matches(chars, j, needle) { j += 1 }
            if j < n {
                push(&tokens, emit, base, 0, j + needle.count, .string)
                i = j + needle.count
                state = .normal
            } else {
                push(&tokens, emit, base, 0, n, .string)
                return .multilineString(index)
            }
        case .normal:
            break
        }

        // A preprocessor or directive line is coloured whole, which is how C's
        // `#define` and Make's `ifeq` read most clearly.
        if i == 0, let prefix = language.preprocessorPrefix {
            var k = 0
            while k < n && (chars[k] == 32 || chars[k] == 9) { k += 1 }
            if matches(chars, k, units(prefix)) {
                // `#` in C is a directive, but only when a word follows it.
                let after = k + prefix.utf16.count
                if after < n && isIdentStartU(chars[after]) {
                    push(&tokens, emit, base, k, n, .preprocessor)
                    return .normal
                }
            }
        }

        let lineCommentNeedles = language.lineComments.map(units)
        let blockOpen = language.blockComment.map { units($0.open) }
        let blockClose = language.blockComment.map { units($0.close) }
        let multiOpens = language.multilineStrings.map { units($0.open) }

        while i < n {
            let c = chars[i]

            if isSpaceU(c) { i += 1; continue }

            // Multi-line string openers are tested before single-character
            // delimiters so `"""` is not read as an empty string followed by a
            // quote.
            var openedMulti = false
            for (index, opener) in multiOpens.enumerated() where matches(chars, i, opener) {
                let closer = units(language.multilineStrings[index].close)
                var j = i + opener.count
                while j < n && !matches(chars, j, closer) { j += 1 }
                if j < n {
                    push(&tokens, emit, base, i, j + closer.count, .string)
                    i = j + closer.count
                } else {
                    push(&tokens, emit, base, i, n, .string)
                    return .multilineString(index)
                }
                openedMulti = true
                break
            }
            if openedMulti { continue }

            var startedComment = false
            for needle in lineCommentNeedles where matches(chars, i, needle) {
                // A word-shaped comment token (`rem` in Batch) must not fire in
                // the middle of an identifier.
                let isWordToken = isIdentStartU(needle[0])
                let boundaryOK = !isWordToken || (i == 0 || !isIdentBodyU(chars[i - 1]))
                if boundaryOK {
                    push(&tokens, emit, base, i, n, .comment)
                    startedComment = true
                    break
                }
            }
            if startedComment { return .normal }

            if let open = blockOpen, let close = blockClose, matches(chars, i, open) {
                // `/**` and `///` are documentation, dimmed differently.
                let isDoc = i + open.count < n && chars[i + open.count] == 42
                var j = i + open.count
                while j < n && !matches(chars, j, close) { j += 1 }
                if j < n {
                    push(&tokens, emit, base, i, j + close.count, isDoc ? .docComment : .comment)
                    i = j + close.count
                    continue
                }
                push(&tokens, emit, base, i, n, isDoc ? .docComment : .comment)
                return .blockComment
            }

            if language.stringDelimiters.contains(where: { unichar($0.unicodeScalars.first!.value) == c }) {
                let quote = c
                var j = i + 1
                var escapes: [(Int, Int)] = []
                while j < n {
                    if language.escapesInStrings && chars[j] == 92 && j + 1 < n {
                        escapes.append((j, j + 2))
                        j += 2
                        continue
                    }
                    if chars[j] == quote { j += 1; break }
                    j += 1
                }
                push(&tokens, emit, base, i, min(j, n), .string)
                for (from, to) in escapes { push(&tokens, emit, base, from, min(to, n), .escape) }
                i = min(j, n)
                continue
            }

            if isDigitU(c) || (c == 46 && i + 1 < n && isDigitU(chars[i + 1])) {
                var j = i
                if c == 48 && i + 1 < n && (chars[i + 1] == 120 || chars[i + 1] == 88) {
                    j = i + 2
                    while j < n && (isHexU(chars[j]) || chars[j] == 95) { j += 1 }
                } else {
                    while j < n && (isDigitU(chars[j]) || chars[j] == 46 || chars[j] == 95) { j += 1 }
                    if j < n && (chars[j] == 101 || chars[j] == 69) {
                        j += 1
                        if j < n && (chars[j] == 43 || chars[j] == 45) { j += 1 }
                        while j < n && isDigitU(chars[j]) { j += 1 }
                    }
                }
                // Numeric suffixes: 10f, 3u64, 1_000L.
                while j < n && isIdentBodyU(chars[j]) { j += 1 }
                push(&tokens, emit, base, i, j, .number)
                i = j
                continue
            }

            if isIdentStartU(c) || c == 64 || c == 35 {
                var j = i
                if c == 64 || c == 35 { j += 1 }   // @property, .PHONY-style leaders
                while j < n && isIdentBodyU(chars[j]) { j += 1 }
                if j == i { j += 1 }
                let text = word(chars, i, j)
                let lookup = language.caseSensitive ? text : text.lowercased()
                if language.keywords.contains(lookup) {
                    push(&tokens, emit, base, i, j, .keyword)
                } else if language.types.contains(lookup) {
                    push(&tokens, emit, base, i, j, .type)
                } else {
                    // A name immediately followed by `(` is a call or a
                    // definition; either way it is the most useful thing on the
                    // line to be able to find by eye.
                    var k = j
                    while k < n && (chars[k] == 32 || chars[k] == 9) { k += 1 }
                    if k < n && chars[k] == 40 {
                        push(&tokens, emit, base, i, j, .function)
                    }
                }
                i = j
                continue
            }

            if c == 40 || c == 41 || c == 123 || c == 125 || c == 91 || c == 93 ||
               c == 59 || c == 44 || c == 46 { i += 1; continue }

            // Anything left that is not alphanumeric is an operator.
            push(&tokens, emit, base, i, i + 1, .op)
            i += 1
        }
        return .normal
    }

    // MARK: - Markup

    func scanMarkup(_ chars: [unichar], _ base: Int, _ entry: ScanState,
                    _ tokens: inout [Token], _ emit: Bool) -> ScanState {
        let n = chars.count
        var i = 0
        let commentOpen = units("<!--"), commentClose = units("-->")

        if case .blockComment = entry {
            var j = 0
            while j < n && !matches(chars, j, commentClose) { j += 1 }
            if j < n {
                push(&tokens, emit, base, 0, j + commentClose.count, .comment)
                i = j + commentClose.count
            } else {
                push(&tokens, emit, base, 0, n, .comment)
                return .blockComment
            }
        }

        while i < n {
            if matches(chars, i, commentOpen) {
                var j = i + commentOpen.count
                while j < n && !matches(chars, j, commentClose) { j += 1 }
                if j < n {
                    push(&tokens, emit, base, i, j + commentClose.count, .comment)
                    i = j + commentClose.count
                    continue
                }
                push(&tokens, emit, base, i, n, .comment)
                return .blockComment
            }

            if chars[i] == 60 {           // '<'
                var j = i + 1
                if j < n && (chars[j] == 47 || chars[j] == 33 || chars[j] == 63) { j += 1 }
                let nameStart = j
                while j < n && (isIdentBodyU(chars[j]) || chars[j] == 58 || chars[j] == 45) { j += 1 }
                push(&tokens, emit, base, i, i + 1, .op)
                push(&tokens, emit, base, nameStart, j, .tag)

                // Attributes until the closing bracket.
                while j < n && chars[j] != 62 {
                    if chars[j] == 34 || chars[j] == 39 {
                        let quote = chars[j]
                        var k = j + 1
                        while k < n && chars[k] != quote { k += 1 }
                        push(&tokens, emit, base, j, min(k + 1, n), .string)
                        j = min(k + 1, n)
                        continue
                    }
                    if isIdentStartU(chars[j]) {
                        let attrStart = j
                        while j < n && (isIdentBodyU(chars[j]) || chars[j] == 45 || chars[j] == 58) { j += 1 }
                        push(&tokens, emit, base, attrStart, j, .attribute)
                        continue
                    }
                    j += 1
                }
                if j < n { push(&tokens, emit, base, j, j + 1, .op); j += 1 }
                i = j
                continue
            }

            if chars[i] == 38 {           // '&' entity
                var j = i + 1
                while j < n && j < i + 12 && chars[j] != 59 && !isSpaceU(chars[j]) { j += 1 }
                if j < n && chars[j] == 59 {
                    push(&tokens, emit, base, i, j + 1, .escape)
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return .normal
    }

    // MARK: - CSS

    func scanCSS(_ chars: [unichar], _ base: Int, _ entry: ScanState,
                 _ tokens: inout [Token], _ emit: Bool) -> ScanState {
        let n = chars.count
        var i = 0
        let open = units("/*"), close = units("*/")

        if case .blockComment = entry {
            var j = 0
            while j < n && !matches(chars, j, close) { j += 1 }
            if j < n {
                push(&tokens, emit, base, 0, j + close.count, .comment)
                i = j + close.count
            } else {
                push(&tokens, emit, base, 0, n, .comment)
                return .blockComment
            }
        }

        // Anything before a `:` on a line that has one is a property name;
        // otherwise the line is part of a selector.
        var colonAt = -1, braceAt = -1
        for k in i..<n {
            if chars[k] == 58 && colonAt < 0 { colonAt = k }
            if chars[k] == 123 { braceAt = k; break }
        }

        while i < n {
            if matches(chars, i, open) {
                var j = i + open.count
                while j < n && !matches(chars, j, close) { j += 1 }
                if j < n { push(&tokens, emit, base, i, j + close.count, .comment); i = j + close.count; continue }
                push(&tokens, emit, base, i, n, .comment)
                return .blockComment
            }
            if chars[i] == 34 || chars[i] == 39 {
                let quote = chars[i]
                var j = i + 1
                while j < n && chars[j] != quote { j += 1 }
                push(&tokens, emit, base, i, min(j + 1, n), .string)
                i = min(j + 1, n)
                continue
            }
            if chars[i] == 35 {           // '#': hex colour, or an id selector
                var j = i + 1
                while j < n && isIdentBodyU(chars[j]) { j += 1 }
                let body = word(chars, i + 1, j)
                let isHex = (body.count == 3 || body.count == 4 || body.count == 6 || body.count == 8)
                    && body.allSatisfy(\.isHexDigit)
                push(&tokens, emit, base, i, j, isHex ? .number : .type)
                i = j
                continue
            }
            if chars[i] == 64 {           // '@media', '@import'
                var j = i + 1
                while j < n && isIdentBodyU(chars[j]) { j += 1 }
                push(&tokens, emit, base, i, j, .keyword)
                i = j
                continue
            }
            if isDigitU(chars[i]) || (chars[i] == 46 && i + 1 < n && isDigitU(chars[i + 1])) {
                var j = i
                while j < n && (isDigitU(chars[j]) || chars[j] == 46) { j += 1 }
                while j < n && isLetterU(chars[j]) { j += 1 }   // px, rem, %
                if j < n && chars[j] == 37 { j += 1 }
                push(&tokens, emit, base, i, j, .number)
                i = j
                continue
            }
            if isIdentStartU(chars[i]) || chars[i] == 45 {
                var j = i
                while j < n && (isIdentBodyU(chars[j]) || chars[j] == 45) { j += 1 }
                let isProperty = colonAt > 0 && j <= colonAt && braceAt < 0
                push(&tokens, emit, base, i, j, isProperty ? .attribute : .type)
                i = j
                continue
            }
            if chars[i] == 46 && i + 1 < n && isIdentStartU(chars[i + 1]) {
                var j = i + 1
                while j < n && (isIdentBodyU(chars[j]) || chars[j] == 45) { j += 1 }
                push(&tokens, emit, base, i, j, .type)
                i = j
                continue
            }
            i += 1
        }
        return .normal
    }

    // MARK: - JSON

    func scanJSON(_ chars: [unichar], _ base: Int, _ entry: ScanState,
                  _ tokens: inout [Token], _ emit: Bool) -> ScanState {
        let n = chars.count
        var i = 0
        let open = units("/*"), close = units("*/")

        if case .blockComment = entry {
            var j = 0
            while j < n && !matches(chars, j, close) { j += 1 }
            if j < n { push(&tokens, emit, base, 0, j + close.count, .comment); i = j + close.count }
            else { push(&tokens, emit, base, 0, n, .comment); return .blockComment }
        }

        while i < n {
            if matches(chars, i, units("//")) { push(&tokens, emit, base, i, n, .comment); return .normal }
            if matches(chars, i, open) {
                var j = i + open.count
                while j < n && !matches(chars, j, close) { j += 1 }
                if j < n { push(&tokens, emit, base, i, j + close.count, .comment); i = j + close.count; continue }
                push(&tokens, emit, base, i, n, .comment)
                return .blockComment
            }
            if chars[i] == 34 {
                var j = i + 1
                while j < n {
                    if chars[j] == 92 { j += 2; continue }
                    if chars[j] == 34 { j += 1; break }
                    j += 1
                }
                let end = min(j, n)
                // A string followed by `:` is a key, and keys are what you scan
                // a JSON file for.
                var k = end
                while k < n && isSpaceU(chars[k]) { k += 1 }
                push(&tokens, emit, base, i, end, (k < n && chars[k] == 58) ? .attribute : .string)
                i = end
                continue
            }
            if isDigitU(chars[i]) || (chars[i] == 45 && i + 1 < n && isDigitU(chars[i + 1])) {
                var j = i + 1
                while j < n && (isDigitU(chars[j]) || chars[j] == 46 || chars[j] == 101 ||
                                chars[j] == 69 || chars[j] == 43 || chars[j] == 45) { j += 1 }
                push(&tokens, emit, base, i, j, .number)
                i = j
                continue
            }
            if isIdentStartU(chars[i]) {
                var j = i
                while j < n && isIdentBodyU(chars[j]) { j += 1 }
                let text = word(chars, i, j)
                push(&tokens, emit, base, i, j,
                     ["true", "false", "null"].contains(text) ? .keyword : .plain)
                i = j
                continue
            }
            i += 1
        }
        return .normal
    }

    // MARK: - YAML

    func scanYAML(_ chars: [unichar], _ base: Int, _ tokens: inout [Token], _ emit: Bool) -> ScanState {
        let n = chars.count
        var i = 0
        while i < n && (chars[i] == 32 || chars[i] == 9) { i += 1 }
        guard i < n else { return .normal }

        if chars[i] == 35 { push(&tokens, emit, base, i, n, .comment); return .normal }
        if matches(chars, i, units("---")) || matches(chars, i, units("...")) {
            push(&tokens, emit, base, i, n, .preprocessor)
            return .normal
        }
        if chars[i] == 45 && (i + 1 >= n || isSpaceU(chars[i + 1])) {
            push(&tokens, emit, base, i, i + 1, .op)
            i += 1
            while i < n && chars[i] == 32 { i += 1 }
        }

        // `key:` up to the first colon followed by space or end of line.
        var keyEnd = -1
        var k = i
        while k < n {
            if chars[k] == 35 && k > i && isSpaceU(chars[k - 1]) { break }
            if chars[k] == 58 && (k + 1 >= n || isSpaceU(chars[k + 1])) { keyEnd = k; break }
            k += 1
        }
        if keyEnd > i {
            push(&tokens, emit, base, i, keyEnd, .attribute)
            push(&tokens, emit, base, keyEnd, keyEnd + 1, .op)
            i = keyEnd + 1
        }

        while i < n {
            if chars[i] == 35 && (i == 0 || isSpaceU(chars[i - 1])) {
                push(&tokens, emit, base, i, n, .comment)
                return .normal
            }
            if chars[i] == 34 || chars[i] == 39 {
                let quote = chars[i]
                var j = i + 1
                while j < n && chars[j] != quote { j += 1 }
                push(&tokens, emit, base, i, min(j + 1, n), .string)
                i = min(j + 1, n)
                continue
            }
            if chars[i] == 38 || chars[i] == 42 {      // &anchor, *alias
                var j = i + 1
                while j < n && isIdentBodyU(chars[j]) { j += 1 }
                if j > i + 1 { push(&tokens, emit, base, i, j, .type); i = j; continue }
            }
            if isDigitU(chars[i]) {
                var j = i
                while j < n && (isDigitU(chars[j]) || chars[j] == 46) { j += 1 }
                if j >= n || isSpaceU(chars[j]) {
                    push(&tokens, emit, base, i, j, .number)
                    i = j
                    continue
                }
            }
            if isIdentStartU(chars[i]) {
                var j = i
                while j < n && isIdentBodyU(chars[j]) { j += 1 }
                let text = word(chars, i, j).lowercased()
                if ["true", "false", "null", "yes", "no", "on", "off", "~"].contains(text) {
                    push(&tokens, emit, base, i, j, .keyword)
                }
                i = j
                continue
            }
            i += 1
        }
        return .normal
    }

    // MARK: - INI and TOML

    func scanINI(_ chars: [unichar], _ base: Int, _ tokens: inout [Token], _ emit: Bool) -> ScanState {
        let n = chars.count
        var i = 0
        while i < n && (chars[i] == 32 || chars[i] == 9) { i += 1 }
        guard i < n else { return .normal }

        if chars[i] == 35 || chars[i] == 59 { push(&tokens, emit, base, i, n, .comment); return .normal }
        if chars[i] == 91 {
            var j = i
            while j < n && chars[j] != 93 { j += 1 }
            push(&tokens, emit, base, i, min(j + 1, n), .tag)
            return .normal
        }

        var eq = -1
        for k in i..<n where chars[k] == 61 { eq = k; break }
        if eq > i {
            push(&tokens, emit, base, i, eq, .attribute)
            push(&tokens, emit, base, eq, eq + 1, .op)
            i = eq + 1
        }
        while i < n {
            if chars[i] == 35 && (i == 0 || isSpaceU(chars[i - 1])) {
                push(&tokens, emit, base, i, n, .comment)
                return .normal
            }
            if chars[i] == 34 || chars[i] == 39 {
                let quote = chars[i]
                var j = i + 1
                while j < n && chars[j] != quote { j += 1 }
                push(&tokens, emit, base, i, min(j + 1, n), .string)
                i = min(j + 1, n)
                continue
            }
            if isDigitU(chars[i]) {
                var j = i
                while j < n && (isDigitU(chars[j]) || chars[j] == 46) { j += 1 }
                push(&tokens, emit, base, i, j, .number)
                i = j
                continue
            }
            if isIdentStartU(chars[i]) {
                var j = i
                while j < n && isIdentBodyU(chars[j]) { j += 1 }
                let text = word(chars, i, j).lowercased()
                if ["true", "false", "yes", "no", "on", "off"].contains(text) {
                    push(&tokens, emit, base, i, j, .keyword)
                }
                i = j
                continue
            }
            i += 1
        }
        return .normal
    }

    // MARK: - Markdown

    /// Markdown reuses `.blockComment` to mean "inside a fenced code block",
    /// which is the only state that carries across a line here.
    func scanMarkdown(_ chars: [unichar], _ base: Int, _ entry: ScanState,
                      _ tokens: inout [Token], _ emit: Bool) -> ScanState {
        let n = chars.count
        var i = 0
        let fence = units("```"), fenceAlt = units("~~~")

        if case .blockComment = entry {
            push(&tokens, emit, base, 0, n, .string)
            var k = 0
            while k < n && (chars[k] == 32 || chars[k] == 9) { k += 1 }
            return (matches(chars, k, fence) || matches(chars, k, fenceAlt)) ? .normal : .blockComment
        }

        var lead = 0
        while lead < n && (chars[lead] == 32 || chars[lead] == 9) { lead += 1 }
        if matches(chars, lead, fence) || matches(chars, lead, fenceAlt) {
            push(&tokens, emit, base, lead, n, .preprocessor)
            return .blockComment
        }
        if lead < n && chars[lead] == 35 {
            push(&tokens, emit, base, lead, n, .heading)
            return .normal
        }
        if lead < n && chars[lead] == 62 {
            push(&tokens, emit, base, lead, n, .docComment)
            return .normal
        }
        if lead < n && (chars[lead] == 45 || chars[lead] == 42 || chars[lead] == 43)
            && lead + 1 < n && chars[lead + 1] == 32 {
            push(&tokens, emit, base, lead, lead + 1, .keyword)
            i = lead + 1
        }

        while i < n {
            if chars[i] == 96 {                       // `inline code`
                var j = i + 1
                while j < n && chars[j] != 96 { j += 1 }
                push(&tokens, emit, base, i, min(j + 1, n), .string)
                i = min(j + 1, n)
                continue
            }
            if chars[i] == 42 || chars[i] == 95 {     // emphasis
                let marker = chars[i]
                let double = i + 1 < n && chars[i + 1] == marker
                let width = double ? 2 : 1
                var j = i + width
                while j < n && !(chars[j] == marker && (!double || (j + 1 < n && chars[j + 1] == marker))) { j += 1 }
                if j < n {
                    push(&tokens, emit, base, i, min(j + width, n), double ? .keyword : .type)
                    i = min(j + width, n)
                    continue
                }
            }
            if chars[i] == 91 {                       // [text](url)
                var j = i
                while j < n && chars[j] != 93 { j += 1 }
                push(&tokens, emit, base, i, min(j + 1, n), .link)
                j = min(j + 1, n)
                if j < n && chars[j] == 40 {
                    let urlStart = j
                    while j < n && chars[j] != 41 { j += 1 }
                    push(&tokens, emit, base, urlStart, min(j + 1, n), .attribute)
                    j = min(j + 1, n)
                }
                i = j
                continue
            }
            i += 1
        }
        return .normal
    }
}
