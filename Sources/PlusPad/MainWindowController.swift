import AppKit

/// Lays out the four fixed strips of the window: toolbar, tab bar, editor, status.
final class MainContentView: NSView {
    var toolbar: ToolbarView?
    var tabBar: TabBarView?
    var editorContainer: NSView?
    var statusBar: StatusBarView?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        if let toolbar, !toolbar.isHidden {
            toolbar.frame = NSRect(x: 0, y: y, width: bounds.width, height: ToolbarView.height)
            y += ToolbarView.height
        }
        if let tabBar {
            tabBar.frame = NSRect(x: 0, y: y, width: bounds.width, height: TabBarView.height)
            y += TabBarView.height
        }
        var bottom: CGFloat = 0
        if let statusBar, !statusBar.isHidden {
            bottom = StatusBarView.height
            statusBar.frame = NSRect(x: 0, y: bounds.height - bottom,
                                     width: bounds.width, height: bottom)
        }
        editorContainer?.frame = NSRect(x: 0, y: y, width: bounds.width,
                                        height: max(0, bounds.height - y - bottom))
    }
}

/// Splits the editor area between the document and its rendered preview.
///
/// A custom container rather than an `NSSplitView`: the divider has to match
/// the window's other chrome, which is themed and hand-drawn, and the behaviour
/// wanted here is one fixed divider with a remembered position rather than
/// anything `NSSplitView` adds on top of that.
final class EditorSplitView: NSView {
    /// The editor pane for the current tab. Swapped as tabs change.
    var content: NSView? {
        didSet {
            guard content !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let content {
                addSubview(content, positioned: .below, relativeTo: preview)
            }
            needsLayout = true
        }
    }

    var preview: NSView? {
        didSet {
            guard preview !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let preview { addSubview(preview) }
            needsLayout = true
        }
    }

    /// Fraction of the usable width kept by the editor.
    var fraction: CGFloat = 0.5
    var onFractionChanged: ((CGFloat) -> Void)?
    var dividerColor: NSColor = .gridColor

    static let dividerWidth: CGFloat = 6
    private var dragging = false

    override var isFlipped: Bool { true }

    private var previewIsVisible: Bool {
        guard let preview else { return false }
        return !preview.isHidden
    }

    override func layout() {
        super.layout()
        guard let content else { return }
        guard previewIsVisible, let preview else {
            content.frame = bounds
            return
        }
        let usable = max(0, bounds.width - Self.dividerWidth)
        // Both halves stay usable however far the divider is dragged, so a
        // mis-drag cannot leave the editor a sliver wide with no way back.
        let left = (usable * min(max(fraction, 0.15), 0.85)).rounded()
        content.frame = NSRect(x: 0, y: 0, width: left, height: bounds.height)
        preview.frame = NSRect(x: left + Self.dividerWidth, y: 0,
                               width: usable - left, height: bounds.height)
    }

