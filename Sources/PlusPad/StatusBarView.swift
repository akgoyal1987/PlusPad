import AppKit

protocol StatusBarViewDelegate: AnyObject {
    func statusBar(_ bar: StatusBarView, didClickSegment segment: StatusBarView.Segment, at point: NSPoint)
}

/// The bottom strip, laid out in the same segments and the same order as
/// Notepad++'s: language, document size, caret position, line ending, encoding,
/// and insert/overwrite mode.
///
/// The last four segments are clickable and open the same menu the menu bar
/// offers, because reaching for the status bar is how most people change an
/// encoding or a line ending in Notepad++.
final class StatusBarView: NSView {

    enum Segment: Int, CaseIterable {
        case language, size, position, lineEnding, encoding, insertMode

        var isClickable: Bool {
            switch self {
            case .language, .lineEnding, .encoding, .insertMode: return true
            case .size, .position: return false
            }
        }
    }

    weak var delegate: StatusBarViewDelegate?
    var theme: Theme = .classic { didSet { needsDisplay = true } }

    static let height: CGFloat = 22

    private var values: [Segment: String] = [:]
    private var segmentRects: [Segment: NSRect] = [:]
    private var hovered: Segment?

    /// Proportional widths. The caret segment gets the most room because it is
    /// the one that changes constantly and must not make its neighbours jump.
    private let weights: [Segment: CGFloat] = [
        .language: 0.15, .size: 0.22, .position: 0.26,
        .lineEnding: 0.17, .encoding: 0.14, .insertMode: 0.06,
    ]

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        for segment in Segment.allCases { values[segment] = "" }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(language: String, characters: Int, lines: Int,
                line: Int, column: Int, selectionLength: Int, selectionLines: Int,
                lineEnding: LineEnding, encoding: FileEncoding, overwrite: Bool) {
        values[.language] = language
        values[.size] = "length : \(characters)    lines : \(lines)"
        values[.position] = "Ln : \(line)    Col : \(column)    Sel : \(selectionLength) | \(selectionLines)"
        values[.lineEnding] = lineEnding.displayName
        values[.encoding] = encoding.displayName
        values[.insertMode] = overwrite ? "OVR" : "INS"
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        segmentRects = [:]
        let total = bounds.width
        for segment in Segment.allCases {
            let width = (weights[segment] ?? 0.1) * total
            segmentRects[segment] = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.statusBackground.setFill()
        bounds.intersection(dirtyRect).fill()

        theme.chromeBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: theme.statusText,
        ]

        for segment in Segment.allCases {
            guard let rect = segmentRects[segment] else { continue }

            if hovered == segment && segment.isClickable {
                theme.chromeBorder.withAlphaComponent(0.35).setFill()
                rect.insetBy(dx: 1, dy: 2).fill()
            }

            if segment != Segment.allCases.last {
                theme.chromeBorder.setFill()
                NSRect(x: rect.maxX - 1, y: 4, width: 1, height: rect.height - 8).fill()
            }

            let text = (values[segment] ?? "") as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(in: NSRect(x: rect.minX + 7, y: (rect.height - size.height) / 2 + 1,
                                 width: max(0, rect.width - 12), height: size.height),
                      withAttributes: attributes)
        }
    }

    private func segment(at point: NSPoint) -> Segment? {
        segmentRects.first { $0.value.contains(point) }?.key
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let segment = segment(at: point), segment.isClickable else { return }
        delegate?.statusBar(self, didClickSegment: segment, at: point)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let found = segment(at: point)
        if found != hovered {
            hovered = found
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
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
