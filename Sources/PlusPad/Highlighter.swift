import AppKit

/// The classes of text the scanner can recognise. Deliberately small: more
/// categories than the eye can distinguish makes code harder to read, not easier.
enum TokenKind: UInt8 {
    case plain
    case keyword
    case type
    case string
    case escape
    case comment
    case docComment
    case number
    case preprocessor
    case tag
    case attribute
    case function
    case op
    case heading
    case link
    case invalid
}

struct Token {
    var range: NSRange
    var kind: TokenKind
}

/// Where the scanner stands at the first character of a line. Everything else
/// about a line can be derived from its own characters; only these three carry
/// across a line boundary, which is why they are the only thing cached.
enum ScanState: Equatable {
    case normal
    case blockComment
    /// Index into the language's `multilineStrings`.
    case multilineString(Int)
}

/// A cache of line start offsets, repaired incrementally as the text changes.
///
/// Every other part of the editor that needs to speak in line numbers -- the
/// gutter, Go To Line, the status bar, bookmarks, the highlighter's own state
/// cache -- asks this. Rebuilding it on each keystroke would be the single
/// hottest thing in the app on a large file, so an edit only re-scans the lines
/// it actually touched and shifts the offsets after it.
final class LineIndex {
    private(set) var starts: [Int] = [0]
    private(set) var length: Int = 0

    var lineCount: Int { starts.count }

    func rebuild(_ text: NSString) {
        length = text.length
        var result: [Int] = [0]
        result.reserveCapacity(max(16, length / 40))
        scanNewlines(text, from: 0, to: length) { result.append($0 + 1) }
        starts = result
    }

    /// Repair after an edit. `editedRange` is in the new text; `delta` is the
    /// change in length.
    func update(_ text: NSString, editedRange: NSRange, delta: Int) {
        guard !starts.isEmpty, length + delta == text.length else {
            rebuild(text)
            return
        }
        let firstLine = lineIndex(containing: editedRange.location)
        let regionStart = starts[firstLine]
        let regionEnd = min(text.length, editedRange.location + editedRange.length)

        // Line starts strictly beyond the old edited region are untouched except
        // that they all slide by `delta`.
        let oldRegionEnd = editedRange.location + editedRange.length - delta
        var tailIndex = firstLine + 1
        while tailIndex < starts.count && starts[tailIndex] <= oldRegionEnd { tailIndex += 1 }

        var rebuilt: [Int] = []
        scanNewlines(text, from: regionStart, to: regionEnd) { rebuilt.append($0 + 1) }

        var next = Array(starts[0...firstLine])
        next.append(contentsOf: rebuilt)
        if tailIndex < starts.count {
            next.append(contentsOf: starts[tailIndex...].map { $0 + delta })
        }
        // The two halves cannot overlap: the rescan is exclusive of `regionEnd`
        // and the tail only keeps starts strictly past `oldRegionEnd`.
        starts = next
        length = text.length
    }

    /// Zero-based index of the line containing `offset`.
    func lineIndex(containing offset: Int) -> Int {
        guard starts.count > 1 else { return 0 }
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func start(ofLine index: Int) -> Int {
        guard index >= 0 else { return 0 }
        guard index < starts.count else { return length }
        return starts[index]
    }

    /// End of the line's contents plus its terminator, clamped to the text.
    func end(ofLine index: Int) -> Int {
        index + 1 < starts.count ? starts[index + 1] : length
    }

    func range(ofLine index: Int) -> NSRange {
        let s = start(ofLine: index)
        return NSRange(location: s, length: max(0, end(ofLine: index) - s))
    }

    /// Character range spanning whole lines `first` through `last`, inclusive.
    func range(fromLine first: Int, toLine last: Int) -> NSRange {
        let s = start(ofLine: max(0, first))
        let e = end(ofLine: min(last, starts.count - 1))
        return NSRange(location: s, length: max(0, e - s))
    }

    private func scanNewlines(_ text: NSString, from: Int, to: Int, _ found: (Int) -> Void) {
        guard to > from else { return }
        let chunkSize = 8192
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var offset = from
        while offset < to {
            let count = min(chunkSize, to - offset)
            text.getCharacters(&buffer, range: NSRange(location: offset, length: count))
            for i in 0..<count where buffer[i] == 0x0A {
                found(offset + i)
            }
            offset += count
        }
    }
}

/// Scans text into tokens for one language, caching the state at each line start.
///
/// Only the visible slice is ever tokenised. What makes that possible without
/// getting block comments and triple-quoted strings wrong is `lineStates`: the
/// scanner records how each line ended, so highlighting a line halfway down a
/// file only requires walking forward from the last line whose state is still
/// known, not from the top of the document.
final class SyntaxHighlighter {

