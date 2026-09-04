import AppKit

/// Colours for every token kind and every piece of editor chrome.
///
/// The default deliberately reproduces Notepad++'s own "Default" style rather
/// than inventing a Mac-native palette: blue bold keywords, green comments,
/// orange numbers, grey strings, a lavender current line and a grey gutter. That
/// specific combination is what makes a Notepad++ window recognisable across the
/// room, and matching it is the point of the app.
struct Theme {
    var name: String
    var isDark: Bool

    var colors: [TokenKind: NSColor]
    var boldKinds: Set<TokenKind>

    var background: NSColor
    var foreground: NSColor
    var cursor: NSColor
    var selection: NSColor
    var currentLine: NSColor

    var gutterBackground: NSColor
    var gutterForeground: NSColor
    var gutterActiveForeground: NSColor
    var gutterSeparator: NSColor
    var bookmarkFill: NSColor

    var invisibles: NSColor
    var indentGuide: NSColor
    var bracketMatch: NSColor
    var bracketMismatch: NSColor

    var findHighlight: NSColor
    var findCurrent: NSColor
    var markHighlight: NSColor
    var smartHighlight: NSColor

    /// Window chrome, matched to Notepad++'s toolbar and tab strip.
    var chromeBackground: NSColor
    var chromeBorder: NSColor
    var tabInactive: NSColor
    var tabInactiveHover: NSColor
    var tabActive: NSColor
    var tabActiveAccent: NSColor
    var tabText: NSColor
    var tabActiveText: NSColor
    var statusBackground: NSColor
    var statusText: NSColor

    func color(_ kind: TokenKind) -> NSColor { colors[kind] ?? foreground }
    func isBold(_ kind: TokenKind) -> Bool { boldKinds.contains(kind) }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    // MARK: - Built-in themes

    /// Notepad++ "Default" style, colour for colour.
    static let classic = Theme(
        name: "Default (Notepad++)",
        isDark: false,
        colors: [
            .plain:        hex(0x000000),
            .keyword:      hex(0x0000FF),
            .type:         hex(0x8000FF),
            .string:       hex(0x808080),
            .escape:       hex(0x8080C0),
            .comment:      hex(0x008000),
            .docComment:   hex(0x008080),
            .number:       hex(0xFF8000),
            .preprocessor: hex(0x804000),
            .tag:          hex(0x0000FF),
            .attribute:    hex(0xFF0000),
            .function:     hex(0x000080),
            .op:           hex(0x000080),
            .heading:      hex(0x0000A0),
            .link:         hex(0x0000FF),
            .invalid:      hex(0xFF0000),
        ],
        boldKinds: [.keyword, .type, .tag, .heading],

        background:             hex(0xFFFFFF),
        foreground:             hex(0x000000),
        cursor:                 hex(0x000000),
        selection:              hex(0xC0C0C0),
        currentLine:            hex(0xE8E8FF),

        gutterBackground:       hex(0xFFFFFF),
        gutterForeground:       hex(0x808080),
        gutterActiveForeground: hex(0x404040),
        gutterSeparator:        hex(0xD8D8D8),
        bookmarkFill:           hex(0x1E6FD9),

        invisibles:             hex(0xC0C0C0),
        indentGuide:            hex(0xD8D8D8),
        bracketMatch:           hex(0xFF0000),
        bracketMismatch:        hex(0xFF00FF),

        findHighlight:          hex(0xFFFF00),
        findCurrent:            hex(0xFF9632),
        markHighlight:          hex(0x00FFFF),
        smartHighlight:         hex(0x00FF00, alpha: 0.35),

        chromeBackground:       hex(0xF0F0F0),
        chromeBorder:           hex(0xACACAC),
        tabInactive:            hex(0xD6D6D6),
        tabInactiveHover:       hex(0xE6E6E6),
        tabActive:              hex(0xFFFFFF),
        tabActiveAccent:        hex(0xFF8000),
        tabText:                hex(0x303030),
        tabActiveText:          hex(0x000000),
        statusBackground:       hex(0xF0F0F0),
        statusText:             hex(0x202020)
    )

    /// Notepad++'s own dark theme, for people who run it that way. Same
    /// structure, same role for every colour, just inverted ground.
    static let dark = Theme(
        name: "Dark",
        isDark: true,
        colors: [
            .plain:        hex(0xDCDCDC),
            .keyword:      hex(0x569CD6),
            .type:         hex(0x4EC9B0),
            .string:       hex(0xCE9178),
            .escape:       hex(0xD7BA7D),
            .comment:      hex(0x6A9955),
            .docComment:   hex(0x608B4E),
            .number:       hex(0xB5CEA8),
            .preprocessor: hex(0xC586C0),
            .tag:          hex(0x569CD6),
            .attribute:    hex(0x9CDCFE),
            .function:     hex(0xDCDCAA),
            .op:           hex(0xD4D4D4),
            .heading:      hex(0x569CD6),
            .link:         hex(0x4EC9B0),
            .invalid:      hex(0xF44747),
        ],
        boldKinds: [.keyword, .tag, .heading],

        background:             hex(0x1E1E1E),
        foreground:             hex(0xDCDCDC),
        cursor:                 hex(0xEDEDED),
        selection:              hex(0x264F78),
        currentLine:            hex(0x2A2D2E),

        gutterBackground:       hex(0x252526),
        gutterForeground:       hex(0x858585),
        gutterActiveForeground: hex(0xE0E0E0),
        gutterSeparator:        hex(0x3A3A3A),
        bookmarkFill:           hex(0x569CD6),

        invisibles:             hex(0x505050),
        indentGuide:            hex(0x3B3B3B),
        bracketMatch:           hex(0xFFD700),
        bracketMismatch:        hex(0xFF6060),

        findHighlight:          hex(0x7A6A00),
        findCurrent:            hex(0xB86A18),
        markHighlight:          hex(0x0E5A5A),
        smartHighlight:         hex(0x2E6E2E, alpha: 0.55),

        chromeBackground:       hex(0x2D2D30),
        chromeBorder:           hex(0x1A1A1A),
        tabInactive:            hex(0x2D2D30),
        tabInactiveHover:       hex(0x3E3E42),
        tabActive:              hex(0x1E1E1E),
        tabActiveAccent:        hex(0xFF8000),
        tabText:                hex(0xBEBEBE),
        tabActiveText:          hex(0xFFFFFF),
        statusBackground:       hex(0x2D2D30),
        statusText:             hex(0xD0D0D0)
    )

    static let all: [Theme] = [.classic, .dark]

    static func named(_ name: String) -> Theme? {
        all.first { $0.name == name }
    }
}
