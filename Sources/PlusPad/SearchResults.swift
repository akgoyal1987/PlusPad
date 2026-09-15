import AppKit

// MARK: - Model

/// One matching line, and enough to get back to it.
///
/// The hit carries its character range rather than just a line number, so
/// clicking it selects the match itself and not the whole line. A hit in a file
/// that is not open carries the URL instead of a document id, which is how a
/// Find in Files result stays clickable.
struct SearchResultHit {
    var documentID: UUID?
    var fileURL: URL?
    /// Zero-based.
    var line: Int
    /// The match, in the document's text.
    var range: NSRange
    var lineText: String
    /// The match, within `lineText`, for highlighting the row.
    var matchInLine: NSRange
}

struct SearchResultGroup {
    var title: String
    var documentID: UUID?
    var fileURL: URL?
    var hits: [SearchResultHit]
    /// Hits beyond the per-file cap, reported rather than silently dropped.
    var truncated: Int = 0
}

struct SearchResults {
    /// The line Notepad++ puts at the top: Search "x" (12 hits in 3 files).
    var summary: String
    var groups: [SearchResultGroup]
    var totalHits: Int

    /// At most this many hits are listed per file. A regex like `.` against a
    /// large file matches every character, and an outline view holding a
    /// hundred thousand rows of that is not a search result, it is a hang.
    static let hitsPerFileCap = 500

    static func build(term: String, groups: [SearchResultGroup]) -> SearchResults {
        let total = groups.reduce(0) { $0 + $1.hits.count + $1.truncated }
        let files = groups.count
        var summary = "Search \"\(term)\" (\(total) hit\(total == 1 ? "" : "s")"
        summary += files == 1 && groups.first?.fileURL == nil && groups.first?.documentID != nil
            ? " in \(groups.first?.title ?? "document"))"
            : " in \(files) file\(files == 1 ? "" : "s"))"
        return SearchResults(summary: summary, groups: groups, totalHits: total)
    }
}

// MARK: - Panel

protocol SearchResultsPanelDelegate: AnyObject {
    func searchResults(_ panel: SearchResultsPanel, didChoose hit: SearchResultHit)
    func searchResultsDidRequestClose(_ panel: SearchResultsPanel)
    func searchResults(_ panel: SearchResultsPanel, didResizeTo height: CGFloat)
}

/// The Find result panel, docked along the bottom of the window.
///
/// Notepad++ puts search results in a dock rather than a document, and it is
/// the right call: results are not a file. They cannot be edited, they should
/// not be saveable, they must not sit in the tab bar competing with real work,
/// and above all every line in them is a place to go rather than text to read.
/// PlusPad used to open them as an untitled tab, which got all four wrong.
final class SearchResultsPanel: NSView {

    weak var delegate: SearchResultsPanelDelegate?

    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let scrollView = NSScrollView()
    private let outline = NSOutlineView()
    private var results = SearchResults(summary: "", groups: [], totalHits: 0)
    private var nodes: [GroupNode] = []
    private var theme: Theme
    private var font: NSFont

    static let headerHeight: CGFloat = 24
    /// The grab strip along the top edge.
    static let gripHeight: CGFloat = 5
    static let minimumHeight: CGFloat = 80

    private var dragOrigin: CGFloat?

    override var isFlipped: Bool { true }

    init(theme: Theme, font: NSFont) {
        self.theme = theme
        self.font = font
        super.init(frame: .zero)
        clipsToBounds = true
        buildHeader()
        buildOutline()
        applyTheme(theme, font: font)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildHeader() {
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(titleLabel)

        closeButton.title = "Close"
        closeButton.bezelStyle = .inline
        closeButton.font = NSFont.systemFont(ofSize: 10)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        header.addSubview(closeButton)
        addSubview(header)
    }

    private func buildOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.usesAlternatingRowBackgroundColors = false
        outline.selectionHighlightStyle = .regular
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.autoresizingMask = [.width, .height]

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        addSubview(scrollView)
    }

    // MARK: layout

