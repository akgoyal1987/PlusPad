import AppKit

/// The Find / Replace / Find in Files dialog.
///
/// Kept as a floating panel with a tab across the top rather than a docked find
/// bar, because that is the shape of the Notepad++ dialog and because the
/// options -- three search modes plus four checkboxes -- do not fit in a bar
/// without hiding most of them behind a menu.
final class FindPanelController: NSWindowController, NSWindowDelegate {

    enum Tab: Int, CaseIterable { case find, replace, findInFiles

        var title: String {
            switch self {
            case .find: return "Find"
            case .replace: return "Replace"
            case .findInFiles: return "Find in Files"
            }
        }
    }

    private weak var host: MainWindowController?
    private(set) var mode: Tab = .find

    private let modeSelector = NSSegmentedControl()

    // One instance of each control, shared by every mode.
    //
    // They were previously added to three separate NSTabView views. A view has a
    // single superview, so adding the same field to the second tab silently
    // removed it from the first, and the Find tab ended up with its labels but
    // no text field, no checkboxes and no search-mode radios -- which is why
    // Find appeared to do nothing. One panel, rows shown and hidden per mode.
    private let findField = NSComboBox()
    private let replaceField = NSComboBox()
    private let filtersField = NSTextField()
    private let directoryField = NSTextField()
    private let browseButton = NSButton()

    private let findRow = NSView()
    private let replaceRow = NSView()
    private let filtersRow = NSView()
    private let directoryRow = NSView()

    private let matchCaseBox = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let wholeWordBox = NSButton(checkboxWithTitle: "Match whole word only", target: nil, action: nil)
    private let wrapBox = NSButton(checkboxWithTitle: "Wrap around", target: nil, action: nil)
    private let inSelectionBox = NSButton(checkboxWithTitle: "In selection", target: nil, action: nil)
    private let subfoldersBox = NSButton(checkboxWithTitle: "In all sub-folders", target: nil, action: nil)

    private let modeTitle = NSTextField(labelWithString: "Search Mode")
    private let modeNormal = NSButton(radioButtonWithTitle: "Normal", target: nil, action: nil)
    private let modeExtended = NSButton(radioButtonWithTitle: "Extended (\\n, \\t, \\0, \\x..)", target: nil, action: nil)
    private let modeRegex = NSButton(radioButtonWithTitle: "Regular expression", target: nil, action: nil)

    private let statusLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var actionButtons: [NSButton] = []

    private var searchHistory: [String] = []
    private var replaceHistory: [String] = []

    /// Every control that must be on screen, for the self test. The bug this
    /// guards against was silent: the panel opened, looked plausible, and simply
    /// had no text field in it.
    var requiredControls: [(String, NSView)] {
        [("Find what field", findField), ("Replace with field", replaceField),
         ("Filters field", filtersField), ("Directory field", directoryField),
         ("Match case", matchCaseBox), ("Whole word", wholeWordBox),
         ("Wrap around", wrapBox), ("In selection", inSelectionBox),
         ("Sub-folders", subfoldersBox), ("Normal mode", modeNormal),
         ("Extended mode", modeExtended), ("Regex mode", modeRegex),
         ("Mode selector", modeSelector), ("Status label", statusLabel)]
    }

    var visibleActionButtonTitles: [String] { actionButtons.map(\.title) }

    func setSearchTextForTesting(_ text: String) { findField.stringValue = text }
    func setReplaceTextForTesting(_ text: String) { replaceField.stringValue = text }

    private let rowHeight: CGFloat = 30
    private let panelWidth: CGFloat = 742
    private let optionColumnX: CGFloat = 300
    private let buttonX: CGFloat = 542
    private let buttonWidth: CGFloat = 184

    // MARK: - Construction

