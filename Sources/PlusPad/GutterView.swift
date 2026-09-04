import AppKit

/// The left margin: bookmarks, line numbers, and the fold column.
///
/// Laid out in Notepad++'s order -- bookmark margin, then right-aligned line
/// numbers on the editor's own background, then the fold column with its box
/// markers, then a hairline against the text. Drawn as an `NSRulerView` so
/// AppKit keeps it scrolled in step with the text for free, rather than the app
/// mirroring the scroll offset into a second view and getting it subtly wrong
/// during live resize.
final class GutterView: NSRulerView {

    weak var editor: EditorTextView?
    var theme: Theme = .classic { didSet { needsDisplay = true } }
    var font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { recalculateWidth(); needsDisplay = true }
    }
    var showsLineNumbers = true { didSet { recalculateWidth(); needsDisplay = true } }
    var showsBookmarks = true { didSet { recalculateWidth(); needsDisplay = true } }
    var showsFoldMargin = true { didSet { recalculateWidth(); needsDisplay = true } }

    private let numberPadding: CGFloat = 8
    private let bookmarkWidth: CGFloat = 12
    private let foldWidth: CGFloat = 14

    init(scrollView: NSScrollView, editor: EditorTextView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clipsToBounds = true
        clientView = editor
        recalculateWidth()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// Width of the number column alone.
    private var numbersWidth: CGFloat {
        guard showsLineNumbers, let document = editor?.document else { return 0 }
        // Floor of three digits so a short file does not visibly jitter as it
        // grows from line 9 to line 10.
        let digits = max(3, String(document.lineIndex.lineCount).count)
        let sample = String(repeating: "8", count: digits)
        return (sample as NSString).size(withAttributes: [.font: font]).width + numberPadding * 2
    }

    private var foldColumnX: CGFloat {
        (showsBookmarks ? bookmarkWidth : 0) + numbersWidth
    }

    func recalculateWidth() {
        var width = foldColumnX
        if showsFoldMargin { width += foldWidth }
        ruleThickness = max(width, 1)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor,
              let document = editor.document,
              let layoutManager = editor.layoutManager,
              let container = editor.textContainer else { return }

        // The number column shares the editor's ground, the way Notepad++ draws
        // it; the fold column is the only part that is tinted.
        theme.gutterBackground.setFill()
        bounds.intersection(rect).fill()

        // Height comes from `bounds`, never from `rect`. The dirty rect is the
        // window's, expressed in this view's coordinates, so using its y and
        // height drew this hairline the full height of the window -- straight up
        // through the tab bar and the toolbar.
        theme.gutterSeparator.setFill()
        NSRect(x: bounds.width - 1, y: bounds.minY, width: 1, height: bounds.height)
            .intersection(rect).fill()

        let visibleRect = editor.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        guard glyphRange.length > 0 || document.textStorage.length == 0 else { return }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let index = document.lineIndex
        let folds = document.foldModel
        let firstLine = index.lineIndex(containing: charRange.location)
        let lastLine = index.lineIndex(containing: max(charRange.location,
                                                      charRange.location + charRange.length - 1))
        let currentLine = index.lineIndex(containing: min(editor.selectedRange().location,
                                                         max(0, document.textStorage.length)))
        let inset = editor.textContainerInset
        let originY = convert(NSPoint.zero, from: editor).y

        let normalAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: theme.gutterForeground,
        ]
        let activeAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: theme.gutterActiveForeground,
        ]

        for line in firstLine...max(firstLine, lastLine) {
            // A folded-away line has a zero-height fragment; drawing its number
            // would stack every hidden number on the header's row.
            guard !folds.isHidden(line) else { continue }

            let lineRange = index.range(ofLine: line)
            guard lineRange.location <= document.textStorage.length else { break }
            let safeRange = NSRange(location: lineRange.location,
                                    length: min(lineRange.length,
                                                document.textStorage.length - lineRange.location))
            let lineGlyphs = layoutManager.glyphRange(forCharacterRange: safeRange,
                                                      actualCharacterRange: nil)
            var fragment = layoutManager.boundingRect(forGlyphRange: lineGlyphs, in: container)
            // A wrapped line occupies several fragments; the number belongs
            // against the first of them only, as it does in Notepad++.
            if lineGlyphs.length > 0 {
                let first = layoutManager.lineFragmentRect(forGlyphAt: lineGlyphs.location,
                                                           effectiveRange: nil)
                fragment.origin.y = first.origin.y
                fragment.size.height = first.height
            }
            guard fragment.height > 0 else { continue }

            let y = fragment.origin.y + inset.height + originY
            guard y + fragment.height >= rect.minY - 20, y <= rect.maxY + 20 else { continue }

            if showsBookmarks && document.bookmarks.contains(line) {
                let dot = NSRect(x: 2, y: y + (fragment.height - 9) / 2, width: 9, height: 9)
                theme.bookmarkFill.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }

            if showsLineNumbers {
                let label = "\(line + 1)" as NSString
                let attributes = (line == currentLine) ? activeAttributes : normalAttributes
                let size = label.size(withAttributes: attributes)
                let x = foldColumnX - numberPadding - size.width
                label.draw(at: NSPoint(x: x, y: y + (fragment.height - size.height) / 2),
                           withAttributes: attributes)
            }

            if showsFoldMargin {
                drawFoldMarker(line: line, folds: folds, y: y, height: fragment.height)
            }
        }
    }

    /// A box with a minus when open and a plus when closed, plus the vertical
    /// run that shows how far the region reaches.
    private func drawFoldMarker(line: Int, folds: FoldModel, y: CGFloat, height: CGFloat) {
        let centreX = foldColumnX + foldWidth / 2
        let stroke = theme.gutterForeground.withAlphaComponent(0.75)

        if folds.isHeader(line) {
            let collapsed = folds.isCollapsed(line)
            let side: CGFloat = 9
            let box = NSRect(x: centreX - side / 2, y: y + (height - side) / 2,
                             width: side, height: side)
            theme.gutterBackground.setFill()
            box.fill()
            stroke.setStroke()
            NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()

            let glyph = NSBezierPath()
            glyph.move(to: NSPoint(x: box.minX + 2, y: box.midY))
            glyph.line(to: NSPoint(x: box.maxX - 2, y: box.midY))
            if collapsed {
                glyph.move(to: NSPoint(x: box.midX, y: box.minY + 2))
                glyph.line(to: NSPoint(x: box.midX, y: box.maxY - 2))
            }
            glyph.lineWidth = 1
            stroke.setStroke()
            glyph.stroke()

            // An open region continues below the box.
            if !collapsed {
                stroke.withAlphaComponent(0.5).setFill()
                NSRect(x: centreX - 0.5, y: box.maxY, width: 1,
                       height: max(0, y + height - box.maxY)).fill()
            }
        } else if let owner = enclosingOpenRegion(of: line, folds: folds) {
            stroke.withAlphaComponent(0.5).setFill()
            let isLast = folds.regionEnd(for: owner) == line
            NSRect(x: centreX - 0.5, y: y, width: 1,
                   height: isLast ? height / 2 : height).fill()
            // The run finishes with a foot, the way Notepad++ closes a fold.
            if isLast {
                NSRect(x: centreX - 0.5, y: y + height / 2 - 0.5,
                       width: foldWidth / 2 - 1, height: 1).fill()
            }
        }
    }

    /// The innermost expanded region containing `line`, if any.
    private func enclosingOpenRegion(of line: Int, folds: FoldModel) -> Int? {
        var best: Int? = nil
        for header in folds.headers where header < line && !folds.isCollapsed(header) {
            if folds.regionEnd(for: header) >= line {
                if best == nil || header > best! { best = header }
            }
        }
        return best
    }

    // MARK: - Clicking

    /// Clicking the fold column toggles a region; clicking the number or
    /// bookmark column toggles a bookmark, as Notepad++ does.
    override func mouseDown(with event: NSEvent) {
        guard let editor, let document = editor.document,
              let layoutManager = editor.layoutManager,
              let container = editor.textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)

        let inEditor = NSPoint(x: 2,
                               y: point.y - convert(NSPoint.zero, from: editor).y
                                  - editor.textContainerInset.height)
        let glyph = layoutManager.glyphIndex(for: inEditor, in: container)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        let line = document.lineIndex.lineIndex(containing: charIndex)

        if showsFoldMargin && point.x >= foldColumnX {
            editor.toggleFold(atLine: line)
            needsDisplay = true
            return
        }

        if document.bookmarks.contains(line) {
            document.bookmarks.remove(line)
        } else {
            document.bookmarks.insert(line)
        }
        needsDisplay = true
    }
}
