import AppKit

protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelect index: Int)
    func tabBar(_ bar: TabBarView, didRequestClose index: Int)
    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int)
    func tabBar(_ bar: TabBarView, didRequestContextMenuFor index: Int, at point: NSPoint)
    func tabBarDidRequestNewDocument(_ bar: TabBarView)
}

/// One tab's worth of what the bar needs to draw.
struct TabItem {
    var title: String
    var tooltip: String
    var isDirty: Bool
    var isReadOnly: Bool
}

/// The document tab strip, drawn to match Notepad++ rather than the Mac.
///
/// The details that make it read as Notepad++: a grey strip with white for the
/// active tab, a coloured accent bar along the top edge of the active tab, and a
/// small disk glyph per tab that is blue when saved and red when not. The red
/// disk is the app's primary unsaved-work signal, and deliberately the only one
/// -- there is never a dialog.
///
/// Overflow follows Notepad++ too: tabs keep their width and the strip scrolls,
/// with a pair of arrow buttons appearing at the right end. Tabs are never
/// shrunk to fit, because a row of twenty tabs reading "ma...", "RE...",
/// "co..." identifies nothing.
final class TabBarView: NSView {

    weak var delegate: TabBarViewDelegate?

    var theme: Theme = .classic { didSet { needsDisplay = true } }
    var showsCloseButtons = true { didSet { relayout() } }

    private(set) var items: [TabItem] = []
    private(set) var selectedIndex = 0

    private var tabRects: [NSRect] = []
    private var newTabRect: NSRect = .zero
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    private var hoverClose = false { didSet { needsDisplay = true } }
    private var hoverNewTab = false { didSet { needsDisplay = true } }
    private var hoverArrow: Int? { didSet { needsDisplay = true } }
    private var scrollOffset: CGFloat = 0
    private var toolTipTags: [NSView.ToolTipTag: Int] = [:]

    private var dragIndex: Int?
    private var dragOrigin: NSPoint = .zero
    private var dragOffset: CGFloat = 0
    private var isDragging = false

    static let height: CGFloat = 26
    private let minTabWidth: CGFloat = 104
    private let maxTabWidth: CGFloat = 240
    private let closeSize: CGFloat = 13
    private let diskSize: CGFloat = 9
    private let newTabWidth: CGFloat = 26
    private let arrowWidth: CGFloat = 20

    private var labelFont: NSFont { NSFont.systemFont(ofSize: 11) }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setItems(_ newItems: [TabItem], selected: Int) {
        items = newItems
        selectedIndex = max(0, min(selected, newItems.count - 1))
        relayout()
        scrollSelectedIntoView()
    }

    // MARK: - Layout

    /// Total width of tabs plus the new-tab button, ignoring scrolling.
    private var contentWidth: CGFloat {
        var total: CGFloat = 0
        for item in items { total += width(for: item) }
        return total + newTabWidth
    }

    private func width(for item: TabItem) -> CGFloat {
        let textWidth = (item.title as NSString).size(withAttributes: [.font: labelFont]).width
        var width = textWidth + diskSize + 20
        if showsCloseButtons { width += closeSize + 4 }
        return min(max(width, minTabWidth), maxTabWidth)
    }

    /// True when the strip cannot show everything at once.
    private var isOverflowing: Bool { contentWidth > bounds.width }

    /// Width available to tabs, less the arrow buttons when they are showing.
    private var trackWidth: CGFloat {
        isOverflowing ? max(0, bounds.width - arrowWidth * 2) : bounds.width
    }

    private var maxScroll: CGFloat { max(0, contentWidth - trackWidth) }

    private func relayout() {
        scrollOffset = max(0, min(scrollOffset, maxScroll))
        tabRects = []
        var x = -scrollOffset
        for item in items {
            let w = width(for: item)
            tabRects.append(NSRect(x: x, y: 0, width: w, height: bounds.height))
            x += w
        }
        // The new-tab button sits immediately after the last tab and scrolls
        // with them, rather than being pinned to the far right where it reads as
        // unrelated to the strip.
        newTabRect = NSRect(x: x, y: 0, width: newTabWidth, height: bounds.height)
        rebuildToolTips()
        needsDisplay = true
    }

