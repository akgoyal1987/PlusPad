import AppKit

protocol EditorTextViewDelegate: AnyObject {
    func editorTextDidChange(_ editor: EditorTextView)
    func editorSelectionDidChange(_ editor: EditorTextView)
}

/// The text view itself: editing behaviour, and every decoration Notepad++
/// draws behind the glyphs.
///
/// Syntax colours are applied as *temporary* attributes on the layout manager
/// rather than written into the text storage. That keeps them out of the undo
/// stack (undoing a paste must not step back through a hundred recolourings),
/// keeps the storage's attributes uniform so copy and paste carry plain text,
/// and makes re-highlighting after a scroll free of any document mutation.
final class EditorTextView: NSTextView {

    weak var document: TextDocument?
    weak var editorDelegate: EditorTextViewDelegate?

    var theme: Theme = .classic {
        didSet { applyThemeToChrome(); rebuildBaseAttributes(); needsDisplay = true }
    }
    var settings: Settings = Settings() {
        didSet { applySettings(); }
    }

    /// Ranges the find bar has asked to be shown highlighted.
    private var findHighlights: [NSRange] = []
    private var currentFindHighlight: NSRange?
    /// Occurrences of the word under the cursor, Notepad++'s "smart highlight".
    private var smartHighlights: [NSRange] = []
    private var matchingBracket: NSRange?

    private var highlightWorkPending = false

    /// Character ranges folded away. Cached because the layout manager asks
    /// about them once per glyph run, which is far too hot to recompute in.
    private(set) var hiddenRanges: [NSRange] = []

    // MARK: - Construction

    init(document: TextDocument, settings: Settings, theme: Theme) {
        self.document = document
        self.settings = settings
        self.theme = theme
        super.init(frame: .zero, textContainer: document.textContainer)

        isEditable = true
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        usesFindBar = false
        isIncrementalSearchingEnabled = false
        smartInsertDeleteEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = true
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 2, height: 2)

        document.layoutManager.delegate = self

