import AppKit

/// One document's editing surface: scroll view, text view and gutter.
///
/// Created lazily. A session with sixty restored tabs builds sixty documents but
/// only the panes for tabs the user actually visits, so relaunch stays fast and
/// memory tracks what is being looked at rather than what was left open.
final class EditorPane: NSView {

    let document: TextDocument
    let scrollView = NSScrollView()
    let textView: EditorTextView
    private(set) var gutter: GutterView!

    weak var paneDelegate: EditorTextViewDelegate? {
        didSet { textView.editorDelegate = paneDelegate }
    }

    private var settings: Settings
    private var theme: Theme

    init(document: TextDocument, settings: Settings, theme: Theme) {
        self.document = document
        self.settings = settings
        self.theme = theme
        self.textView = EditorTextView(document: document, settings: settings, theme: theme)
        super.init(frame: .zero)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !settings.wordWrap
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        gutter = GutterView(scrollView: scrollView, editor: textView)
        gutter.theme = theme
        gutter.font = settings.editorFont
        gutter.showsLineNumbers = settings.showLineNumbers
        gutter.showsBookmarks = settings.showBookmarkMargin
        gutter.showsFoldMargin = settings.showFoldMargin
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = settings.showLineNumbers || settings.showBookmarkMargin
            || settings.showFoldMargin

        // Re-highlight and redraw the gutter as the view scrolls; both only ever
        // consider what is actually on screen.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewScrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        // Nothing to do for wrapping: `widthTracksTextView` keeps the container
        // matched to the text view, which AppKit has already sized to the clip
        // view minus the ruler.
    }

    @objc private func viewScrolled() {
        textView.setNeedsHighlight()
        gutter.needsDisplay = true
        document.scrollOffset = scrollView.contentView.bounds.origin.y
    }

    func apply(settings newSettings: Settings, theme newTheme: Theme) {
        settings = newSettings
        theme = newTheme
        textView.settings = newSettings
        textView.theme = newTheme
        scrollView.backgroundColor = newTheme.background
        scrollView.hasHorizontalScroller = !newSettings.wordWrap
        gutter.theme = newTheme
        gutter.font = newSettings.editorFont
        gutter.showsLineNumbers = newSettings.showLineNumbers
        gutter.showsBookmarks = newSettings.showBookmarkMargin
        gutter.showsFoldMargin = newSettings.showFoldMargin
        textView.recomputeFolds()
        scrollView.rulersVisible = newSettings.showLineNumbers || newSettings.showBookmarkMargin
            || newSettings.showFoldMargin
        gutter.recalculateWidth()
        needsLayout = true
        textView.setNeedsHighlight()
    }

    /// Where the clip view sits when the document is scrolled fully to its
    /// top-left corner.
    ///
    /// It is **not** the origin. `NSScrollView` pays for the ruler, the content
    /// insets and the window's safe area out of the clip view's bounds origin,
    /// so with the gutter showing, "unscrolled" is around `(-65.5, -24)`.
    /// Scrolling to a literal `(0, y)` therefore slides the text 65pt to the
    /// right, out from under the gutter and off the left edge of the window --
    /// which is what every Find Next used to do, because the code that centres
    /// a hit vertically passed `x: 0` for the horizontal position it did not
    /// mean to change.
    ///
    /// The clip view is asked rather than the value being reassembled from
    /// `contentInsets`: only part of the offset is there (the ruler's 65.5pt),
    /// the vertical 24pt is not, and `constrainBoundsRect` is the same call
    /// AppKit uses to clamp a scroll, so it is right by construction.
    private var restingScrollOrigin: NSPoint {
        let clip = scrollView.contentView
        let far = NSRect(origin: NSPoint(x: -1_000_000, y: -1_000_000), size: clip.bounds.size)
        return clip.constrainBoundsRect(far).origin
    }

    /// Scroll vertically, leaving the horizontal position exactly as it was.
    private func scrollVertically(to y: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Restore the cursor and scroll position recorded in the document.
    func restoreViewState() {
        let length = document.textStorage.length
        let location = min(document.selectedRange.location, length)
        let extent = min(document.selectedRange.length, length - location)
        textView.setSelectedRange(NSRange(location: location, length: extent))

        // Layout has to have happened before a scroll offset means anything, so
        // this is deferred one turn rather than applied inline.
        let offset = document.scrollOffset
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if offset > self.restingScrollOrigin.y {
                self.scrollVertically(to: offset)
            } else {
                self.textView.scrollRangeToVisible(self.textView.selectedRange())
            }
            self.textView.setNeedsHighlight()
            self.gutter.needsDisplay = true
        }
    }

    func captureViewState() {
        document.selectedRange = textView.selectedRange()
        document.scrollOffset = scrollView.contentView.bounds.origin.y
    }

    /// Scroll a character range into view and select it.
    func reveal(_ range: NSRange, select: Bool = true) {
        // Expand anything hiding the target first, or the scroll lands on a
        // zero-height fragment and nothing appears to happen.
        textView.revealLine(document.lineIndex.lineIndex(containing: min(range.location,
                                                                        max(0, document.textStorage.length - 1))))
        let length = document.textStorage.length
        let clamped = NSRange(location: min(range.location, length),
                              length: min(range.length, max(0, length - min(range.location, length))))
        if select { textView.setSelectedRange(clamped) }
        textView.scrollRangeToVisible(clamped)
        // Centring the hit vertically keeps successive Find Next results in a
        // stable place instead of pinning each one to the bottom edge.
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            let glyphs = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            let visible = scrollView.contentView.bounds
            if rect.height < visible.height {
                scrollVertically(to: max(restingScrollOrigin.y, rect.midY - visible.height / 2))
            }
        }
        textView.setNeedsHighlight()
        gutter.needsDisplay = true
    }
}