    var language: LanguageDef {
        didSet {
            guard language.name != oldValue.name else { return }
            invalidateAll()
        }
    }
    private var lineStates: [ScanState] = [.normal]
    /// Highest line index whose *entry* state in `lineStates` is trustworthy.
    private var validThrough: Int = 0

    init(language: LanguageDef = LanguageRegistry.plainText) {
        self.language = language
    }

    func invalidateAll() {
        lineStates = [.normal]
        validThrough = 0
    }

    /// Called after an edit: everything at or below the edited line is suspect.
    func invalidate(fromLine line: Int) {
        validThrough = min(validThrough, max(0, line))
        if lineStates.count > validThrough + 1 {
            lineStates.removeSubrange((validThrough + 1)...)
        }
    }

    /// Tokens for whole lines `firstLine` through `lastLine`.
    func tokens(in text: NSString, index: LineIndex, firstLine: Int, lastLine: Int) -> [Token] {
        if case .plain = language.flavor { return [] }
        let first = max(0, firstLine)
        let last = min(lastLine, index.lineCount - 1)
        guard first <= last else { return [] }

        advanceStates(to: first, text: text, index: index)

        var state = stateAtLine(first)
        var tokens: [Token] = []
        tokens.reserveCapacity((last - first + 1) * 8)

        for line in first...last {
            let range = index.range(ofLine: line)
            state = scanLine(text, range, state: state, into: &tokens)
            recordState(state, forLineAfter: line)
        }
        return tokens
    }

    /// Walk forward without emitting tokens until the entry state of `target` is
    /// known. This is the only part that can touch text far from the viewport,
    /// and it happens once per edit rather than once per scroll.
    private func advanceStates(to target: Int, text: NSString, index: LineIndex) {
        guard target > validThrough else { return }
        var state = stateAtLine(validThrough)
        var throwaway: [Token] = []
        var line = validThrough
        while line < target {
            let range = index.range(ofLine: line)
            throwaway.removeAll(keepingCapacity: true)
            state = scanLine(text, range, state: state, into: &throwaway, emit: false)
            recordState(state, forLineAfter: line)
            line += 1
        }
    }

    private func stateAtLine(_ line: Int) -> ScanState {
        line < lineStates.count ? lineStates[line] : .normal
    }

    private func recordState(_ state: ScanState, forLineAfter line: Int) {
        let slot = line + 1
        while lineStates.count <= slot { lineStates.append(.normal) }
        lineStates[slot] = state
        validThrough = max(validThrough, slot)
    }

    // MARK: - Per-line scanning

    private func scanLine(_ text: NSString, _ range: NSRange, state: ScanState,
                          into tokens: inout [Token], emit: Bool = true) -> ScanState {
        // Scan the line's contents without its terminator. A token that ran to
        // the end of the range would otherwise include the newline, which is
        // wrong as a boundary and paints past the last glyph as soon as a token
        // carries a background colour.
        var length = range.length
        while length > 0 {
            let last = text.character(at: range.location + length - 1)
            guard last == 0x0A || last == 0x0D else { break }
            length -= 1
        }
        guard length > 0 else { return state }
        let range = NSRange(location: range.location, length: length)

        var chars = [unichar](repeating: 0, count: range.length)
        text.getCharacters(&chars, range: range)
        let base = range.location

        switch language.flavor {
        case .cLike:    return scanCLike(chars, base, state, &tokens, emit)
        case .markup:   return scanMarkup(chars, base, state, &tokens, emit)
        case .css:      return scanCSS(chars, base, state, &tokens, emit)
        case .json:     return scanJSON(chars, base, state, &tokens, emit)
        case .yaml:     return scanYAML(chars, base, &tokens, emit)
        case .ini:      return scanINI(chars, base, &tokens, emit)
        case .markdown: return scanMarkdown(chars, base, state, &tokens, emit)
        case .plain:    return .normal
        }
    }
}