        applyThemeToChrome()
        applySettings()
        rebuildBaseAttributes()
    }

    // MARK: - Folding

    /// Rebuild which lines can fold, preserving what the user has collapsed.
    func recomputeFolds() {
        guard let document else { return }
        document.foldModel.recompute(text: document.textStorage.string as NSString,
                                     index: document.lineIndex,
                                     tabWidth: settings.tabWidth)
        refreshFolding()
    }

    /// Push the current fold state into the layout manager.
    ///
    /// Both invalidations are needed and in this order: glyphs decide what is
    /// drawn, layout decides how tall the line is, and invalidating only the
    /// first leaves full-height blank gaps where the folded text used to be.
    func refreshFolding() {
        guard let document, let layoutManager else { return }
        hiddenRanges = document.foldModel.hiddenCharacterRanges(index: document.lineIndex)
        let full = NSRange(location: 0, length: document.textStorage.length)
        layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0,
                                       actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        needsDisplay = true
        setNeedsHighlight()
    }

    func toggleFold(atLine line: Int) {
        guard let document, document.foldModel.isHeader(line) else { return }
        document.foldModel.toggle(line)
        refreshFolding()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Expand whatever hides `line`, so navigation can always land on it.
    func revealLine(_ line: Int) {
        guard let document, document.foldModel.isHidden(line) else { return }
        document.foldModel.reveal(line)
        refreshFolding()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    private func isEntirelyHidden(_ range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        return hiddenRanges.contains {
            range.location >= $0.location && range.location + range.length <= $0.location + $0.length
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func applyThemeToChrome() {
        backgroundColor = theme.background
        insertionPointColor = theme.cursor
        selectedTextAttributes = [.backgroundColor: theme.selection]
        typingAttributes = [.font: settings.editorFont, .foregroundColor: theme.foreground]
    }

    private func applySettings() {
        let font = settings.editorFont
        // The default tab stops are set for proportional text; replace them with
        // a single repeating interval so a tab is exactly `tabWidth` columns.
        let paragraph = NSMutableParagraphStyle()
        let advance = (" " as NSString).size(withAttributes: [.font: font]).width
        paragraph.defaultTabInterval = advance * CGFloat(max(1, settings.tabWidth))
        paragraph.tabStops = []
        defaultParagraphStyle = paragraph

        if settings.wordWrap {
            // Let the container follow the text view's own width rather than
            // computing one. `scrollView.contentSize` is the full clip width and
            // does not subtract the ruler, so deriving the wrap width from it
            // made every wrapped row about a gutter's worth too long and pushed
            // the tail off the right edge.
            isHorizontallyResizable = false
            textContainer?.widthTracksTextView = true
            textContainer?.containerSize = NSSize(width: max(1, bounds.width),
                                                  height: CGFloat.greatestFiniteMagnitude)
            autoresizingMask = [.width]
        } else {
            textContainer?.widthTracksTextView = false
            textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
            isHorizontallyResizable = true
            autoresizingMask = [.width, .height]
        }
        applyThemeToChrome()
        rebuildBaseAttributes()
    }

    /// Reset font, colour and tab stops across the whole document. Everything
    /// syntax-specific is layered on top of this as temporary attributes.
    func rebuildBaseAttributes() {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: settings.editorFont,
            .foregroundColor: theme.foreground,
        ]
        if let paragraph = defaultParagraphStyle { attributes[.paragraphStyle] = paragraph }
        storage.beginEditing()
        storage.setAttributes(attributes, range: full)
        storage.endEditing()
        setNeedsHighlight()
    }

    // MARK: - Highlighting

    func setNeedsHighlight() {
        guard !highlightWorkPending else { return }
        highlightWorkPending = true
        // Coalesce to the end of the run loop so a burst of edits, a scroll and
        // a selection change together cost one pass, not three.
        DispatchQueue.main.async { [weak self] in
            self?.highlightWorkPending = false
            self?.refreshHighlighting()
        }
    }

    /// The character range currently on screen, expanded to whole lines and
    /// padded so a small scroll does not immediately need another pass.
    private func visibleLineRange(padding: Int = 40) -> (NSRange, Int, Int)? {
        guard let document, let layoutManager, let container = textContainer else { return nil }
        let storageLength = document.textStorage.length
        guard storageLength > 0 else { return nil }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let index = document.lineIndex
        let first = max(0, index.lineIndex(containing: min(charRange.location, storageLength - 1)) - padding)
        let lastChar = min(storageLength - 1, max(charRange.location, charRange.location + charRange.length - 1))
        let last = min(index.lineCount - 1, index.lineIndex(containing: lastChar) + padding)
        guard first <= last else { return nil }
        return (index.range(fromLine: first, toLine: last), first, last)
    }

    func refreshHighlighting() {
        guard let document, let layoutManager else { return }
        guard let (range, firstLine, lastLine) = visibleLineRange() else { return }
        let clamped = NSRange(location: range.location,
                              length: min(range.length, document.textStorage.length - range.location))
        guard clamped.length > 0 else { return }

        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: clamped)
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: clamped)
        layoutManager.addTemporaryAttributes([.foregroundColor: theme.foreground], forCharacterRange: clamped)

        let tokens = document.highlighter.tokens(in: document.textStorage.string as NSString,
                                                 index: document.lineIndex,
                                                 firstLine: firstLine, lastLine: lastLine)
        let boldFont = NSFontManager.shared.convert(settings.editorFont, toHaveTrait: .boldFontMask)
        for token in tokens {
            let end = token.range.location + token.range.length
            guard token.range.location >= 0, end <= document.textStorage.length else { continue }
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: theme.color(token.kind)]
            if theme.isBold(token.kind) { attributes[.font] = boldFont }
            layoutManager.addTemporaryAttributes(attributes, forCharacterRange: token.range)
        }

        applyMatchHighlights(in: clamped)
    }

    /// Find results, marked lines and smart highlight all draw as background
    /// colour, applied after the syntax pass so they sit on top of it.
    private func applyMatchHighlights(in visible: NSRange) {
        guard let layoutManager else { return }
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: visible)

        func paint(_ ranges: [NSRange], _ color: NSColor) {
            for range in ranges where NSIntersectionRange(range, visible).length > 0 {
                layoutManager.addTemporaryAttributes([.backgroundColor: color], forCharacterRange: range)
            }
        }
        paint(smartHighlights, theme.smartHighlight)
        paint(findHighlights, theme.findHighlight)
        if let current = currentFindHighlight { paint([current], theme.findCurrent) }
        if let bracket = matchingBracket { paint([bracket], theme.bracketMatch) }
    }

    func setFindHighlights(_ ranges: [NSRange], current: NSRange?) {
        findHighlights = ranges
        currentFindHighlight = current
        setNeedsHighlight()
    }

    func clearFindHighlights() {
        findHighlights = []
        currentFindHighlight = nil
        setNeedsHighlight()
    }

    // MARK: - Decoration drawing

    override func drawBackground(in rect: NSRect) {
        theme.background.setFill()
        bounds.intersection(rect).fill()
        drawCurrentLineHighlight(in: rect)
        drawIndentGuides(in: rect)
        drawInvisibles(in: rect)
    }

    private func drawCurrentLineHighlight(in rect: NSRect) {
        guard settings.highlightCurrentLine,
              let layoutManager, let container = textContainer,
              let storage = textStorage else { return }
        let selection = selectedRange()
        // Only when the cursor is a caret: painting a band behind a multi-line
        // selection fights with the selection colour and reads as a glitch.
        guard selection.length == 0, storage.length >= 0 else { return }

        let location = min(selection.location, storage.length)
        var lineRange = NSRange(location: location, length: 0)
        if storage.length > 0 {
            lineRange = (storage.string as NSString)
                .lineRange(for: NSRange(location: min(location, storage.length - 1), length: 0))
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        if storage.length == 0 || frame.height == 0 {
            frame = NSRect(x: 0, y: 0, width: bounds.width,
                           height: layoutManager.defaultLineHeight(for: settings.editorFont))
        }
        frame.origin.x = 0
        frame.origin.y += textContainerInset.height
        frame.size.width = max(bounds.width, frame.width)
        guard frame.intersects(rect) else { return }
        theme.currentLine.setFill()
        frame.fill()
    }

    private func drawIndentGuides(in rect: NSRect) {
        guard settings.showIndentGuides, let document, let layoutManager else { return }
        guard let (_, firstLine, lastLine) = visibleLineRange(padding: 2) else { return }
        let text = document.textStorage.string as NSString
        let advance = (" " as NSString).size(withAttributes: [.font: settings.editorFont]).width
        guard advance > 0.5 else { return }

        theme.indentGuide.setFill()
        for line in firstLine...lastLine {
            let lineRange = document.lineIndex.range(ofLine: line)
            guard lineRange.length > 0, lineRange.location + lineRange.length <= text.length else { continue }

            var columns = 0
            var offset = lineRange.location
            let limit = lineRange.location + lineRange.length
            while offset < limit {
                let ch = text.character(at: offset)
                if ch == 32 { columns += 1 }
                else if ch == 9 { columns += settings.tabWidth - (columns % settings.tabWidth) }
                else { break }
                offset += 1
            }
            // A blank line has no indentation of its own; drawing guides across
            // it anyway is what makes the column of dots read as continuous.
            guard columns >= settings.tabWidth else { continue }

            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let y = fragment.origin.y + textContainerInset.height
            guard y < rect.maxY, y + fragment.height > rect.minY else { continue }

            var level = 1
            while level * settings.tabWidth <= columns {
                let x = textContainerInset.width + advance * CGFloat(level * settings.tabWidth)
                NSRect(x: x.rounded(), y: y, width: 1, height: fragment.height).fill()
                level += 1
            }
        }
    }

    /// Space, tab and end-of-line markers, drawn the way Notepad++ shows them:
    /// a centred dot, a right arrow, and a literal CR/LF label.
    private func drawInvisibles(in rect: NSRect) {
        guard settings.showInvisibles, let document, let layoutManager else { return }
        guard let (range, _, _) = visibleLineRange(padding: 2) else { return }
        let text = document.textStorage.string as NSString
        let clamped = NSRange(location: range.location,
                              length: min(range.length, text.length - range.location))
        guard clamped.length > 0 else { return }

        let markerFont = NSFont(name: settings.fontName, size: CGFloat(settings.fontSize) * 0.85)
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(settings.fontSize) * 0.85, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: markerFont, .foregroundColor: theme.invisibles,
        ]
        let eolLabel = document.lineEnding == .crlf ? "CRLF" : (document.lineEnding == .cr ? "CR" : "LF")

        for offset in clamped.location..<(clamped.location + clamped.length) {
            let ch = text.character(at: offset)
            guard ch == 32 || ch == 9 || ch == 10 else { continue }
            let glyph = layoutManager.glyphIndexForCharacter(at: offset)
            guard glyph != NSNotFound else { continue }
            var spot = layoutManager.location(forGlyphAt: glyph)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            spot.x += fragment.origin.x + textContainerInset.width
            spot.y = fragment.origin.y + textContainerInset.height

            guard spot.y < rect.maxY, spot.y + fragment.height > rect.minY else { continue }

            switch ch {
            case 32:
                let dot = "·" as NSString
                let size = dot.size(withAttributes: attributes)
                let advance = (" " as NSString).size(withAttributes: [.font: settings.editorFont]).width
                dot.draw(at: NSPoint(x: spot.x + (advance - size.width) / 2,
                                     y: spot.y + (fragment.height - size.height) / 2),
                         withAttributes: attributes)
            case 9:
                let arrow = "→" as NSString
                let size = arrow.size(withAttributes: attributes)
                arrow.draw(at: NSPoint(x: spot.x + 1, y: spot.y + (fragment.height - size.height) / 2),
                           withAttributes: attributes)
            default:
                (eolLabel as NSString).draw(
                    at: NSPoint(x: spot.x + 1, y: spot.y + (fragment.height - markerFont.pointSize) / 2 - 1),
                    withAttributes: attributes)
            }
        }
    }

    // MARK: - Editing behaviour

    override func didChangeText() {
        super.didChangeText()
        editorDelegate?.editorTextDidChange(self)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting else { return }
        updateBracketMatch()
        updateSmartHighlight()
        needsDisplay = true
        editorDelegate?.editorSelectionDidChange(self)
    }

    /// Newline that carries the current line's indentation forward, and opens a
    /// block out by one level after a trailing brace.
    override func insertNewline(_ sender: Any?) {
        guard settings.autoIndent, let storage = textStorage, storage.length > 0 else {
            super.insertNewline(sender)
            return
        }
        let text = storage.string as NSString
        let caret = min(selectedRange().location, text.length)
        let lineRange = text.lineRange(for: NSRange(location: max(0, caret - (caret > 0 ? 1 : 0)), length: 0))
        let line = text.substring(with: NSRange(location: lineRange.location,
                                                length: max(0, min(caret, lineRange.location + lineRange.length) - lineRange.location)))
        var indent = String(line.prefix { $0 == " " || $0 == "\t" })

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let opensBlock = trimmed.hasSuffix("{") || trimmed.hasSuffix("[") || trimmed.hasSuffix("(")
            || trimmed.hasSuffix(":")
        if opensBlock { indent += settings.indentUnit }

        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }

        // A caret placed between a matched pair gets the closing brace pushed on
        // to its own line, which is the behaviour people expect from `{|}`.
        if opensBlock, caret < text.length {
            let after = text.character(at: min(caret, text.length - 1))
            if after == 125 || after == 93 || after == 41 {
                let here = selectedRange()
                let closingIndent = String(indent.dropLast(settings.indentUnit.count))
                insertText("\n" + closingIndent, replacementRange: here)
                setSelectedRange(NSRange(location: here.location, length: 0))
            }
        }
    }

    /// Tab indents a multi-line selection instead of replacing it, which is the
    /// single most important difference between a text field and a code editor.
    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0, let storage = textStorage {
            let text = storage.string as NSString
            let lines = text.lineRange(for: selection)
            if text.substring(with: lines).contains("\n") {
                indentSelection(by: 1)
                return
            }
        }
        if settings.insertSpaces {
            let column = currentColumn()
            let pad = settings.tabWidth - (column % settings.tabWidth)
            insertText(String(repeating: " ", count: pad), replacementRange: selection)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        indentSelection(by: -1)
    }

    /// Shift whole lines in or out by one level, preserving the selection.
    func indentSelection(by levels: Int) {
        guard let storage = textStorage, let document else { return }
        let text = storage.string as NSString
        let selection = selectedRange()
        let lineRange = text.lineRange(for: selection)
        let original = text.substring(with: lineRange)
        let hasTrailingNewline = original.hasSuffix("\n")
        let body = hasTrailingNewline ? String(original.dropLast()) : original

        let updated = levels > 0
            ? TextOps.indent(body, using: settings.indentUnit)
            : TextOps.outdent(body, width: settings.tabWidth, usesTabs: !settings.insertSpaces)
        guard updated != body else { return }

        let replacement = hasTrailingNewline ? updated + "\n" : updated
        guard shouldChangeText(in: lineRange, replacementString: replacement) else { return }
        storage.replaceCharacters(in: lineRange, with: replacement)
        didChangeText()

        let delta = (replacement as NSString).length - lineRange.length
        setSelectedRange(NSRange(location: lineRange.location,
                                 length: max(0, selection.length + delta
                                             + (selection.location - lineRange.location))))
        _ = document
    }

    private func currentColumn() -> Int {
        guard let storage = textStorage, storage.length > 0 else { return 0 }
        let text = storage.string as NSString
        let caret = min(selectedRange().location, text.length)
        let lineStart = text.lineRange(for: NSRange(location: max(0, caret - (caret > 0 ? 1 : 0)), length: 0)).location
        var column = 0
        var offset = lineStart
        while offset < caret {
            column += (text.character(at: offset) == 9)
                ? settings.tabWidth - (column % settings.tabWidth) : 1
            offset += 1
        }
        return column
    }

    private static let bracketPairs: [Character: Character] = ["(": ")", "[": "]", "{": "}",
                                                               "\"": "\"", "'": "'", "`": "`"]

    private static let closingBrackets: Set<Character> = [")", "]", "}"]

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard settings.autoCloseBrackets, let typed = string as? String, typed.count == 1,
              let character = typed.first else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        // Typing the closer that auto-close already inserted walks past it
        // rather than leaving `())` behind.
        if EditorTextView.closingBrackets.contains(character),
           selectedRange().length == 0, let storage = textStorage,
           selectedRange().location < storage.length,
           (storage.string as NSString).character(at: selectedRange().location)
             == unichar(character.unicodeScalars.first!.value) {
            setSelectedRange(NSRange(location: selectedRange().location + 1, length: 0))
            return
        }

        guard let closer = EditorTextView.bracketPairs[character] else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let opener = character
        let selection = selectedRange()

        // Wrapping a selection in brackets is more often what is meant than
        // replacing it, and it is the only way to get the pair around existing
        // text without retyping it.
        if selection.length > 0, let storage = textStorage {
            let inner = (storage.string as NSString).substring(with: selection)
            let wrapped = typed + inner + String(closer)
            guard shouldChangeText(in: selection, replacementString: wrapped) else { return }
            storage.replaceCharacters(in: selection, with: wrapped)
            didChangeText()
            setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
            return
        }

        // Typing a quote where one already sits just steps over it.
        if let storage = textStorage, selection.location < storage.length {
            let next = (storage.string as NSString).character(at: selection.location)
            if next == unichar(String(closer).unicodeScalars.first!.value), opener == closer {
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
                return
            }
        }

        super.insertText(typed + String(closer), replacementRange: replacementRange)
        setSelectedRange(NSRange(location: selectedRange().location - 1, length: 0))
    }

    // MARK: - Bracket matching and smart highlight

    private func updateBracketMatch() {
        matchingBracket = nil
        guard let storage = textStorage, storage.length > 0 else { return }
        let selection = selectedRange()
        guard selection.length == 0 else { return }
        let text = storage.string as NSString

        let openers: [unichar] = [40, 91, 123]
        let closers: [unichar] = [41, 93, 125]

        // Check the character just before the caret first, then the one after:
        // that ordering is what makes the match follow the caret naturally as it
        // moves past a bracket.
        for probe in [selection.location - 1, selection.location] {
            guard probe >= 0, probe < text.length else { continue }
            let ch = text.character(at: probe)
            if let index = openers.firstIndex(of: ch) {
                if let match = scanForBracket(in: text, from: probe + 1, open: ch,
                                              close: closers[index], step: 1) {
                    matchingBracket = NSRange(location: match, length: 1)
                    return
                }
            }
            if let index = closers.firstIndex(of: ch) {
                if let match = scanForBracket(in: text, from: probe - 1, open: ch,
                                              close: openers[index], step: -1) {
                    matchingBracket = NSRange(location: match, length: 1)
                    return
                }
            }
        }
    }

    /// Walk outward counting nesting depth. Capped so a stray brace in a very
    /// large file cannot make every cursor move scan megabytes.
    private func scanForBracket(in text: NSString, from: Int, open: unichar, close: unichar,
                                step: Int) -> Int? {
        var depth = 1
        var offset = from
        var budget = 200_000
        while offset >= 0, offset < text.length, budget > 0 {
            let ch = text.character(at: offset)
            if ch == open { depth += 1 }
            else if ch == close {
                depth -= 1
                if depth == 0 { return offset }
            }
            offset += step
            budget -= 1
        }
        return nil
    }

    /// Highlight every other occurrence of the selected word, Notepad++'s
    /// "smart highlighting".
    private func updateSmartHighlight() {
        smartHighlights = []
        guard settings.smartHighlight, let storage = textStorage, storage.length > 0 else { return }
        let selection = selectedRange()
        guard selection.length > 0, selection.length < 100 else { return }
        let text = storage.string as NSString
        let needle = text.substring(with: selection)
        guard !needle.isEmpty,
              needle.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              needle.count >= 2 else { return }

        // Scan only what is on screen. Searching a large document on every
        // selection change is exactly the kind of per-keystroke cost that makes
        // an editor feel slow.
        guard let (visible, _, _) = visibleLineRange(padding: 10) else { return }
        let scope = NSRange(location: visible.location,
                            length: min(visible.length, text.length - visible.location))
        var found: [NSRange] = []
        var cursor = scope.location
        while cursor < scope.location + scope.length {
            let hit = text.range(of: needle, options: [.literal],
                                 range: NSRange(location: cursor,
                                                length: scope.location + scope.length - cursor))
            guard hit.location != NSNotFound else { break }
            if hit.location != selection.location { found.append(hit) }
            cursor = hit.location + max(1, hit.length)
            if found.count > 500 { break }
        }
        smartHighlights = found
    }
}


// MARK: - Folding through the layout manager

/// Folding is done by suppressing glyphs and collapsing line fragments rather
/// than by removing text. The characters stay in the storage, so undo, search,
/// selection offsets, saving and the backup file are all untouched by whether
/// something happens to be folded.
extension EditorTextView: NSLayoutManagerDelegate {

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }

        var adjusted = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        var changed = false
        for offset in 0..<glyphRange.length {
            var property = props[offset]
            let character = charIndexes[offset]
            if hiddenRanges.contains(where: { NSLocationInRange(character, $0) }) {
                property.insert(.null)
                changed = true
            }
            adjusted[offset] = property
        }
        guard changed else { return 0 }

        layoutManager.setGlyphs(glyphs, properties: &adjusted, characterIndexes: charIndexes,
                                font: aFont, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard !hiddenRanges.isEmpty else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                      actualGlyphRange: nil)
        guard isEntirelyHidden(characters) else { return false }
        // Zero height rather than hidden: the fragment still exists, so glyph
        // and character indexes stay in step with the unfolded document.
        lineFragmentRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.size.height = 0
        baselineOffset.pointee = 0
        return true
    }
}
