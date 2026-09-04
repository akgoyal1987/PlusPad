import AppKit

/// The icon strip under the menu bar.
///
/// Notepad++ puts its toolbar inside the window rather than in the title bar, in
/// a fixed order with separators between groups, and that layout is reproduced
/// exactly here. The glyphs themselves are SF Symbols: drawing imitations of
/// Notepad++'s Windows bitmaps would look worse on a Retina Mac than the system
/// icons do, and the recognisable part is the grouping and the order.
final class ToolbarView: NSView {

    struct Item {
        var symbol: String
        var tooltip: String
        var action: Selector
        /// Buttons that show a pressed state, e.g. Word Wrap.
        var isToggle = false
        var stateKey: String? = nil
    }

    var theme: Theme = .classic {
        didSet { restyle(); needsDisplay = true }
    }

    static let height: CGFloat = 30
    private let buttonSize: CGFloat = 24
    private let separatorWidth: CGFloat = 9

    /// nil marks a group separator.
    private let layout: [Item?] = [
        Item(symbol: "doc.badge.plus", tooltip: "New (Cmd N)", action: #selector(PlusPadCommands.newDocument(_:))),
        Item(symbol: "folder", tooltip: "Open (Cmd O)", action: #selector(PlusPadCommands.openDocument(_:))),
        Item(symbol: "square.and.arrow.down", tooltip: "Save (Cmd S)", action: #selector(PlusPadCommands.saveDocument(_:))),
        Item(symbol: "square.and.arrow.down.on.square", tooltip: "Save All (Cmd Alt S)", action: #selector(PlusPadCommands.saveAllDocuments(_:))),
        Item(symbol: "xmark.square", tooltip: "Close (Cmd W)", action: #selector(PlusPadCommands.closeCurrentTab(_:))),
        nil,
        Item(symbol: "scissors", tooltip: "Cut (Cmd X)", action: #selector(NSText.cut(_:))),
        Item(symbol: "doc.on.doc", tooltip: "Copy (Cmd C)", action: #selector(NSText.copy(_:))),
        Item(symbol: "clipboard", tooltip: "Paste (Cmd V)", action: #selector(NSText.paste(_:))),
        nil,
        Item(symbol: "arrow.uturn.backward", tooltip: "Undo (Cmd Z)", action: Selector(("undo:"))),
        Item(symbol: "arrow.uturn.forward", tooltip: "Redo (Cmd Shift Z)", action: Selector(("redo:"))),
        nil,
        Item(symbol: "magnifyingglass", tooltip: "Find (Cmd F)", action: #selector(PlusPadCommands.showFind(_:))),
        Item(symbol: "arrow.2.squarepath", tooltip: "Replace (Cmd H)", action: #selector(PlusPadCommands.showReplace(_:))),
        nil,
        Item(symbol: "plus.magnifyingglass", tooltip: "Zoom In (Cmd +)", action: #selector(PlusPadCommands.zoomIn(_:))),
        Item(symbol: "minus.magnifyingglass", tooltip: "Zoom Out (Cmd -)", action: #selector(PlusPadCommands.zoomOut(_:))),
        nil,
        Item(symbol: "arrow.turn.down.left", tooltip: "Word Wrap", action: #selector(PlusPadCommands.toggleWordWrap(_:)),
             isToggle: true, stateKey: "wordWrap"),
        Item(symbol: "paragraphsign", tooltip: "Show All Characters", action: #selector(PlusPadCommands.toggleInvisibles(_:)),
             isToggle: true, stateKey: "showInvisibles"),
        Item(symbol: "list.bullet.indent", tooltip: "Show Indent Guide", action: #selector(PlusPadCommands.toggleIndentGuides(_:)),
             isToggle: true, stateKey: "showIndentGuides"),
        nil,
        Item(symbol: "bookmark", tooltip: "Toggle Bookmark (Cmd F2)", action: #selector(PlusPadCommands.toggleBookmark(_:))),
        Item(symbol: "folder.badge.gearshape", tooltip: "Reveal Workspace Folder", action: #selector(PlusPadCommands.revealWorkspace(_:))),
    ]

    private var buttons: [NSButton] = []
    private var toggleKeys: [ObjectIdentifier: String] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        var x: CGFloat = 5
        for entry in layout {
            guard let item = entry else {
                x += separatorWidth
                continue
            }
            let button = NSButton(frame: NSRect(x: x, y: (ToolbarView.height - buttonSize) / 2,
                                                width: buttonSize, height: buttonSize))
            button.bezelStyle = .smallSquare
            button.isBordered = false
            button.imagePosition = .imageOnly
            // A symbol name that does not exist on this OS returns nil, and the
            // button then renders as an empty gap that looks like a layout bug
            // rather than a missing icon. Fall back to something visible.
            let image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tooltip)
                ?? NSImage(systemSymbolName: "questionmark.square.dashed",
                           accessibilityDescription: item.tooltip)
            image?.isTemplate = true
            button.image = image
            button.toolTip = item.tooltip
            button.action = item.action
            // A nil target sends the action up the responder chain, which is
            // what lets one strip drive commands that live on the window, the
            // text view and the app delegate without knowing which is which.
            button.target = nil
            button.setButtonType(.momentaryChange)
            if let key = item.stateKey {
                toggleKeys[ObjectIdentifier(button)] = key
            }
            addSubview(button)
            buttons.append(button)
            x += buttonSize + 2
        }
        restyle()
    }

    private func restyle() {
        for button in buttons {
            button.contentTintColor = theme.isDark ? NSColor.white.withAlphaComponent(0.85)
                                                   : NSColor.black.withAlphaComponent(0.75)
        }
    }

    /// Reflect the current settings on the toggle buttons.
    func syncToggles(with settings: Settings) {
        for button in buttons {
            guard let key = toggleKeys[ObjectIdentifier(button)] else { continue }
            let on: Bool
            switch key {
            case "wordWrap": on = settings.wordWrap
            case "showInvisibles": on = settings.showInvisibles
            case "showIndentGuides": on = settings.showIndentGuides
            default: on = false
            }
            button.contentTintColor = on
                ? theme.tabActiveAccent
                : (theme.isDark ? NSColor.white.withAlphaComponent(0.85)
                                : NSColor.black.withAlphaComponent(0.75))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.chromeBackground.setFill()
        // `dirtyRect` is the window's dirty region expressed in this view's
        // coordinates, so it routinely extends well past the view. Filling it
        // directly paints over every sibling, because NSView.clipsToBounds
        // defaults to false on macOS 14 and later.
        bounds.intersection(dirtyRect).fill()
        theme.chromeBorder.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { true }
}

/// The commands the toolbar, menus and keyboard all send. Declared as a protocol
/// on `NSObject` so `NSButton` can target the responder chain rather than a
/// specific object, and so the selectors exist at compile time.
@objc protocol PlusPadCommands {
    func newDocument(_ sender: Any?)
    func openDocument(_ sender: Any?)
    func saveDocument(_ sender: Any?)
    func saveDocumentAs(_ sender: Any?)
    func saveAllDocuments(_ sender: Any?)
    func closeCurrentTab(_ sender: Any?)
    func reopenClosedTab(_ sender: Any?)
    func showFind(_ sender: Any?)
    func showReplace(_ sender: Any?)
    func showFindInFiles(_ sender: Any?)
    func findNext(_ sender: Any?)
    func findPrevious(_ sender: Any?)
    func goToLine(_ sender: Any?)
    func zoomIn(_ sender: Any?)
    func zoomOut(_ sender: Any?)
    func zoomReset(_ sender: Any?)
    func toggleWordWrap(_ sender: Any?)
    func toggleInvisibles(_ sender: Any?)
    func toggleIndentGuides(_ sender: Any?)
    func toggleLineNumbers(_ sender: Any?)
    func toggleBookmark(_ sender: Any?)
    func nextBookmark(_ sender: Any?)
    func previousBookmark(_ sender: Any?)
    func clearBookmarks(_ sender: Any?)
    func revealWorkspace(_ sender: Any?)
    func chooseWorkspace(_ sender: Any?)
}
