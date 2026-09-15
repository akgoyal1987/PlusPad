import AppKit

protocol MarkdownPreviewDelegate: AnyObject {
    /// A link was clicked. Local text files open as tabs; everything else is
    /// handed to the system.
    func preview(_ preview: MarkdownPreviewPane, didActivate url: URL)
}

/// The rendered half of a Markdown document, shown beside the editor.
///
/// It is an ordinary read-only text view rather than a web view. A web view
/// would render more of the format for less code, and would also run whatever
/// script a file cared to embed, fetch whatever it referenced, and bring a
/// second rendering engine that has to be kept in step with the first. This
/// shows the document and nothing else -- see MarkdownRenderer.
final class MarkdownPreviewPane: NSView {

    weak var delegate: MarkdownPreviewDelegate?

    private let scrollView = NSScrollView()
    private let textView = PreviewTextView()
    private var refreshTimer: Timer?
    private weak var document: TextDocument?
    private var settings: Settings
    private var theme: Theme

    /// Rendering a long document on every keystroke would make typing feel
    /// heavy, and nobody reads the preview mid-word. One pass shortly after the
    /// typing stops is enough, and is what every editor with a preview does.
    private static let refreshDelay: TimeInterval = 0.25

    init(settings: Settings, theme: Theme) {
        self.settings = settings
        self.theme = theme
        super.init(frame: .zero)
        clipsToBounds = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.linkTextAttributes = [:]
        textView.delegate = self
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.background.setFill()
        // Never fill dirtyRect: it is the window's dirty region in this view's
        // coordinates and is routinely larger than the view.
        bounds.intersection(dirtyRect).fill()
    }

    // MARK: - Content

    func show(_ document: TextDocument?) {
        self.document = document
        refreshNow()
    }

    /// Called as the user types. Coalesced, so a burst of keystrokes costs one
    /// render.
    func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshDelay,
                                            repeats: false) { [weak self] _ in
            self?.refreshNow()
        }
    }

    func refreshNow() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard let document else {
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            return
        }

        // Hold the scroll position across a re-render, or the preview jumps to
        // the top on every pause in typing, which makes it unusable for exactly
        // the document it is meant to help with: a long one.
        let clip = scrollView.contentView
        let previousHeight = textView.bounds.height
        let previousOffset = clip.bounds.origin.y

        let options = MarkdownRenderer.Options(
            theme: theme,
            editorFont: settings.editorFont,
            baseURL: document.fileURL?.deletingLastPathComponent())
        let rendered = MarkdownRenderer.render(document.textStorage.string, options: options)
        textView.textStorage?.setAttributedString(rendered)
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }

        let newHeight = textView.bounds.height
        guard previousHeight > 1, newHeight > 1, previousOffset > 0 else { return }
        let scaled = previousOffset * (newHeight / previousHeight)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x,
                                y: min(scaled, max(0, newHeight - clip.bounds.height))))
        scrollView.reflectScrolledClipView(clip)
    }

    func applySettings(_ settings: Settings) {
        self.settings = settings
        applyTheme(settings.theme)
        refreshNow()
    }

    private func applyTheme(_ theme: Theme) {
        self.theme = theme
        textView.quoteBarColor = theme.color(.keyword)
        scrollView.backgroundColor = theme.background
        textView.backgroundColor = theme.background
        needsDisplay = true
    }

    /// Scroll the preview to roughly where the editor is. Proportional rather
    /// than line-mapped: a rendered heading and its source line are different
    /// heights, so an exact mapping would need the renderer to record where
    /// every source line ended up. Proportional is what people expect from a
    /// preview and costs nothing.
    func syncScroll(toFractionOf editor: NSScrollView) {
        let source = editor.contentView
        let sourceHeight = max(1, editor.documentView?.bounds.height ?? 1)
        let visible = source.bounds.height
        guard sourceHeight > visible else { return }
        let resting = restingOrigin(of: source).y
        let fraction = max(0, min(1, (source.bounds.origin.y - resting) / (sourceHeight - visible)))

        let clip = scrollView.contentView
        let height = textView.bounds.height
        guard height > clip.bounds.height else { return }
        let target = fraction * (height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Where a clip view sits when scrolled fully to its top. It is not zero:
    /// the ruler and content insets are paid for out of the bounds origin.
    private func restingOrigin(of clip: NSClipView) -> NSPoint {
        let far = NSRect(origin: NSPoint(x: -1_000_000, y: -1_000_000), size: clip.bounds.size)
        return clip.constrainBoundsRect(far).origin
    }
}

extension MarkdownPreviewPane: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any,
                  at charIndex: Int) -> Bool {
        let url: URL?
        switch link {
        case let value as URL: url = value
        case let value as String: url = URL(string: value)
        default: url = nil
        }
        guard let url else { return false }
        delegate?.preview(self, didActivate: url)
        return true
    }
}

/// Draws the bar beside a blockquote. The renderer marks the runs; only the
/// text view knows where they were laid out.
private final class PreviewTextView: NSTextView {
    var quoteBarColor: NSColor = .systemGray

    override func draw(_ dirtyRect: NSRect) {
        drawQuoteBars(clippedTo: dirtyRect)
        super.draw(dirtyRect)
    }

    private func drawQuoteBars(clippedTo dirtyRect: NSRect) {
        guard let layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return }
        let inset = textContainerInset
        quoteBarColor.withAlphaComponent(0.5).setFill()

        storage.enumerateAttribute(.markdownQuoteBar,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, _, _ in
                // Geometry from `bounds` and the layout manager, never from
                // dirtyRect, which extends well past this view.
                let bar = NSRect(x: inset.width + 6, y: usedRect.minY + inset.height,
                                 width: 3, height: usedRect.height)
                if bar.intersects(dirtyRect) { bar.fill() }
            }
        }
    }
}