    init(host: MainWindowController) {
        self.host = host
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 742, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Find"
        panel.isFloatingPanel = true
        // Floats above PlusPad's own windows, but goes away when PlusPad is not
        // the active app. Without this the panel sat on top of every other
        // application on the desktop.
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        super.init(window: panel)
        panel.delegate = self
        build()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func labelled(_ title: String, _ control: NSView, controlWidth: CGFloat,
                          trailing: NSView? = nil) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 26))
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.font = NSFont.systemFont(ofSize: 12)
        label.frame = NSRect(x: 8, y: 4, width: 100, height: 18)
        row.addSubview(label)
        control.frame = NSRect(x: 116, y: 0, width: controlWidth, height: 24)
        row.addSubview(control)
        if let trailing {
            trailing.frame = NSRect(x: 116 + controlWidth + 6, y: 0, width: 40, height: 24)
            row.addSubview(trailing)
        }
        return row
    }

    private func build() {
        guard let content = window?.contentView else { return }

        modeSelector.segmentStyle = .automatic
        modeSelector.segmentCount = Tab.allCases.count
        for tab in Tab.allCases {
            modeSelector.setLabel(tab.title, forSegment: tab.rawValue)
            modeSelector.setWidth(120, forSegment: tab.rawValue)
        }
        modeSelector.selectedSegment = 0
        modeSelector.target = self
        modeSelector.action = #selector(modeSegmentChanged)
        modeSelector.frame = NSRect(x: 116, y: 334, width: 360, height: 24)
        content.addSubview(modeSelector)

        for combo in [findField, replaceField] {
            combo.completes = false
            combo.usesDataSource = false
            combo.numberOfVisibleItems = 10
            combo.font = NSFont.systemFont(ofSize: 12)
        }
        for field in [filtersField, directoryField] { field.font = NSFont.systemFont(ofSize: 12) }
        filtersField.placeholderString = "*.swift *.py   (blank means every text file)"
        directoryField.placeholderString = "Folder to search"
        browseButton.title = "..."
        browseButton.bezelStyle = .rounded
        browseButton.target = self
        browseButton.action = #selector(browseDirectory)

        // Return in either text field runs the mode's primary action.
        findField.target = self
        findField.action = #selector(primaryAction)
        replaceField.target = self
        replaceField.action = #selector(primaryAction)

        addRow(findRow, into: content, labelled("Find what:", findField, controlWidth: 300))
        addRow(replaceRow, into: content, labelled("Replace with:", replaceField, controlWidth: 300))
        addRow(filtersRow, into: content, labelled("Filters:", filtersField, controlWidth: 300))
        addRow(directoryRow, into: content,
               labelled("Directory:", directoryField, controlWidth: 254, trailing: browseButton))

        for box in [matchCaseBox, wholeWordBox, wrapBox, inSelectionBox, subfoldersBox] {
            box.font = NSFont.systemFont(ofSize: 12)
            box.target = self
            box.action = #selector(optionChanged)
            content.addSubview(box)
        }
        wrapBox.state = .on
        subfoldersBox.state = .on

        modeTitle.font = NSFont.boldSystemFont(ofSize: 12)
        content.addSubview(modeTitle)
        for radio in [modeNormal, modeExtended, modeRegex] {
            radio.font = NSFont.systemFont(ofSize: 12)
            radio.target = self
            radio.action = #selector(searchModeChanged)
            content.addSubview(radio)
        }
        modeNormal.state = .on

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 16, y: 14, width: 400, height: 18)
        content.addSubview(statusLabel)

        closeButton.title = "Close"
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        content.addSubview(closeButton)

        applyMode()
    }

    private func addRow(_ container: NSView, into content: NSView, _ built: NSView) {
        container.frame = built.frame
        for child in built.subviews { container.addSubview(child) }
        content.addSubview(container)
    }

    /// Which rows and which buttons this mode shows, and how tall the panel
    /// needs to be for them.
    ///
    /// The height is computed rather than fixed: Find needs one text field and
    /// Find in Files needs four, and a single height for both leaves either a
    /// large empty band or clipped controls.
    private func applyMode() {
        guard let window, let content = window.contentView else { return }

        replaceRow.isHidden = (mode == .find)
        filtersRow.isHidden = (mode != .findInFiles)
        directoryRow.isHidden = (mode != .findInFiles)
        inSelectionBox.isHidden = (mode == .findInFiles)
        wrapBox.isHidden = (mode == .findInFiles)
        subfoldersBox.isHidden = (mode != .findInFiles)

        let rows = [findRow, replaceRow, filtersRow, directoryRow].filter { !$0.isHidden }
        let checks = [matchCaseBox, wholeWordBox, wrapBox, inSelectionBox, subfoldersBox]
            .filter { !$0.isHidden }
        let optionRows = max(checks.count, 3)
        let buttons = buttonSpecs()

        let optionsHeight = CGFloat(optionRows) * 24
        let buttonsHeight = CGFloat(buttons.count) * 29
        let stackHeight = CGFloat(rows.count) * rowHeight + 8 + optionsHeight
        let height = 14 + 24 + 12 + max(stackHeight, buttonsHeight) + 12 + 40

        window.setContentSize(NSSize(width: panelWidth, height: height))
        let top = height

        modeSelector.frame = NSRect(x: 116, y: top - 38, width: 360, height: 24)

        var y = top - 38 - 12 - 26
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: content.bounds.width, height: 26)
            y -= rowHeight
        }

        var optionY = y - 4
        modeTitle.frame = NSRect(x: optionColumnX, y: optionY, width: 180, height: 18)
        var checkY = optionY
        for box in checks {
            box.frame = NSRect(x: 22, y: checkY, width: 260, height: 18)
            checkY -= 24
        }
        optionY -= 24
        for radio in [modeNormal, modeExtended, modeRegex] {
            radio.frame = NSRect(x: optionColumnX + 6, y: optionY, width: 216, height: 18)
            optionY -= 24
        }

        for button in actionButtons { button.removeFromSuperview() }
        actionButtons = []
        var buttonY = top - 38 - 12 - 26
        for (title, selector, isDefault) in buttons {
            let button = NSButton(title: title, target: self, action: selector)
            button.frame = NSRect(x: buttonX, y: buttonY, width: buttonWidth, height: 26)
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 12)
            if isDefault { button.keyEquivalent = "\r" }
            content.addSubview(button)
            actionButtons.append(button)
            buttonY -= 29
        }

        statusLabel.frame = NSRect(x: 16, y: 14, width: buttonX - 26, height: 18)
        closeButton.frame = NSRect(x: panelWidth - 100, y: 10, width: 84, height: 26)
        window.title = mode.title
        content.needsDisplay = true
    }

    private func buttonSpecs() -> [(String, Selector, Bool)] {
        switch mode {
        case .find:
            return [("Find Next", #selector(findNext), true),
                    ("Find Previous", #selector(findPrevious), false),
                    ("Count", #selector(count), false),
                    ("Find All in This File", #selector(findAll), false),
                    ("Find All in All Files", #selector(findAllInAllDocuments), false),
                    ("Mark All", #selector(markAll), false)]
        case .replace:
            return [("Find Next", #selector(findNext), true),
                    ("Replace", #selector(replaceOne), false),
                    ("Replace All", #selector(replaceAll), false),
                    ("Replace All in All Files", #selector(replaceAllEverywhere), false),
                    ("Count", #selector(count), false)]
        case .findInFiles:
            return [("Find All", #selector(findInFiles), true)]
        }
    }

    /// The theme follows the editor rather than the system, so the panel does
    /// not come up dark over a light window.
    func applyTheme() {
        window?.appearance = NSAppearance(named: (host?.theme.isDark ?? false) ? .darkAqua : .aqua)
    }

    @objc private func modeSegmentChanged() {
        mode = Tab(rawValue: modeSelector.selectedSegment) ?? .find
        applyMode()
    }

    @objc private func optionChanged() {}

    @objc private func searchModeChanged(_ sender: NSButton) {
        for radio in [modeNormal, modeExtended, modeRegex] where radio !== sender {
            radio.state = .off
        }
        sender.state = .on
    }

    /// Return in a field runs whatever the mode's default button does.
    @objc private func primaryAction() {
        switch mode {
        case .find, .replace: findNext()
        case .findInFiles: findInFiles()
        }
    }

    // MARK: - Presentation

    func show(tab: Tab, seedingFromSelection: Bool = true) {
        mode = tab
        modeSelector.selectedSegment = tab.rawValue
        applyMode()
        applyTheme()

        if seedingFromSelection, let textView = host?.currentTextView {
            let selection = textView.selectedRange()
            if selection.length > 0, selection.length < 200 {
                let text = (textView.string as NSString).substring(with: selection)
                if !text.contains("\n") { findField.stringValue = text }
            }
        }
        if directoryField.stringValue.isEmpty,
           let url = host?.currentDocument?.fileURL?.deletingLastPathComponent() {
            directoryField.stringValue = url.path
        }
        showWindow(nil)
        window?.makeFirstResponder(findField)
        statusLabel.stringValue = ""
    }

    /// Called when the active tab changes so stale match highlights go away.
    func editorChanged() {
        host?.currentTextView?.clearFindHighlights()
    }

    @objc private func closePanel() {
        host?.currentTextView?.clearFindHighlights()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        host?.currentTextView?.clearFindHighlights()
    }

    // MARK: - Query assembly

    private var options: SearchOptions {
        var opts = SearchOptions()
        opts.mode = modeRegex.state == .on ? .regex : (modeExtended.state == .on ? .extended : .normal)
        opts.matchCase = matchCaseBox.state == .on
        opts.wholeWord = wholeWordBox.state == .on
        opts.wrapAround = wrapBox.state == .on
        opts.inSelection = inSelectionBox.state == .on
        return opts
    }

    private func currentQuery() -> SearchQuery? {
        let pattern = findField.stringValue
        guard !pattern.isEmpty else {
            statusLabel.stringValue = "Enter something to find."
            return nil
        }
        rememberSearch(pattern)
        let query = SearchQuery(pattern: pattern, options: options)
        if let error = query.error {
            statusLabel.stringValue = "Invalid regular expression: \(error)"
            return nil
        }
        return query
    }

    private func rememberSearch(_ term: String) {
        guard !term.isEmpty else { return }
        searchHistory.removeAll { $0 == term }
        searchHistory.insert(term, at: 0)
        if searchHistory.count > 20 { searchHistory.removeLast() }
        findField.removeAllItems()
        findField.addItems(withObjectValues: searchHistory)
    }

    private func rememberReplacement(_ term: String) {
        guard !term.isEmpty else { return }
        replaceHistory.removeAll { $0 == term }
        replaceHistory.insert(term, at: 0)
        if replaceHistory.count > 20 { replaceHistory.removeLast() }
        replaceField.removeAllItems()
        replaceField.addItems(withObjectValues: replaceHistory)
    }

    /// The range to search within: the whole document, or the selection when
    /// "In selection" is ticked and there is one worth restricting to.
    private func scope(for textView: EditorTextView) -> NSRange? {
        guard inSelectionBox.state == .on else { return nil }
        let selection = textView.selectedRange()
        return selection.length > 1 ? selection : nil
    }

    // MARK: - Find

    @objc func findNext() {
        guard let query = currentQuery(), let pane = host?.currentPane else { return }
        let text = pane.textView.string as NSString
        let from = pane.textView.selectedRange().location + max(1, pane.textView.selectedRange().length)
        guard let hit = FindEngine.next(query, in: text, from: min(from, text.length),
                                        within: scope(for: pane.textView)) else {
            statusLabel.stringValue = "No matches."
            NSSound.beep()
            return
        }
        pane.reveal(hit.range)
        statusLabel.stringValue = "Found at line \(lineNumber(of: hit.range.location, in: pane))."
    }

    @objc func findPrevious() {
        guard let query = currentQuery(), let pane = host?.currentPane else { return }
        let text = pane.textView.string as NSString
        guard let hit = FindEngine.previous(query, in: text,
                                            before: pane.textView.selectedRange().location,
                                            within: scope(for: pane.textView)) else {
            statusLabel.stringValue = "No matches."
            NSSound.beep()
            return
        }
        pane.reveal(hit.range)
        statusLabel.stringValue = "Found at line \(lineNumber(of: hit.range.location, in: pane))."
    }

    @objc func count() {
        guard let query = currentQuery(), let pane = host?.currentPane else { return }
        let text = pane.textView.string as NSString
        let range = scope(for: pane.textView) ?? NSRange(location: 0, length: text.length)
        let hits = FindEngine.matches(of: query, in: text, range: range)
        statusLabel.stringValue = "\(hits.count) match\(hits.count == 1 ? "" : "es")."
    }

    @objc func markAll() {
        guard let query = currentQuery(), let pane = host?.currentPane else { return }
        let text = pane.textView.string as NSString
        let range = scope(for: pane.textView) ?? NSRange(location: 0, length: text.length)
        let hits = FindEngine.matches(of: query, in: text, range: range)
        pane.textView.setFindHighlights(hits.map(\.range), current: nil)
        statusLabel.stringValue = "Marked \(hits.count) match\(hits.count == 1 ? "" : "es")."
    }

    @objc func findAll() {
        guard let query = currentQuery(), let host, let pane = host.currentPane else { return }
        let text = pane.textView.string as NSString
        let hits = FindEngine.matches(of: query, in: text,
                                      range: NSRange(location: 0, length: text.length))
        guard !hits.isEmpty else {
            statusLabel.stringValue = "No matches."
            return
        }
        pane.textView.setFindHighlights(hits.map(\.range), current: nil)

        let name = host.currentDocument?.displayName ?? "document"
        var report = "Search \"\(findField.stringValue)\" (\(hits.count) hits in \(name))\n\n"
        for hit in hits {
            let line = pane.document.lineIndex.lineIndex(containing: hit.range.location)
            let lineRange = pane.document.lineIndex.range(ofLine: line)
            let safe = NSRange(location: lineRange.location,
                               length: min(lineRange.length, text.length - lineRange.location))
            let content = text.substring(with: safe).trimmingCharacters(in: .newlines)
            report += "\tLine \(line + 1): \(content)\n"
        }
        host.presentSearchResults(title: "Search results", text: report)
        statusLabel.stringValue = "\(hits.count) match\(hits.count == 1 ? "" : "es")."
    }

    /// Search every open document, including tabs whose editor has never been
    /// built. The text lives on the document, not the view, so a restored tab
    /// the user has not visited is searched like any other.
    @objc func findAllInAllDocuments() {
        guard let query = currentQuery(), let host else { return }
        var report = "Search \"\(findField.stringValue)\" in \(host.documents.count) open file"
        report += host.documents.count == 1 ? "\n\n" : "s\n\n"
        var totalHits = 0
        var matchedFiles = 0

        for document in host.documents {
            let text = document.textStorage.string as NSString
            let hits = FindEngine.matches(of: query, in: text,
                                          range: NSRange(location: 0, length: text.length))
            guard !hits.isEmpty else { continue }
            matchedFiles += 1
            totalHits += hits.count

            let where_ = document.fileURL?.path ?? document.displayName
            report += "\(where_)  (\(hits.count) hit\(hits.count == 1 ? "" : "s"))\n"
            for hit in hits.prefix(500) {
                let line = document.lineIndex.lineIndex(containing: hit.range.location)
                let lineRange = document.lineIndex.range(ofLine: line)
                let safe = NSRange(location: lineRange.location,
                                   length: min(lineRange.length, text.length - lineRange.location))
                report += "\tLine \(line + 1): "
                report += text.substring(with: safe).trimmingCharacters(in: .newlines) + "\n"
            }
            if hits.count > 500 { report += "\t... \(hits.count - 500) more\n" }
            report += "\n"
        }

        guard totalHits > 0 else {
            statusLabel.stringValue = "No matches in any open file."
            return
        }
        host.presentSearchResults(title: "Search results", text: report)
        statusLabel.stringValue = "\(totalHits) hit\(totalHits == 1 ? "" : "s") in \(matchedFiles) "
            + "file\(matchedFiles == 1 ? "" : "s")."
    }

    private func lineNumber(of location: Int, in pane: EditorPane) -> Int {
        pane.document.lineIndex.lineIndex(containing: location) + 1
    }

    // MARK: - Replace

    @objc func replaceOne() {
        guard let query = currentQuery(), let pane = host?.currentPane else { return }
        rememberReplacement(replaceField.stringValue)
        let textView = pane.textView
        let text = textView.string as NSString
        let selection = textView.selectedRange()

        // Replace the current selection when it is itself a match; otherwise
        // this acts as Find Next. That two-step is what makes holding the button
        // walk through a document one hit at a time.
        let selectionMatches = selection.length > 0 &&
            FindEngine.matches(of: query, in: text, range: selection).contains {
                $0.range == selection
            }

        if selectionMatches {
            let hit = FindEngine.matches(of: query, in: text, range: selection)[0]
            let replacement = FindEngine.expand(template: replaceField.stringValue, for: hit,
                                                in: text, mode: query.options.mode)
            if textView.shouldChangeText(in: selection, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: selection, with: replacement)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: selection.location,
                                                  length: (replacement as NSString).length))
            }
        }
        findNext()
    }

    @objc func replaceAll() {
        guard let query = currentQuery(), let pane = host?.currentPane else { return }
        rememberReplacement(replaceField.stringValue)
        let count = performReplaceAll(query, in: pane, scope: scope(for: pane.textView))
        statusLabel.stringValue = "Replaced \(count) occurrence\(count == 1 ? "" : "s")."
    }

    @objc func replaceAllEverywhere() {
        guard let query = currentQuery(), let host else { return }
        rememberReplacement(replaceField.stringValue)
        var total = 0
        var touched = 0
        for document in host.documents {
            let pane = host.ensurePane(for: document)
            let replaced = performReplaceAll(query, in: pane, scope: nil)
            if replaced > 0 { touched += 1 }
            total += replaced
        }
        statusLabel.stringValue = "Replaced \(total) occurrence\(total == 1 ? "" : "s") in \(touched) file\(touched == 1 ? "" : "s")."
    }

    /// One undoable replace-all over a whole range.
    ///
    /// The document is rewritten in a single edit rather than one per match, so
    /// a thousand replacements are one Undo, and the text view only relayouts
    /// once.
    private func performReplaceAll(_ query: SearchQuery, in pane: EditorPane,
                                   scope: NSRange?) -> Int {
        let textView = pane.textView
        guard let storage = textView.textStorage else { return 0 }
        let text = storage.string as NSString
        let range = scope ?? NSRange(location: 0, length: text.length)
        let hits = FindEngine.matches(of: query, in: text, range: range)
        guard !hits.isEmpty else { return 0 }

        let mutable = NSMutableString(string: text.substring(with: range))
        var replaced = 0
        for hit in hits.reversed() {
            let local = NSRange(location: hit.range.location - range.location, length: hit.range.length)
            guard local.location >= 0, local.location + local.length <= mutable.length else { continue }
            let replacement = FindEngine.expand(template: replaceField.stringValue, for: hit,
                                                in: text, mode: query.options.mode)
            mutable.replaceCharacters(in: local, with: replacement)
            replaced += 1
        }

        let result = mutable as String
        guard textView.shouldChangeText(in: range, replacementString: result) else { return 0 }
        storage.replaceCharacters(in: range, with: result)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        return replaced
    }

    // MARK: - Find in Files

    @objc private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !directoryField.stringValue.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: directoryField.stringValue)
        }
        if panel.runModal() == .OK, let url = panel.url {
            directoryField.stringValue = url.path
        }
    }

    @objc func findInFiles() {
        guard let query = currentQuery(), let host else { return }
        let root = directoryField.stringValue
        guard !root.isEmpty else {
            statusLabel.stringValue = "Choose a directory to search."
            return
        }
        let directory = URL(fileURLWithPath: root, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            statusLabel.stringValue = "That directory does not exist."
            return
        }

        let filters = filtersField.stringValue
            .split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "," })
            .map(String.init)
        let recursive = subfoldersBox.state == .on
        let needle = findField.stringValue
        statusLabel.stringValue = "Searching..."

        // Walking a source tree is slow enough to block the window visibly, so
        // it runs off the main thread and only the finished report comes back.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = FileSearcher.search(query: query, needle: needle, in: directory,
                                             filters: filters, recursive: recursive)
            DispatchQueue.main.async {
                guard let self else { return }
                host.presentSearchResults(title: "Search results", text: report.text)
                self.statusLabel.stringValue =
                    "\(report.hits) hit\(report.hits == 1 ? "" : "s") in \(report.files) file\(report.files == 1 ? "" : "s") "
                    + "(searched \(report.scanned))."
            }
        }
    }
}

/// Recursive text search over a directory tree.
enum FileSearcher {

    struct Report {
        var text: String
        var hits: Int
        var files: Int
        var scanned: Int
    }

    /// Skipped wholesale. Searching a `.git` directory or a `node_modules` tree
    /// finds thousands of matches nobody wants and takes far longer than the
    /// search the user asked for.
    private static let skippedDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "build", "DerivedData",
        ".venv", "venv", "__pycache__", ".next", "dist", ".gradle", "Pods",
    ]

    private static let maximumFileSize = 8 * 1024 * 1024

    static func search(query: SearchQuery, needle: String, in root: URL,
                       filters: [String], recursive: Bool) -> Report {
        let fm = FileManager.default
        var output = "Search \"\(needle)\" in \(root.path)\n\n"
        var totalHits = 0
        var matchedFiles = 0
        var scanned = 0

        var stack: [URL] = [root]
        while let directory = stack.popLast() {
            guard let entries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else { continue }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if recursive, !skippedDirectories.contains(entry.lastPathComponent) {
                        stack.append(entry)
                    }
                    continue
                }
                guard matches(filters: filters, name: entry.lastPathComponent) else { continue }
                guard (values?.fileSize ?? 0) <= maximumFileSize else { continue }
                guard let data = try? Data(contentsOf: entry) else { continue }
                // A NUL byte in the first few kilobytes means this is not text;
                // running a regex over a binary is slow and never useful.
                guard !data.prefix(4096).contains(0) else { continue }
                scanned += 1

                let decoded = TextCodec.decode(data)
                let text = decoded.text as NSString
                let hits = FindEngine.matches(of: query, in: text,
                                              range: NSRange(location: 0, length: text.length))
                guard !hits.isEmpty else { continue }

                matchedFiles += 1
                totalHits += hits.count
                output += "\(entry.path)  (\(hits.count) hit\(hits.count == 1 ? "" : "s"))\n"

                let index = LineIndex()
                index.rebuild(text)
                for hit in hits.prefix(500) {
                    let line = index.lineIndex(containing: hit.range.location)
                    let lineRange = index.range(ofLine: line)
                    let safe = NSRange(location: lineRange.location,
                                       length: min(lineRange.length, text.length - lineRange.location))
                    let content = text.substring(with: safe).trimmingCharacters(in: .newlines)
                    output += "\tLine \(line + 1): \(content)\n"
                }
                if hits.count > 500 { output += "\t... \(hits.count - 500) more\n" }
                output += "\n"
            }
            if !recursive && directory == root { break }
        }

        if totalHits == 0 { output += "No matches.\n" }
        return Report(text: output, hits: totalHits, files: matchedFiles, scanned: scanned)
    }

    /// Glob match against the `*.ext` style filters Notepad++ accepts. An empty
    /// filter list means every file.
    private static func matches(filters: [String], name: String) -> Bool {
        guard !filters.isEmpty else { return true }
        for filter in filters {
            if filter == "*" || filter == "*.*" { return true }
            if filter.hasPrefix("*.") {
                if name.lowercased().hasSuffix(String(filter.dropFirst(1)).lowercased()) { return true }
            } else if filter.lowercased() == name.lowercased() {
                return true
            }
        }
        return false
    }
}