    override func layout() {
        super.layout()
        let top = Self.gripHeight
        header.frame = NSRect(x: 0, y: top, width: bounds.width, height: Self.headerHeight)
        titleLabel.frame = NSRect(x: 8, y: 4, width: max(0, bounds.width - 90), height: 16)
        closeButton.frame = NSRect(x: bounds.width - 62, y: 3, width: 54, height: 18)
        let listTop = top + Self.headerHeight
        scrollView.frame = NSRect(x: 0, y: listTop, width: bounds.width,
                                  height: max(0, bounds.height - listTop))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Geometry from `bounds`; `dirtyRect` is the window's dirty region in
        // this view's coordinates and is routinely larger than the view.
        theme.chromeBackground.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.gripHeight + Self.headerHeight)
            .intersection(dirtyRect).fill()
        theme.chromeBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).intersection(dirtyRect).fill()
        NSRect(x: 0, y: Self.gripHeight + Self.headerHeight - 1, width: bounds.width, height: 1)
            .intersection(dirtyRect).fill()
    }

    private var gripRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.gripHeight)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(gripRect, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard gripRect.contains(point) else { return super.mouseDown(with: event) }
        dragOrigin = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return super.mouseDragged(with: event) }
        // The panel is anchored to the bottom, so dragging the grip down makes
        // it shorter by exactly the distance moved.
        let delta = origin - event.locationInWindow.y
        delegate?.searchResults(self, didResizeTo: max(Self.minimumHeight, bounds.height - delta))
        dragOrigin = event.locationInWindow.y
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        window?.invalidateCursorRects(for: self)
    }

    // MARK: content

    func show(_ results: SearchResults) {
        self.results = results
        nodes = results.groups.map(GroupNode.init)
        titleLabel.stringValue = results.summary
        outline.reloadData()
        for node in nodes { outline.expandItem(node) }
        if outline.numberOfRows > 0 {
            outline.scrollRowToVisible(0)
        }
    }

    func applyTheme(_ theme: Theme, font: NSFont) {
        self.theme = theme
        self.font = font
        titleLabel.textColor = theme.statusText
        outline.backgroundColor = theme.background
        scrollView.backgroundColor = theme.background
        outline.rowHeight = ceil(font.boundingRectForFont.height) + 4
        outline.reloadData()
        for node in nodes { outline.expandItem(node) }
        needsDisplay = true
    }

    @objc private func closeClicked() { delegate?.searchResultsDidRequestClose(self) }

    /// Notepad++ jumps on a single click, and so does this. A result list whose
    /// rows need a double click is a list you have to learn.
    @objc private func rowClicked() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        if let group = item as? GroupNode {
            outline.isItemExpanded(group) ? outline.collapseItem(group) : outline.expandItem(group)
            return
        }
        guard let hit = item as? HitNode else { return }
        delegate?.searchResults(self, didChoose: hit.hit)
    }

    /// Wrappers because an outline view's items have to be objects.
    private final class GroupNode {
        let group: SearchResultGroup
        let children: [HitNode]
        init(_ group: SearchResultGroup) {
            self.group = group
            self.children = group.hits.map(HitNode.init)
        }
    }

    private final class HitNode {
        let hit: SearchResultHit
        init(_ hit: SearchResultHit) { self.hit = hit }
    }
}

extension SearchResultsPanel: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return nodes.count }
        return (item as? GroupNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let group = item as? GroupNode else { return nodes[index] }
        return group.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? GroupNode).map { !$0.children.isEmpty } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("resultCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let created = NSTableCellView()
                created.identifier = identifier
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.drawsBackground = false
                created.addSubview(field)
                created.textField = field
                return created
            }()

        cell.textField?.attributedStringValue = attributedRow(for: item)
        cell.textField?.frame = NSRect(x: 0, y: 0, width: outlineView.bounds.width, height: outlineView.rowHeight)
        cell.textField?.autoresizingMask = [.width]
        return cell
    }

    private func attributedRow(for item: Any) -> NSAttributedString {
        if let group = item as? GroupNode {
            let count = group.group.hits.count + group.group.truncated
            let text = NSMutableAttributedString(
                string: "\(group.group.title)  (\(count) hit\(count == 1 ? "" : "s"))")
            text.addAttributes([
                .font: NSFont.systemFont(ofSize: font.pointSize - 1, weight: .semibold),
                .foregroundColor: theme.foreground,
            ], range: NSRange(location: 0, length: text.length))
            return text
        }
        guard let node = item as? HitNode else { return NSAttributedString(string: "") }

        let hit = node.hit
        let prefix = "Line \(hit.line + 1): "
        let text = NSMutableAttributedString(string: prefix + hit.lineText)
        text.addAttributes([.font: font, .foregroundColor: theme.foreground],
                           range: NSRange(location: 0, length: text.length))
        text.addAttribute(.foregroundColor, value: theme.color(.comment),
                          range: NSRange(location: 0, length: prefix.count))
        // Mark the match itself, so a long line still shows why it is listed.
        let match = NSRange(location: prefix.count + hit.matchInLine.location,
                            length: hit.matchInLine.length)
        if NSMaxRange(match) <= text.length, match.length > 0 {
            text.addAttributes([
                .backgroundColor: theme.findHighlight,
                .foregroundColor: theme.foreground,
            ], range: match)
        }
        return text
    }
}

// MARK: - Building groups

extension SearchResultGroup {

    /// Turn raw matches in one text into rows that can be clicked back to.
    ///
    /// The line content is trimmed of its newline but not of its indentation:
    /// leading whitespace is often what tells two otherwise identical hits
    /// apart, and the match offset is recorded relative to what is shown so the
    /// highlight lands on the right characters.
    static func make(title: String, documentID: UUID?, fileURL: URL?,
                     matches: [SearchMatch], text: NSString, index: LineIndex) -> SearchResultGroup {
        var hits: [SearchResultHit] = []
        hits.reserveCapacity(min(matches.count, SearchResults.hitsPerFileCap))

        for match in matches.prefix(SearchResults.hitsPerFileCap) {
            let line = index.lineIndex(containing: match.range.location)
            let lineRange = index.range(ofLine: line)
            let safe = NSRange(location: lineRange.location,
                               length: max(0, min(lineRange.length, text.length - lineRange.location)))
            var content = text.substring(with: safe)
            while content.hasSuffix("\n") || content.hasSuffix("\r") { content.removeLast() }
            let offset = max(0, match.range.location - safe.location)
            let within = NSRange(location: min(offset, content.utf16.count),
                                 length: min(match.range.length,
                                             max(0, content.utf16.count - offset)))
            hits.append(SearchResultHit(documentID: documentID, fileURL: fileURL, line: line,
                                        range: match.range, lineText: content, matchInLine: within))
        }
        return SearchResultGroup(title: title, documentID: documentID, fileURL: fileURL,
                                 hits: hits,
                                 truncated: max(0, matches.count - SearchResults.hitsPerFileCap))
    }
}