    private func scrollSelectedIntoView() {
        guard isOverflowing, tabRects.indices.contains(selectedIndex) else { return }
        let rect = tabRects[selectedIndex]
        if rect.minX < 0 {
            scrollOffset += rect.minX
        } else if rect.maxX > trackWidth {
            scrollOffset += rect.maxX - trackWidth
        }
        scrollOffset = max(0, min(scrollOffset, maxScroll))
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    private var leftArrowRect: NSRect {
        NSRect(x: bounds.width - arrowWidth * 2, y: 0, width: arrowWidth, height: bounds.height)
    }

    private var rightArrowRect: NSRect {
        NSRect(x: bounds.width - arrowWidth, y: 0, width: arrowWidth, height: bounds.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        theme.chromeBackground.setFill()
        bounds.intersection(dirtyRect).fill()

        // Tabs and the new-tab button are clipped to the track so a scrolled
        // strip cannot paint underneath the arrow buttons.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: trackWidth, height: bounds.height)).setClip()

        for (index, rect) in tabRects.enumerated() where rect.intersects(bounds) {
            guard index != dragIndex || !isDragging else { continue }
            drawTab(items[index], in: rect, index: index)
        }
        if isDragging, let index = dragIndex, tabRects.indices.contains(index) {
            var rect = tabRects[index]
            rect.origin.x += dragOffset
            drawTab(items[index], in: rect, index: index, lifted: true)
        }
        drawNewTabButton()

        NSGraphicsContext.restoreGraphicsState()

        if isOverflowing { drawScrollArrows() }

        theme.chromeBorder.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func drawTab(_ item: TabItem, in rect: NSRect, index: Int, lifted: Bool = false) {
        let isActive = (index == selectedIndex)
        let isHovered = (index == hoverIndex)

        let background: NSColor = isActive ? theme.tabActive
            : (isHovered ? theme.tabInactiveHover : theme.tabInactive)
        background.setFill()
        rect.fill()

        if lifted {
            NSColor.black.withAlphaComponent(0.12).setFill()
            rect.fill()
        }

        // The accent stripe along the top of the active tab is the single most
        // characteristic mark of the Notepad++ tab bar.
        if isActive {
            theme.tabActiveAccent.setFill()
            NSRect(x: rect.minX, y: 0, width: rect.width, height: 2).fill()
        }

        theme.chromeBorder.setFill()
        NSRect(x: rect.maxX - 1, y: 3, width: 1, height: rect.height - 4).fill()

        var textX = rect.minX + 8

        // Blue disk when the buffer matches its file, red when it does not.
        let diskRect = NSRect(x: textX, y: (rect.height - diskSize) / 2, width: diskSize, height: diskSize)
        let diskColor = item.isDirty ? Theme.hex(0xD01B1B) : Theme.hex(0x1E6FD9)
        diskColor.setFill()
        NSBezierPath(roundedRect: diskRect, xRadius: 1.5, yRadius: 1.5).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSRect(x: diskRect.minX + 2, y: diskRect.minY + 1.5, width: diskSize - 4, height: 2.5).fill()
        textX += diskSize + 6

        var textWidth = rect.maxX - textX - 6
        if showsCloseButtons { textWidth -= closeSize + 2 }

        let color = isActive ? theme.tabActiveText : theme.tabText
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: isActive ? NSFont.systemFont(ofSize: 11, weight: .medium) : labelFont,
            // A dirty tab writes its name in red as well as showing a red disk,
            // because the disk alone is easy to miss in a full row of tabs.
            .foregroundColor: item.isDirty ? Theme.hex(0xB01414) : color,
            .paragraphStyle: style,
        ]
        let title = item.isReadOnly ? item.title + " [RO]" : item.title
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(in: NSRect(x: textX, y: (rect.height - size.height) / 2,
                                            width: max(0, textWidth), height: size.height),
                                 withAttributes: attributes)

        if showsCloseButtons && (isActive || isHovered) {
            let closeRect = closeButtonRect(for: rect)
            if isHovered && hoverClose {
                Theme.hex(0xC75050).setFill()
                NSBezierPath(roundedRect: closeRect, xRadius: 2, yRadius: 2).fill()
            }
            let cross = NSBezierPath()
            let box = closeRect.insetBy(dx: 3.5, dy: 3.5)
            cross.move(to: NSPoint(x: box.minX, y: box.minY))
            cross.line(to: NSPoint(x: box.maxX, y: box.maxY))
            cross.move(to: NSPoint(x: box.maxX, y: box.minY))
            cross.line(to: NSPoint(x: box.minX, y: box.maxY))
            cross.lineWidth = 1.3
            ((isHovered && hoverClose) ? NSColor.white : color.withAlphaComponent(0.75)).setStroke()
            cross.stroke()
        }
    }

    private func closeButtonRect(for tab: NSRect) -> NSRect {
        NSRect(x: tab.maxX - closeSize - 5, y: (tab.height - closeSize) / 2,
               width: closeSize, height: closeSize)
    }

    private func drawNewTabButton() {
        guard newTabRect.intersects(bounds) else { return }
        if hoverNewTab {
            theme.tabInactiveHover.setFill()
            newTabRect.insetBy(dx: 2, dy: 3).fill()
        }
        let plus = NSBezierPath()
        let centre = NSPoint(x: newTabRect.midX, y: newTabRect.midY)
        plus.move(to: NSPoint(x: centre.x - 4, y: centre.y))
        plus.line(to: NSPoint(x: centre.x + 4, y: centre.y))
        plus.move(to: NSPoint(x: centre.x, y: centre.y - 4))
        plus.line(to: NSPoint(x: centre.x, y: centre.y + 4))
        plus.lineWidth = 1.4
        theme.tabText.setStroke()
        plus.stroke()
    }

    /// Left and right chevrons at the far right, the way Notepad++ shows them
    /// once the strip no longer fits. Each dims when it has nowhere to go.
    private func drawScrollArrows() {
        for (index, rect) in [(0, leftArrowRect), (1, rightArrowRect)] {
            theme.chromeBackground.setFill()
            rect.fill()
            theme.chromeBorder.setFill()
            NSRect(x: rect.minX, y: 3, width: 1, height: rect.height - 4).fill()

            if hoverArrow == index {
                theme.tabInactiveHover.setFill()
                rect.insetBy(dx: 2, dy: 3).fill()
            }

            let enabled = (index == 0) ? scrollOffset > 0.5 : scrollOffset < maxScroll - 0.5
            let chevron = NSBezierPath()
            let centre = NSPoint(x: rect.midX, y: rect.midY)
            let reach: CGFloat = 3.5
            if index == 0 {
                chevron.move(to: NSPoint(x: centre.x + reach / 1.5, y: centre.y - reach * 1.4))
                chevron.line(to: NSPoint(x: centre.x - reach / 1.5, y: centre.y))
                chevron.line(to: NSPoint(x: centre.x + reach / 1.5, y: centre.y + reach * 1.4))
            } else {
                chevron.move(to: NSPoint(x: centre.x - reach / 1.5, y: centre.y - reach * 1.4))
                chevron.line(to: NSPoint(x: centre.x + reach / 1.5, y: centre.y))
                chevron.line(to: NSPoint(x: centre.x - reach / 1.5, y: centre.y + reach * 1.4))
            }
            chevron.lineWidth = 1.6
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            theme.tabText.withAlphaComponent(enabled ? 0.9 : 0.25).setStroke()
            chevron.stroke()
        }
    }

    // MARK: - Scrolling

    /// Step by roughly one tab, so a click moves a useful, predictable amount.
    private func scrollBy(_ amount: CGFloat) {
        guard isOverflowing else { return }
        scrollOffset = max(0, min(scrollOffset + amount, maxScroll))
        relayout()
    }

    func scrollToStart() { scrollOffset = 0; relayout() }

    override func scrollWheel(with event: NSEvent) {
        guard isOverflowing else { return }
        // Trackpads report horizontal travel; a mouse wheel only reports
        // vertical, so both are accepted and mapped onto the same axis.
        let travel = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollBy(-travel)
    }

    // MARK: - Hit testing

    private func tabIndex(at point: NSPoint) -> Int? {
        guard point.x < trackWidth else { return nil }
        return tabRects.firstIndex { $0.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isOverflowing, leftArrowRect.contains(point) { hoverArrow = 0 }
        else if isOverflowing, rightArrowRect.contains(point) { hoverArrow = 1 }
        else { hoverArrow = nil }

        hoverNewTab = point.x < trackWidth && newTabRect.contains(point)
        hoverIndex = tabIndex(at: point)
        hoverClose = hoverIndex.map {
            showsCloseButtons && closeButtonRect(for: tabRects[$0]).contains(point)
        } ?? false
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        hoverClose = false
        hoverNewTab = false
        hoverArrow = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isOverflowing, leftArrowRect.contains(point) {
            scrollBy(-(tabRects.first?.width ?? minTabWidth))
            return
        }
        if isOverflowing, rightArrowRect.contains(point) {
            scrollBy(tabRects.first?.width ?? minTabWidth)
            return
        }
        if point.x < trackWidth, newTabRect.contains(point) {
            delegate?.tabBarDidRequestNewDocument(self)
            return
        }

        guard let index = tabIndex(at: point) else {
            // Notepad++ opens a new document when the empty part of the strip is
            // double-clicked.
            if event.clickCount == 2 { delegate?.tabBarDidRequestNewDocument(self) }
            return
        }

        if showsCloseButtons, closeButtonRect(for: tabRects[index]).contains(point) {
            delegate?.tabBar(self, didRequestClose: index)
            return
        }

        // Selecting before dragging means a plain click is instant and a drag
        // starts from the tab the user already sees highlighted.
        if index != selectedIndex {
            delegate?.tabBar(self, didSelect: index)
        }
        dragIndex = index
        dragOrigin = point
        dragOffset = 0
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = dragIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        let travel = point.x - dragOrigin.x
        if !isDragging && abs(travel) < 5 { return }
        isDragging = true
        dragOffset = travel

        // Swap as soon as the dragged tab's centre passes a neighbour's centre,
        // so the row reorders live under the cursor.
        let centre = tabRects[index].midX + travel
        if index > 0, centre < tabRects[index - 1].midX {
            delegate?.tabBar(self, didMove: index, to: index - 1)
            dragIndex = index - 1
            dragOrigin.x -= tabRects[index - 1].width
        } else if index < tabRects.count - 1, centre > tabRects[index + 1].midX {
            delegate?.tabBar(self, didMove: index, to: index + 1)
            dragIndex = index + 1
            dragOrigin.x += tabRects[index + 1].width
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragIndex = nil
        isDragging = false
        dragOffset = 0
        needsDisplay = true
    }

    /// Middle-click closes a tab, as it does in Notepad++ and every browser.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let index = tabIndex(at: point) {
            delegate?.tabBar(self, didRequestClose: index)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tabIndex(at: point) else { return }
        delegate?.tabBar(self, didRequestContextMenuFor: index, at: point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }
}

/// Tooltips carry the full path, which is the only place a tab shows where its
/// file actually lives once the name has been truncated to fit.
extension TabBarView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let index = toolTipTags[tag], items.indices.contains(index) else { return "" }
        return items[index].tooltip
    }

    fileprivate func rebuildToolTips() {
        removeAllToolTips()
        toolTipTags.removeAll()
        let track = NSRect(x: 0, y: 0, width: trackWidth, height: bounds.height)
        for (index, rect) in tabRects.enumerated() {
            let visible = rect.intersection(track)
            guard visible.width > 4 else { continue }
            toolTipTags[addToolTip(visible, owner: self, userData: nil)] = index
        }
    }
}
