import AppKit

/// The Settings window.
///
/// Deliberately one flat panel rather than a tabbed preferences stack: there are
/// about fifteen settings, and hiding them behind three tabs would make them
/// harder to find, not easier. The workspace path sits at the bottom because it
/// is the one setting people come here looking for.
final class PreferencesController: NSWindowController {

    private weak var host: MainWindowController?

    private let fontLabel = NSTextField(labelWithString: "")
    private let sizeField = NSTextField()
    private let tabWidthField = NSTextField()
    private let spacesBox = NSButton(checkboxWithTitle: "Insert spaces instead of tabs", target: nil, action: nil)
    private let autoIndentBox = NSButton(checkboxWithTitle: "Keep indentation on new lines", target: nil, action: nil)
    private let autoCloseBox = NSButton(checkboxWithTitle: "Automatically close brackets and quotes", target: nil, action: nil)
    private let smartHighlightBox = NSButton(checkboxWithTitle: "Highlight other occurrences of the selection", target: nil, action: nil)
    private let currentLineBox = NSButton(checkboxWithTitle: "Highlight the current line", target: nil, action: nil)
    private let closeButtonsBox = NSButton(checkboxWithTitle: "Show close buttons on tabs", target: nil, action: nil)
    private let wordWrapBox = NSButton(checkboxWithTitle: "Word wrap", target: nil, action: nil)
    private let lineNumbersBox = NSButton(checkboxWithTitle: "Show line numbers", target: nil, action: nil)
    private let themePopup = NSPopUpButton()
    private let retentionField = NSTextField()
    private let workspaceLabel = NSTextField(wrappingLabelWithString: "")

    init(host: MainWindowController) {
        self.host = host
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 534),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Settings"
        super.init(window: window)
        build()
        load()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        var y: CGFloat = 494

        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.boldSystemFont(ofSize: 12)
            label.frame = NSRect(x: 20, y: y, width: 400, height: 18)
            content.addSubview(label)
            y -= 26
        }

        func row(_ text: String, _ control: NSView, controlWidth: CGFloat = 220) {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            label.font = NSFont.systemFont(ofSize: 12)
            label.frame = NSRect(x: 20, y: y + 2, width: 170, height: 18)
            content.addSubview(label)
            control.frame = NSRect(x: 200, y: y - 2, width: controlWidth, height: 24)
            content.addSubview(control)
            y -= 30
        }

        func check(_ box: NSButton) {
            box.frame = NSRect(x: 200, y: y, width: 250, height: 20)
            box.font = NSFont.systemFont(ofSize: 12)
            box.target = self
            box.action = #selector(apply)
            content.addSubview(box)
            y -= 24
        }

        heading("Appearance")
        for theme in Theme.all { themePopup.addItem(withTitle: theme.name) }
        themePopup.target = self
        themePopup.action = #selector(apply)
        row("Theme:", themePopup)

        fontLabel.font = NSFont.systemFont(ofSize: 12)
        let fontRow = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        fontLabel.frame = NSRect(x: 0, y: 3, width: 150, height: 18)
        let fontButton = NSButton(title: "Change...", target: self, action: #selector(pickFont))
        fontButton.frame = NSRect(x: 152, y: 0, width: 88, height: 24)
        fontButton.bezelStyle = .rounded
        fontRow.addSubview(fontLabel)
        fontRow.addSubview(fontButton)
        row("Editor font:", fontRow, controlWidth: 240)

        sizeField.target = self
        sizeField.action = #selector(apply)
        row("Font size:", sizeField, controlWidth: 70)

        y -= 8
        heading("Editing")
        tabWidthField.target = self
        tabWidthField.action = #selector(apply)
        row("Tab width:", tabWidthField, controlWidth: 70)
        check(wordWrapBox)
        check(lineNumbersBox)
        check(spacesBox)
        check(autoIndentBox)
        check(autoCloseBox)
        check(smartHighlightBox)
        check(currentLineBox)
        check(closeButtonsBox)

        y -= 12
        heading("Workspace")

        workspaceLabel.frame = NSRect(x: 24, y: y - 26, width: 412, height: 34)
        workspaceLabel.font = NSFont.systemFont(ofSize: 11)
        workspaceLabel.textColor = .secondaryLabelColor
        content.addSubview(workspaceLabel)
        y -= 42

        let change = NSButton(title: "Change Folder...", target: nil,
                              action: #selector(PlusPadCommands.chooseWorkspace(_:)))
        change.frame = NSRect(x: 24, y: y - 4, width: 140, height: 24)
        change.bezelStyle = .rounded
        content.addSubview(change)

        let reveal = NSButton(title: "Show in Finder", target: nil,
                              action: #selector(PlusPadCommands.revealWorkspace(_:)))
        reveal.frame = NSRect(x: 172, y: y - 4, width: 130, height: 24)
        reveal.bezelStyle = .rounded
        content.addSubview(reveal)
        y -= 32

        retentionField.target = self
        retentionField.action = #selector(apply)
        row("Keep closed tabs for (days):", retentionField, controlWidth: 70)
    }

    private func load() {
        guard let settings = host?.settings else { return }
        themePopup.selectItem(withTitle: settings.themeName)
        fontLabel.stringValue = "\(settings.fontName)"
        sizeField.stringValue = String(Int(settings.fontSize))
        tabWidthField.stringValue = String(settings.tabWidth)
        spacesBox.state = settings.insertSpaces ? .on : .off
        autoIndentBox.state = settings.autoIndent ? .on : .off
        autoCloseBox.state = settings.autoCloseBrackets ? .on : .off
        smartHighlightBox.state = settings.smartHighlight ? .on : .off
        currentLineBox.state = settings.highlightCurrentLine ? .on : .off
        closeButtonsBox.state = settings.showTabCloseButtons ? .on : .off
        wordWrapBox.state = settings.wordWrap ? .on : .off
        lineNumbersBox.state = settings.showLineNumbers ? .on : .off
        retentionField.stringValue = String(settings.recentlyClosedRetentionDays)
        workspaceLabel.stringValue = Workspace.shared.root.path
    }

    @objc private func pickFont() {
        host?.chooseFont(nil)
        // The font panel writes back through the responder chain, so the label
        // is refreshed a beat later rather than from a return value.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.load() }
    }

    @objc private func apply() {
        guard var settings = host?.settings else { return }
        settings.themeName = themePopup.titleOfSelectedItem ?? settings.themeName
        if let size = Double(sizeField.stringValue), size >= 7, size <= 48 {
            settings.fontSize = size
        }
        if let width = Int(tabWidthField.stringValue), width >= 1, width <= 16 {
            settings.tabWidth = width
        }
        if let days = Int(retentionField.stringValue), days >= 1, days <= 3650 {
            settings.recentlyClosedRetentionDays = days
        }
        settings.insertSpaces = spacesBox.state == .on
        settings.autoIndent = autoIndentBox.state == .on
        settings.autoCloseBrackets = autoCloseBox.state == .on
        settings.smartHighlight = smartHighlightBox.state == .on
        settings.highlightCurrentLine = currentLineBox.state == .on
        settings.showTabCloseButtons = closeButtonsBox.state == .on
        settings.wordWrap = wordWrapBox.state == .on
        settings.showLineNumbers = lineNumbersBox.state == .on

        host?.settings = settings
        host?.applySettingsEverywhere()
        load()
    }

    override func showWindow(_ sender: Any?) {
        load()
        super.showWindow(sender)
    }
}