    private var dividerRect: NSRect {
        guard previewIsVisible, let content else { return .zero }
        return NSRect(x: content.frame.maxX, y: 0, width: Self.dividerWidth, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard previewIsVisible else { return }
        dividerColor.setFill()
        // Geometry from `bounds`, never from `dirtyRect`, which is the window's
        // dirty region expressed in this view's coordinates.
        let line = NSRect(x: dividerRect.midX - 0.5, y: 0, width: 1, height: bounds.height)
        line.intersection(dirtyRect).fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard previewIsVisible else { return }
        addCursorRect(dividerRect, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard previewIsVisible, dividerRect.insetBy(dx: -2, dy: 0).contains(point) else {
            super.mouseDown(with: event)
            return
        }
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return super.mouseDragged(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let usable = max(1, bounds.width - Self.dividerWidth)
        fraction = min(max(point.x / usable, 0.15), 0.85)
        needsLayout = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return super.mouseUp(with: event) }
        dragging = false
        onFractionChanged?(fraction)
        window?.invalidateCursorRects(for: self)
    }
}

/// The window: tabs, documents, and everything the menus act on.
final class MainWindowController: NSWindowController {

    private(set) var documents: [TextDocument] = []
    private var panes: [UUID: EditorPane] = [:]
    private(set) var currentIndex = 0

    private let contentView = MainContentView()
    private let toolbar = ToolbarView()
    private let tabBar = TabBarView()
    private let editorContainer = EditorSplitView()
    private var previewPane: MarkdownPreviewPane?
    private let statusBar = StatusBarView()

    private var store: SessionStore { SessionStore.shared }
    var settings: Settings {
        get { store.settings }
        set { store.settings = newValue }
    }
    var theme: Theme { settings.theme }

    private var autosaveTimer: Timer?
    private var periodicTimer: Timer?
    private var overwriteMode = false

    var findController: FindPanelController?

    // MARK: - Construction

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 560, height: 320)
        window.setFrameAutosaveName("PlusPadMainWindow")
        window.tabbingMode = .disallowed
        self.init(window: window)

        contentView.toolbar = toolbar
        contentView.tabBar = tabBar
        contentView.editorContainer = editorContainer
        contentView.statusBar = statusBar
        contentView.addSubview(toolbar)
        contentView.addSubview(tabBar)
        contentView.addSubview(editorContainer)
        contentView.addSubview(statusBar)
        window.contentView = contentView

        tabBar.delegate = self
        statusBar.delegate = self
        applyTheme()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey),
            name: NSWindow.didBecomeKeyNotification, object: window)

        // A periodic flush is the backstop for the debounce: if an edit is
        // followed by no further activity at all and then the machine loses
        // power, the debounce has already fired; if the app is busy, this
        // guarantees a write happens anyway.
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.persistSession()
        }
    }

    deinit {
        autosaveTimer?.invalidate()
        periodicTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func applyTheme() {
        let current = theme
        toolbar.theme = current
        tabBar.theme = current
        tabBar.showsCloseButtons = settings.showTabCloseButtons
        statusBar.theme = current
        editorContainer.wantsLayer = true
        editorContainer.layer?.backgroundColor = current.background.cgColor
        toolbar.isHidden = !settings.showToolbar
        statusBar.isHidden = !settings.showStatusBar
        for pane in panes.values { pane.apply(settings: settings, theme: current) }
        editorContainer.dividerColor = current.chromeBorder
        previewPane?.applySettings(settings)
        toolbar.syncToggles(with: settings)
        contentView.needsLayout = true
        window?.appearance = NSAppearance(named: current.isDark ? .darkAqua : .aqua)
    }

    // MARK: - Documents

    var currentDocument: TextDocument? {
        documents.indices.contains(currentIndex) ? documents[currentIndex] : nil
    }

    var currentPane: EditorPane? {
        currentDocument.flatMap { panes[$0.id] }
    }

    var currentTextView: EditorTextView? { currentPane?.textView }

    @discardableResult
    func addDocument(_ document: TextDocument, at index: Int? = nil, select: Bool = true) -> Int {
        let position = index.map { max(0, min($0, documents.count)) } ?? documents.count
        documents.insert(document, at: position)
        if select {
            selectTab(position)
        } else {
            refreshTabs()
        }
        scheduleAutosave()
        return position
    }

    func makeUntitledDocument() -> TextDocument {
        let document = TextDocument(untitledName: store.nextUntitledName())
        document.lineEnding = .systemDefault
        document.encoding = .utf8
        document.highlighter.language = document.language
        return document
    }

    /// Open a file, or focus the tab that already has it.
    @discardableResult
    func open(url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        if let existing = documents.firstIndex(where: { $0.fileURL?.standardizedFileURL == standardized }) {
            selectTab(existing)
            return true
        }
        do {
            let data = try Data(contentsOf: standardized)
            let decoded = TextCodec.decode(data)
            let date = try? FileManager.default
                .attributesOfItem(atPath: standardized.path)[.modificationDate] as? Date

            let document = TextDocument(untitledName: standardized.lastPathComponent)
            document.delegate = self
            document.adopt(decoded: decoded, url: standardized, modificationDate: date ?? Date())
            document.acceptCurrentTextAsSaved()

            // Replace a single pristine untitled tab rather than opening beside
            // it, which is what makes "launch, open a file" show one tab.
            //
            // The new document is added *first*: closing the only tab makes
            // `closeTab` create a replacement blank one to keep the window from
            // emptying, so closing before adding just swaps one blank tab for
            // another and the file lands as a third.
            let pristine: TextDocument? = (documents.count == 1 && !documents[0].hasFile
                                           && !documents[0].isDirty
                                           && documents[0].textStorage.length == 0)
                ? documents[0] : nil
            addDocument(document)
            if let pristine, let index = documents.firstIndex(where: { $0 === pristine }) {
                closeTab(at: index, archive: false)
            }
            settings.noteRecentFile(standardized)
            store.saveSettings()
            if decoded.hadDecodingFallback {
                presentNotice("Some characters in \(standardized.lastPathComponent) could not be decoded.",
                              detail: "The file was opened using a lossy fallback. Choose the right encoding from the Encoding menu, then reopen it, before saving over the original.")
            }
            return true
        } catch {
            presentNotice("Could not open \(standardized.lastPathComponent)",
                          detail: error.localizedDescription)
            return false
        }
    }

    func selectTab(_ index: Int) {
        guard documents.indices.contains(index) else { return }
        currentPane?.captureViewState()
        currentIndex = index
        let document = documents[index]

        let pane = paneForDocument(document)
        let isNewlyShown = pane.superview !== editorContainer
        editorContainer.content = pane
        if isNewlyShown { pane.restoreViewState() }
        pane.textView.recomputeFolds()
        window?.makeFirstResponder(pane.textView)
        refreshTabs()
        updateStatusBar()
        updateWindowTitle()
        updateMarkdownPreview()
        findController?.editorChanged()
    }

    /// Every pane that has actually been built. Restored tabs the user has not
    /// visited have none, which is the point of building them lazily.
    func allPanes() -> [EditorPane] { Array(panes.values) }

    /// Build a pane on first use.
    func paneForDocument(_ document: TextDocument) -> EditorPane {
        if let existing = panes[document.id] { return existing }
        document.delegate = self
        let pane = EditorPane(document: document, settings: settings, theme: theme)
        pane.paneDelegate = self
        panes[document.id] = pane
        return pane
    }

    // MARK: - Closing, without ever asking

    /// Close a tab.
    ///
    /// There is no "save changes?" sheet here and there is not meant to be one.
    /// Unsaved text is written to the workspace's Recently Closed folder first,
    /// so closing is always reversible with Reopen Closed Tab, and the text is
    /// also recoverable from the Finder without the app. The prompt exists in
    /// other editors because they have nowhere to put the text; this one does.
    func closeTab(at index: Int, archive: Bool = true) {
        guard documents.indices.contains(index) else { return }
        let document = documents[index]
        panes[document.id]?.captureViewState()

        if archive {
            let snapshot = DocumentSnapshot(document: document,
                                            backupFilename: Workspace.backupFilename(for: document))
            store.archiveClosed(snapshot)
        }

        panes[document.id]?.removeFromSuperview()
        panes.removeValue(forKey: document.id)
        documents.remove(at: index)

        if documents.isEmpty {
            let fresh = makeUntitledDocument()
            fresh.delegate = self
            documents.append(fresh)
            currentIndex = 0
        } else {
            currentIndex = min(index, documents.count - 1)
        }
        // Force the pane swap even though currentIndex may not have changed.
        let target = currentIndex
        currentIndex = -1
        selectTab(target)
        persistSession()
    }

    func closeAllTabs(except keepIndex: Int? = nil) {
        let keepID = keepIndex.flatMap { documents.indices.contains($0) ? documents[$0].id : nil }
        for index in stride(from: documents.count - 1, through: 0, by: -1) {
            guard documents[index].id != keepID else { continue }
            closeTab(at: index)
        }
    }

    func reopenClosedTab() {
        guard let (record, text) = store.takeMostRecentlyClosed() else {
            NSSound.beep()
            return
        }
        let document = TextDocument(id: record.id, untitledName: record.untitledName)
        document.delegate = self
        document.encoding = FileEncoding(rawValue: record.encoding) ?? .utf8
        document.lineEnding = LineEnding(rawValue: record.lineEnding) ?? .systemDefault
        if let language = LanguageRegistry.named(record.language) {
            document.language = language
            document.languageIsExplicit = record.languageExplicit
            document.highlighter.language = language
        }
        document.replaceAllText(text)
        restoreBaseline(for: document, record: record, restoredText: text)
        document.selectedRange = NSRange(location: record.selectionLocation, length: record.selectionLength)
        document.scrollOffset = CGFloat(record.scrollOffset)
        document.bookmarks = Set(record.bookmarks)
        addDocument(document)
    }

    // MARK: - Saving

    @discardableResult
    func save(document: TextDocument, promptForLocation: Bool = false) -> Bool {
        if document.fileURL == nil || promptForLocation {
            return saveAs(document: document)
        }
        do {
            try document.save()
            refreshTabs()
            updateStatusBar()
            updateWindowTitle()
            persistSession()
            return true
        } catch {
            presentNotice("Could not save \(document.displayName)",
                          detail: error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func saveAs(document: TextDocument) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.displayName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = true
        if let existing = document.fileURL {
            panel.directoryURL = existing.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try document.save(to: url)
            settings.noteRecentFile(url)
            store.saveSettings()
            refreshTabs()
            updateStatusBar()
            updateWindowTitle()
            persistSession()
            return true
        } catch {
            presentNotice("Could not save \(document.displayName)", detail: error.localizedDescription)
            return false
        }
    }

    func saveAll() {
        for document in documents where document.isDirty && document.hasFile {
            save(document: document)
        }
        // Untitled buffers are left alone on purpose: Save All should not open a
        // stack of save panels, and the scratch buffers are already safe in the
        // workspace.
    }

    // MARK: - Session

    func restoreSession() {
        guard let session = store.loadSession(), !session.documents.isEmpty else {
            let fresh = makeUntitledDocument()
            fresh.delegate = self
            documents.append(fresh)
            selectTab(0)
            return
        }

        var recoveredUnsaved = 0
        for record in session.documents {
            let document = TextDocument(id: record.id, untitledName: record.untitledName)
            document.delegate = self
            document.encoding = FileEncoding(rawValue: record.encoding) ?? .utf8
            document.lineEnding = LineEnding(rawValue: record.lineEnding) ?? .systemDefault
            if let language = LanguageRegistry.named(record.language) {
                document.language = language
                document.languageIsExplicit = record.languageExplicit
                document.highlighter.language = language
            }

            let backupText = record.backupFile.flatMap { store.backupText(named: $0) }
            let diskText = loadDiskText(for: record, into: document)

            // The backup wins whenever it exists, because it is by definition at
            // least as new as the file and is the only copy of an unsaved edit.
            let text = backupText ?? diskText ?? ""
            document.replaceAllText(text)
            document.fileURLRestored(record.fileURL)
            document.lastKnownDiskDate = record.diskDate
            restoreBaseline(for: document, record: record, restoredText: text)
            if document.isDirty { recoveredUnsaved += 1 }

            document.selectedRange = NSRange(location: record.selectionLocation,
                                             length: record.selectionLength)
            document.scrollOffset = CGFloat(record.scrollOffset)
            document.bookmarks = Set(record.bookmarks)
            documents.append(document)
        }

        if documents.isEmpty {
            let fresh = makeUntitledDocument()
            fresh.delegate = self
            documents.append(fresh)
        }
        selectTab(min(max(0, session.activeIndex), documents.count - 1))
        store.pruneRecentlyClosed()

        // The report is held rather than shown here: `restoreSession` runs
        // before the window is on screen, and an alert floating over an empty
        // desktop cannot show the tabs it is telling you about.
        if Workspace.shared.previousRunCrashed {
            pendingRecovery = (recoveredUnsaved, documents.count)
        }
    }

    private var pendingRecovery: (unsaved: Int, total: Int)?

    /// Show the recovery notice, once the window it refers to is visible.
    func reportPendingRecoveryIfNeeded() {
        guard let pending = pendingRecovery else { return }
        pendingRecovery = nil
        reportRecovery(unsaved: pending.unsaved, total: pending.total)
    }

    private func loadDiskText(for record: SessionDocument, into document: TextDocument) -> String? {
        guard let url = record.fileURL else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            document.fileMissing = true
            return nil
        }
        let decoded = TextCodec.decode(data, forcing: FileEncoding(rawValue: record.encoding))
        return decoded.text
    }

    /// Work out what the document's "saved" baseline should be, so the dirty
    /// flag after a restore reflects reality rather than always reading dirty.
    private func restoreBaseline(for document: TextDocument, record: SessionDocument,
                                 restoredText: String) {
        guard let url = record.fileURL, !document.fileMissing,
              let data = try? Data(contentsOf: url) else {
            // No readable file to compare against. An empty baseline is the
            // honest one: a scratch buffer with text in it has never been
            // written anywhere, so it is unsaved, and an empty one is not.
            document.markDirty(against: "")
            return
        }
        let onDisk = TextCodec.decode(data, forcing: document.encoding).text
        if onDisk == restoredText {
            document.acceptCurrentTextAsSaved()
        } else {
            document.markDirty(against: onDisk)
        }
    }

    private func reportRecovery(unsaved: Int, total: Int) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "PlusPad recovered your work"
        if unsaved > 0 {
            alert.informativeText = """
            The last session ended unexpectedly. \(total) tab\(total == 1 ? " was" : "s were") \
            restored, \(unsaved) of them with unsaved changes.

            Everything is also on disk in the workspace folder, under Backups.
            """
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show Backups Folder")
        } else {
            alert.informativeText = """
            The last session ended unexpectedly. All \(total) tab\(total == 1 ? "" : "s") \
            were restored, and nothing was unsaved.
            """
            alert.addButton(withTitle: "OK")
        }
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Workspace.shared.backupsDirectory])
        }
    }

    /// Debounced write. Every edit restarts it; a quiet moment commits.
    func scheduleAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.persistSession()
        }
    }

    func persistSession() {
        currentPane?.captureViewState()
        let snapshots = documents.map {
            DocumentSnapshot(document: $0, backupFilename: Workspace.backupFilename(for: $0))
        }
        store.persist(documents: snapshots, activeIndex: currentIndex)
    }

    /// Called on quit and on losing focus: write synchronously enough that a
    /// crash immediately afterwards still finds the text on disk.
    func flushNow() {
        autosaveTimer?.invalidate()
        persistSession()
        store.saveSettings()
    }

    // MARK: - Chrome updates

    func refreshTabs() {
        let items = documents.map { document in
            TabItem(title: document.displayName,
                    tooltip: document.hasFile ? (document.fileURL?.path ?? "") : "Not saved to a file",
                    isDirty: document.isDirty,
                    isReadOnly: document.fileMissing)
        }
        tabBar.setItems(items, selected: currentIndex)
        toolbar.syncToggles(with: settings)
    }

    func updateWindowTitle() {
        guard let document = currentDocument else { window?.title = "PlusPad"; return }
        let marker = document.isDirty ? " *" : ""
        window?.title = "\(document.displayName)\(marker) - PlusPad"
        window?.representedURL = document.fileURL
        // The proxy icon's dirty dot is AppKit's own; suppressing the standard
        // close-button dot keeps the red disk on the tab as the single signal.
        window?.isDocumentEdited = false
    }

    func updateStatusBar() {
        guard let document = currentDocument, let textView = currentTextView else { return }
        let selection = textView.selectedRange()
        let text = document.textStorage.string as NSString
        let index = document.lineIndex
        let caretLine = index.lineIndex(containing: min(selection.location, max(0, text.length)))
        let lineStart = index.start(ofLine: caretLine)

        var column = 0
        var offset = lineStart
        while offset < min(selection.location, text.length) {
            column += (text.character(at: offset) == 9)
                ? settings.tabWidth - (column % settings.tabWidth) : 1
            offset += 1
        }

        var selectedLines = 0
        if selection.length > 0 {
            let firstLine = index.lineIndex(containing: selection.location)
            let lastLine = index.lineIndex(containing: min(text.length - 1,
                                                          selection.location + selection.length - 1))
            selectedLines = lastLine - firstLine + 1
        }

        statusBar.update(language: document.language.name,
                         characters: text.length,
                         lines: index.lineCount,
                         line: caretLine + 1,
                         column: column + 1,
                         selectionLength: selection.length,
                         selectionLines: selectedLines,
                         lineEnding: document.lineEnding,
                         encoding: document.encoding,
                         overwrite: overwriteMode)
    }

    // MARK: - External change detection

    @objc private func windowBecameKey() {
        checkForExternalChanges()
    }

    /// Notice that a file changed underneath us.
    ///
    /// A clean document is reloaded silently -- there is nothing to lose and it
    /// is what the user means by switching to a branch in another window. A
    /// dirty one is never touched without asking, and the choice is presented
    /// with the in-memory version as the default.
    func checkForExternalChanges() {
        for document in documents where document.diskChangedExternally() {
            guard let url = document.fileURL else { continue }
            if !FileManager.default.fileExists(atPath: url.path) {
                document.fileMissing = true
                document.markDirty(against: "")
                continue
            }
            if !document.isDirty {
                try? document.revertFromDisk()
                panes[document.id]?.textView.rebuildBaseAttributes()
                continue
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(document.displayName) changed on disk"
            alert.informativeText = """
            This file was modified by another program, and you also have unsaved changes here.

            Your unsaved version is safe in the workspace either way.
            """
            alert.addButton(withTitle: "Keep My Version")
            alert.addButton(withTitle: "Reload From Disk")
            if alert.runModal() == .alertSecondButtonReturn {
                try? document.revertFromDisk()
                panes[document.id]?.textView.rebuildBaseAttributes()
            } else {
                document.lastKnownDiskDate = Date()
            }
        }
        refreshTabs()
        updateStatusBar()
    }

    // MARK: - Helpers

    func presentNotice(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func toggleOverwriteMode() {
        overwriteMode.toggle()
        updateStatusBar()
    }

    var isOverwriteMode: Bool { overwriteMode }
}

// MARK: - Tab bar

extension MainWindowController: TabBarViewDelegate {
    func tabBar(_ bar: TabBarView, didSelect index: Int) {
        selectTab(index)
    }

    func tabBar(_ bar: TabBarView, didRequestClose index: Int) {
        closeTab(at: index)
    }

    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int) {
        guard documents.indices.contains(from), documents.indices.contains(to) else { return }
        let moved = documents.remove(at: from)
        documents.insert(moved, at: to)
        if currentIndex == from { currentIndex = to }
        else if from < currentIndex && to >= currentIndex { currentIndex -= 1 }
        else if from > currentIndex && to <= currentIndex { currentIndex += 1 }
        refreshTabs()
        scheduleAutosave()
    }

    func tabBar(_ bar: TabBarView, didRequestContextMenuFor index: Int, at point: NSPoint) {
        guard documents.indices.contains(index) else { return }
        let document = documents[index]
        let menu = NSMenu()

        menu.addItem(withTitle: "Close", action: #selector(contextClose(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Close All But This", action: #selector(contextCloseOthers(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Save", action: #selector(contextSave(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Save As...", action: #selector(contextSaveAs(_:)), keyEquivalent: "")
        if document.hasFile {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy Full Path", action: #selector(contextCopyPath(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Show in Finder", action: #selector(contextRevealInFinder(_:)), keyEquivalent: "")
        }
        for item in menu.items {
            item.target = self
            item.representedObject = index
        }
        menu.popUp(positioning: nil, at: point, in: bar)
    }

    func tabBarDidRequestNewDocument(_ bar: TabBarView) {
        let document = makeUntitledDocument()
        document.delegate = self
        addDocument(document)
    }

    private func indexFrom(_ sender: Any?) -> Int? {
        (sender as? NSMenuItem)?.representedObject as? Int
    }

    @objc private func contextClose(_ sender: Any?) {
        if let index = indexFrom(sender) { closeTab(at: index) }
    }

    @objc private func contextCloseOthers(_ sender: Any?) {
        if let index = indexFrom(sender) { closeAllTabs(except: index) }
    }

    @objc private func contextSave(_ sender: Any?) {
        if let index = indexFrom(sender), documents.indices.contains(index) {
            save(document: documents[index])
        }
    }

    @objc private func contextSaveAs(_ sender: Any?) {
        if let index = indexFrom(sender), documents.indices.contains(index) {
            saveAs(document: documents[index])
        }
    }

    @objc private func contextCopyPath(_ sender: Any?) {
        guard let index = indexFrom(sender), documents.indices.contains(index),
              let path = documents[index].fileURL?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func contextRevealInFinder(_ sender: Any?) {
        guard let index = indexFrom(sender), documents.indices.contains(index),
              let url = documents[index].fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Editor callbacks

extension MainWindowController: EditorTextViewDelegate {
    func editorTextDidChange(_ editor: EditorTextView) {
        guard let document = editor.document else { return }
        document.noteTextChanged()

        // Repair the line index and the highlighter's state cache against just
        // the edited region, then redraw only what is visible.
        let text = document.textStorage.string as NSString
        let edited = document.textStorage.editedRange
        let delta = document.textStorage.changeInLength
        if edited.location != NSNotFound {
            document.lineIndex.update(text, editedRange: edited, delta: delta)
            document.highlighter.invalidate(fromLine: document.lineIndex.lineIndex(containing: edited.location))
        } else {
            document.lineIndex.rebuild(text)
            document.highlighter.invalidateAll()
        }

        editor.recomputeFolds()
        editor.setNeedsHighlight()
        panes[document.id]?.gutter.recalculateWidth()
        panes[document.id]?.gutter.needsDisplay = true
        refreshTabs()
        updateStatusBar()
        updateWindowTitle()
        scheduleAutosave()
    }

    func editorSelectionDidChange(_ editor: EditorTextView) {
        updateStatusBar()
        currentPane?.gutter.needsDisplay = true
    }
}

extension MainWindowController: TextDocumentDelegate {
    func documentStateChanged(_ document: TextDocument) {
        refreshTabs()
        updateStatusBar()
        updateWindowTitle()
        if document === currentDocument { previewPane?.scheduleRefresh() }
    }

    func documentLanguageChanged(_ document: TextDocument) {
        panes[document.id]?.textView.refreshHighlighting()
        updateStatusBar()
        // Setting the language by hand is how a file that is Markdown without
        // saying so in its name gets a preview.
        if document === currentDocument { updateMarkdownPreview() }
    }
}

// MARK: - Markdown preview

extension MainWindowController: MarkdownPreviewDelegate {

    /// The preview is only ever shown for Markdown. The setting is remembered
    /// across launches and across tabs, so switching to a .md file brings it
    /// back rather than making you ask for it again, and switching away hides
    /// it rather than showing a rendered view of source code.
    var currentDocumentIsMarkdown: Bool {
        guard let language = currentDocument?.language else { return false }
        if case .markdown = language.flavor { return true }
        return false
    }

    /// Whether the rendered pane is on screen right now, which is not the same
    /// as the setting: the setting is a standing preference, this is what the
    /// current document actually gets.
    var isMarkdownPreviewVisible: Bool {
        guard let preview = editorContainer.preview else { return false }
        return !preview.isHidden
    }

    func updateMarkdownPreview() {
        let wanted = settings.showMarkdownPreview && currentDocumentIsMarkdown
        guard wanted else {
            editorContainer.preview?.isHidden = true
            editorContainer.needsLayout = true
            editorContainer.needsDisplay = true
            return
        }

        let pane = previewPane ?? {
            let created = MarkdownPreviewPane(settings: settings, theme: theme)
            created.delegate = self
            previewPane = created
            editorContainer.preview = created
            editorContainer.fraction = CGFloat(settings.markdownPreviewFraction)
            editorContainer.onFractionChanged = { [weak self] fraction in
                guard let self else { return }
                self.settings.markdownPreviewFraction = Double(fraction)
                SessionStore.shared.saveSettings()
            }
            return created
        }()

        pane.isHidden = false
        pane.show(currentDocument)
        editorContainer.needsLayout = true
        editorContainer.needsDisplay = true
        window?.invalidateCursorRects(for: editorContainer)
    }

    @objc func toggleMarkdownPreview(_ sender: Any?) {
        settings.showMarkdownPreview.toggle()
        SessionStore.shared.saveSettings()
        // Asking for a preview on a document that is not Markdown is a clear
        // enough statement of intent to treat as one: mark the language rather
        // than silently doing nothing.
        if settings.showMarkdownPreview, !currentDocumentIsMarkdown,
           let document = currentDocument, let markdown = LanguageRegistry.named("Markdown") {
            document.setLanguage(markdown, explicit: true)
            currentPane?.textView.refreshHighlighting()
        }
        updateMarkdownPreview()
    }

    func preview(_ preview: MarkdownPreviewPane, didActivate url: URL) {
        // A link to a local file opens as a tab, which is what makes a folder of
        // cross-linked notes navigable. Anything else is the system's business.
        if url.isFileURL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                open(url: url)
                return
            }
        }
        NSWorkspace.shared.open(url)
    }
}
