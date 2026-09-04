import AppKit

/// Everything the menus, the toolbar and the keyboard invoke.
///
/// Split out of `MainWindowController` so the window keeps to owning documents
/// and chrome while this file holds the verbs. All of it funnels through two
/// helpers, `transformSelection` and `transformSelectedLines`, so every text
/// command lands on the undo stack as exactly one undoable step.
extension MainWindowController: PlusPadCommands, StatusBarViewDelegate, NSMenuItemValidation {

    // MARK: - Editing helpers

    /// Apply a transform to the selection, or the whole document if there is
    /// none, as a single undoable edit.
    @discardableResult
    func transformSelection(_ transform: (String) -> String) -> Bool {
        guard let textView = currentTextView, let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        let range = selection.length > 0 ? selection : NSRange(location: 0, length: storage.length)
        guard range.length > 0 else { return false }

        let original = (storage.string as NSString).substring(with: range)
        let updated = transform(original)
        guard updated != original else { return false }
        guard textView.shouldChangeText(in: range, replacementString: updated) else { return false }

        storage.replaceCharacters(in: range, with: updated)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location,
                                          length: (updated as NSString).length))
        return true
    }

    /// Apply a transform to the whole lines the selection touches.
    ///
    /// Line commands must not be able to cut a line in half, so the range is
    /// always widened to line boundaries before the transform sees it.
    @discardableResult
    func transformSelectedLines(_ transform: (String) -> String) -> Bool {
        guard let textView = currentTextView, let storage = textView.textStorage,
              storage.length > 0 else { return false }
        let text = storage.string as NSString
        let selection = textView.selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: min(selection.location, text.length),
                                                    length: min(selection.length,
                                                                text.length - min(selection.location, text.length))))
        let original = text.substring(with: lineRange)
        let hadTrailingNewline = original.hasSuffix("\n")
        let body = hadTrailingNewline ? String(original.dropLast()) : original

        let transformed = transform(body)
        let updated = hadTrailingNewline ? transformed + "\n" : transformed
        guard updated != original else { return false }
        guard textView.shouldChangeText(in: lineRange, replacementString: updated) else { return false }

        storage.replaceCharacters(in: lineRange, with: updated)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: lineRange.location,
                                          length: max(0, (updated as NSString).length - (hadTrailingNewline ? 1 : 0))))
        return true
    }

    func ensurePane(for document: TextDocument) -> EditorPane {
        paneForDocument(document)
    }

    /// Open a read-only-ish results buffer in a new tab.
    ///
    /// Search results land in an ordinary tab rather than a dedicated panel:
    /// they are text, the editor already knows how to show text, and putting
    /// them in a tab means they are searchable, savable and survive a relaunch
    /// like anything else.
    func presentSearchResults(title: String, text: String) {
        let document = TextDocument(untitledName: title)
        document.delegate = self
        document.setLanguage(LanguageRegistry.plainText, explicit: true)
        document.replaceAllText(text)
        document.acceptCurrentTextAsSaved()
        addDocument(document)
        currentPane?.textView.rebuildBaseAttributes()
    }

    // MARK: - File

    func newDocument(_ sender: Any?) {
        let document = makeUntitledDocument()
        document.delegate = self
        addDocument(document)
    }

    func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // No type filter: a general-purpose text editor opens whatever it is
        // pointed at, and guessing a whitelist only gets in the way.
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url: url) }
    }

    func saveDocument(_ sender: Any?) {
        guard let document = currentDocument else { return }
        save(document: document)
    }

    func saveDocumentAs(_ sender: Any?) {
        guard let document = currentDocument else { return }
        saveAs(document: document)
    }

    func saveAllDocuments(_ sender: Any?) {
        saveAll()
    }

    func closeCurrentTab(_ sender: Any?) {
        closeTab(at: currentIndex)
    }

    func reopenClosedTab(_ sender: Any?) {
        reopenClosedTab()
    }

    @objc func closeAllDocuments(_ sender: Any?) {
        closeAllTabs()
    }

    @objc func revertDocument(_ sender: Any?) {
        guard let document = currentDocument, document.hasFile else { return }
        let alert = NSAlert()
        alert.messageText = "Discard changes to \(document.displayName)?"
        alert.informativeText = "The file will be reloaded from disk. A copy of the current text stays in the workspace's Recently Closed folder."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reload")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        // Park the text first: reverting is the one destructive thing in the
        // app, so it goes through the same recovery folder as a closed tab.
        SessionStore.shared.archiveClosed(
            DocumentSnapshot(document: document, backupFilename: Workspace.backupFilename(for: document)))
        try? document.revertFromDisk()
        currentPane?.textView.rebuildBaseAttributes()
        refreshTabs()
    }

    @objc func openRecentFile(_ sender: Any?) {
        guard let path = (sender as? NSMenuItem)?.representedObject as? String else { return }
        open(url: URL(fileURLWithPath: path))
    }

    @objc func clearRecentFiles(_ sender: Any?) {
        settings.recentFiles = []
        SessionStore.shared.saveSettings()
    }

    // MARK: - Search

    func showFind(_ sender: Any?) { presentFindPanel(tab: .find) }
    func showReplace(_ sender: Any?) { presentFindPanel(tab: .replace) }
    func showFindInFiles(_ sender: Any?) { presentFindPanel(tab: .findInFiles) }

    private func presentFindPanel(tab: FindPanelController.Tab) {
        if findController == nil {
            findController = FindPanelController(host: self)
        }
        findController?.show(tab: tab)
    }

    func findNext(_ sender: Any?) {
        if findController == nil { presentFindPanel(tab: .find); return }
        findController?.findNext()
    }

    func findPrevious(_ sender: Any?) {
        if findController == nil { presentFindPanel(tab: .find); return }
        findController?.findPrevious()
    }

    /// Search for the word under the cursor without opening the dialog.
    @objc func findSelectionNext(_ sender: Any?) {
        guard let pane = currentPane else { return }
        let selection = pane.textView.selectedRange()
        guard selection.length > 0 else { return }
        let needle = (pane.textView.string as NSString).substring(with: selection)
        let query = SearchQuery(pattern: needle, options: SearchOptions())
        let text = pane.textView.string as NSString
        if let hit = FindEngine.next(query, in: text, from: selection.location + selection.length) {
            pane.reveal(hit.range)
        } else {
            NSSound.beep()
        }
    }

    func goToLine(_ sender: Any?) {
        guard let document = currentDocument, let pane = currentPane else { return }
        let alert = NSAlert()
        alert.messageText = "Go to line"
        alert.informativeText = "1 to \(document.lineIndex.lineCount)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "Line number"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn,
              let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        let line = max(0, min(number - 1, document.lineIndex.lineCount - 1))
        pane.reveal(NSRange(location: document.lineIndex.start(ofLine: line), length: 0))
    }

    // MARK: - View

    func zoomIn(_ sender: Any?) { adjustFontSize(by: 1) }
    func zoomOut(_ sender: Any?) { adjustFontSize(by: -1) }
    func zoomReset(_ sender: Any?) {
        settings.fontSize = 13
        applySettingsEverywhere()
    }

    private func adjustFontSize(by delta: Double) {
        settings.fontSize = max(7, min(48, settings.fontSize + delta))
        applySettingsEverywhere()
    }

    func toggleWordWrap(_ sender: Any?) {
        settings.wordWrap.toggle()
        applySettingsEverywhere()
    }

    func toggleInvisibles(_ sender: Any?) {
        settings.showInvisibles.toggle()
        applySettingsEverywhere()
    }

    func toggleIndentGuides(_ sender: Any?) {
        settings.showIndentGuides.toggle()
        applySettingsEverywhere()
    }

    func toggleLineNumbers(_ sender: Any?) {
        settings.showLineNumbers.toggle()
        applySettingsEverywhere()
    }

    @objc func toggleCurrentLineHighlight(_ sender: Any?) {
        settings.highlightCurrentLine.toggle()
        applySettingsEverywhere()
    }

    @objc func toggleToolbar(_ sender: Any?) {
        settings.showToolbar.toggle()
        applySettingsEverywhere()
    }

    @objc func toggleStatusBar(_ sender: Any?) {
        settings.showStatusBar.toggle()
        applySettingsEverywhere()
    }

    @objc func toggleOverwrite(_ sender: Any?) {
        toggleOverwriteMode()
    }

    @objc func selectTheme(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        settings.themeName = name
        applySettingsEverywhere()
    }

    @objc func chooseFont(_ sender: Any?) {
        NSFontManager.shared.setSelectedFont(settings.editorFont, isMultiple: false)
        NSFontManager.shared.target = self
        NSFontPanel.shared.makeKeyAndOrderFront(nil)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let manager = sender else { return }
        let updated = manager.convert(settings.editorFont)
        settings.fontName = updated.fontName
        settings.fontSize = Double(updated.pointSize)
        applySettingsEverywhere()
    }

    func applySettingsEverywhere() {
        applyTheme()
        for pane in allPanes() { pane.apply(settings: settings, theme: theme) }
        currentPane?.textView.rebuildBaseAttributes()
        refreshTabs()
        updateStatusBar()
        SessionStore.shared.saveSettings()
    }

    // MARK: - Folding

    @objc func foldAll(_ sender: Any?) {
        guard let document = currentDocument else { return }
        document.foldModel.collapseAll()
        currentTextView?.refreshFolding()
        currentPane?.gutter.needsDisplay = true
    }

    @objc func unfoldAll(_ sender: Any?) {
        guard let document = currentDocument else { return }
        document.foldModel.expandAll()
        currentTextView?.refreshFolding()
        currentPane?.gutter.needsDisplay = true
    }

    /// Fold or unfold the region the caret is sitting in.
    @objc func toggleFoldAtCursor(_ sender: Any?) {
        guard let document = currentDocument, let textView = currentTextView else { return }
        let line = document.lineIndex.lineIndex(containing: textView.selectedRange().location)
        if document.foldModel.isHeader(line) {
            textView.toggleFold(atLine: line)
            return
        }
        // Not on a header: fold the region that contains the caret.
        for header in document.foldModel.headers.sorted(by: >)
        where header < line && document.foldModel.regionEnd(for: header) >= line {
            textView.toggleFold(atLine: header)
            return
        }
        NSSound.beep()
    }

    @objc func toggleFoldMargin(_ sender: Any?) {
        settings.showFoldMargin.toggle()
        applySettingsEverywhere()
    }

    // MARK: - Bookmarks

    func toggleBookmark(_ sender: Any?) {
        guard let document = currentDocument, let textView = currentTextView else { return }
        let line = document.lineIndex.lineIndex(containing: textView.selectedRange().location)
        if document.bookmarks.contains(line) {
            document.bookmarks.remove(line)
        } else {
            document.bookmarks.insert(line)
        }
        currentPane?.gutter.needsDisplay = true
        scheduleAutosave()
    }

    func nextBookmark(_ sender: Any?) { jumpBookmark(forward: true) }
    func previousBookmark(_ sender: Any?) { jumpBookmark(forward: false) }

    private func jumpBookmark(forward: Bool) {
        guard let document = currentDocument, let pane = currentPane,
              !document.bookmarks.isEmpty else { NSSound.beep(); return }
        let current = document.lineIndex.lineIndex(containing: pane.textView.selectedRange().location)
        let sorted = document.bookmarks.sorted()
        // Wrap in both directions, so repeatedly pressing the key cycles rather
        // than stopping at the last mark.
        let target = forward
            ? (sorted.first { $0 > current } ?? sorted.first!)
            : (sorted.last { $0 < current } ?? sorted.last!)
        pane.reveal(NSRange(location: document.lineIndex.start(ofLine: target), length: 0))
    }

    func clearBookmarks(_ sender: Any?) {
        currentDocument?.bookmarks.removeAll()
        currentPane?.gutter.needsDisplay = true
        scheduleAutosave()
    }

    // MARK: - Workspace

    func revealWorkspace(_ sender: Any?) {
        Workspace.shared.revealInFinder()
    }

    func chooseWorkspace(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where PlusPad keeps its session, settings and unsaved-work backups."
        panel.prompt = "Use This Folder"
        panel.directoryURL = Workspace.shared.root.deletingLastPathComponent()

        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        // A folder called PlusPad already is used as-is; anything else gets a
        // PlusPad subfolder, so picking the Desktop does not scatter files
        // across it.
        let target = chosen.lastPathComponent == "PlusPad"
            ? chosen : chosen.appendingPathComponent("PlusPad", isDirectory: true)

        flushNow()
        do {
            try Workspace.shared.relocate(to: target)
            SessionStore.shared.loadSettings()
            applySettingsEverywhere()
            persistSession()
            let alert = NSAlert()
            alert.messageText = "Workspace moved"
            alert.informativeText = """
            PlusPad now keeps its data in:
            \(target.path)

            The previous folder was left in place; delete it yourself once you \
            have confirmed everything you need is here.
            """
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")
            if alert.runModal() == .alertSecondButtonReturn {
                Workspace.shared.revealInFinder()
            }
        } catch {
            presentNotice("Could not move the workspace", detail: error.localizedDescription)
        }
    }

    // MARK: - Encoding, line endings, language

    @objc func setEncoding(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let encoding = FileEncoding(rawValue: raw),
              let document = currentDocument else { return }
        document.convert(to: encoding)
        scheduleAutosave()
    }

    @objc func reinterpretEncoding(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let encoding = FileEncoding(rawValue: raw),
              let document = currentDocument else { return }
        guard document.hasFile else {
            document.convert(to: encoding)
            return
        }
        if document.isDirty {
            let alert = NSAlert()
            alert.messageText = "Reopen \(document.displayName) as \(encoding.displayName)?"
            alert.informativeText = "Unsaved changes will be replaced by the file on disk. A copy is kept in the workspace's Recently Closed folder."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Reopen")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            SessionStore.shared.archiveClosed(
                DocumentSnapshot(document: document, backupFilename: Workspace.backupFilename(for: document)))
        }
        do {
            try document.reinterpret(as: encoding)
            currentPane?.textView.rebuildBaseAttributes()
        } catch {
            presentNotice("Could not reopen the file", detail: error.localizedDescription)
        }
    }

    @objc func setLineEnding(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let ending = LineEnding(rawValue: raw),
              let document = currentDocument else { return }
        document.convert(to: ending)
        scheduleAutosave()
    }

    @objc func setLanguage(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String,
              let language = LanguageRegistry.named(name),
              let document = currentDocument else { return }
        document.setLanguage(language, explicit: true)
        currentPane?.textView.refreshHighlighting()
    }

    // MARK: - Status bar segments

    func statusBar(_ bar: StatusBarView, didClickSegment segment: StatusBarView.Segment,
                   at point: NSPoint) {
        let menu = NSMenu()
        switch segment {
        case .language:
            for language in LanguageRegistry.menuOrder {
                let item = menu.addItem(withTitle: language.name, action: #selector(setLanguage(_:)),
                                        keyEquivalent: "")
                item.target = self
                item.representedObject = language.name
                item.state = (currentDocument?.language.name == language.name) ? .on : .off
            }
        case .encoding:
            for (group, encodings) in FileEncoding.menuGroups {
                menu.addItem(NSMenuItem.sectionHeader(title: group))
                for encoding in encodings {
                    let item = menu.addItem(withTitle: encoding.displayName,
                                            action: #selector(setEncoding(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = encoding.rawValue
                    item.state = (currentDocument?.encoding == encoding) ? .on : .off
                }
            }
        case .lineEnding:
            for ending in LineEnding.allCases {
                let item = menu.addItem(withTitle: ending.displayName,
                                        action: #selector(setLineEnding(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ending.rawValue
                item.state = (currentDocument?.lineEnding == ending) ? .on : .off
            }
        case .insertMode:
            let item = menu.addItem(withTitle: isOverwriteMode ? "Switch to Insert" : "Switch to Overwrite",
                                    action: #selector(toggleOverwrite(_:)), keyEquivalent: "")
            item.target = self
        default:
            return
        }
        menu.popUp(positioning: nil, at: point, in: bar)
    }

    // MARK: - Text transforms

    @objc func makeUpperCase(_ sender: Any?) { transformSelection(TextOps.upper) }
    @objc func makeLowerCase(_ sender: Any?) { transformSelection(TextOps.lower) }
    @objc func makeProperCase(_ sender: Any?) { transformSelection(TextOps.properCase) }
    @objc func makeSentenceCase(_ sender: Any?) { transformSelection(TextOps.sentenceCase) }
    @objc func makeInvertCase(_ sender: Any?) { transformSelection(TextOps.invertCase) }
    @objc func makeCamelCase(_ sender: Any?) { transformSelection { TextOps.camelCase($0) } }
    @objc func makeSnakeCase(_ sender: Any?) { transformSelection(TextOps.snakeCase) }

    @objc func sortAscending(_ sender: Any?) { transformSelectedLines { TextOps.sortLines($0, .ascending) } }
    @objc func sortDescending(_ sender: Any?) { transformSelectedLines { TextOps.sortLines($0, .descending) } }
    @objc func sortAscendingCaseInsensitive(_ sender: Any?) {
        transformSelectedLines { TextOps.sortLines($0, .ascendingCaseInsensitive) }
    }
    @objc func sortNumericAscending(_ sender: Any?) {
        transformSelectedLines { TextOps.sortLines($0, .ascendingNumeric) }
    }
    @objc func sortNumericDescending(_ sender: Any?) {
        transformSelectedLines { TextOps.sortLines($0, .descendingNumeric) }
    }
    @objc func reverseLines(_ sender: Any?) { transformSelectedLines { TextOps.sortLines($0, .reverse) } }
    @objc func shuffleLines(_ sender: Any?) { transformSelectedLines { TextOps.sortLines($0, .shuffle) } }

    @objc func removeDuplicateLines(_ sender: Any?) {
        transformSelectedLines { TextOps.removeDuplicateLines($0) }
    }
    @objc func removeConsecutiveDuplicateLines(_ sender: Any?) {
        transformSelectedLines(TextOps.removeConsecutiveDuplicateLines)
    }
    @objc func removeEmptyLines(_ sender: Any?) {
        transformSelectedLines { TextOps.removeEmptyLines($0) }
    }
    @objc func trimTrailingSpaces(_ sender: Any?) {
        transformSelectedLines(TextOps.trimTrailingWhitespace)
    }
    @objc func trimLeadingSpaces(_ sender: Any?) {
        transformSelectedLines(TextOps.trimLeadingWhitespace)
    }
    @objc func joinLines(_ sender: Any?) {
        transformSelectedLines { TextOps.joinLines($0) }
    }
    @objc func convertTabsToSpaces(_ sender: Any?) {
        let width = settings.tabWidth
        transformSelectedLines { TextOps.tabsToSpaces($0, width: width) }
    }
    @objc func convertSpacesToTabs(_ sender: Any?) {
        let width = settings.tabWidth
        transformSelectedLines { TextOps.leadingSpacesToTabs($0, width: width) }
    }

    @objc func duplicateLine(_ sender: Any?) {
        transformSelectedLines { $0 + "\n" + $0 }
    }

    @objc func deleteLine(_ sender: Any?) {
        guard let textView = currentTextView, let storage = textView.textStorage,
              storage.length > 0 else { return }
        let text = storage.string as NSString
        let selection = textView.selectedRange()
        var lineRange = text.lineRange(for: NSRange(location: min(selection.location, text.length),
                                                    length: min(selection.length,
                                                                text.length - min(selection.location, text.length))))
        // Deleting the last line has no trailing newline of its own to take, so
        // it takes the preceding one instead and does not leave a blank behind.
        if lineRange.location + lineRange.length >= text.length, lineRange.location > 0,
           !text.substring(with: lineRange).hasSuffix("\n") {
            lineRange = NSRange(location: lineRange.location - 1, length: lineRange.length + 1)
        }
        guard textView.shouldChangeText(in: lineRange, replacementString: "") else { return }
        storage.replaceCharacters(in: lineRange, with: "")
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: min(lineRange.location, storage.length), length: 0))
    }

    @objc func moveLineUp(_ sender: Any?) { moveLines(by: -1) }
    @objc func moveLineDown(_ sender: Any?) { moveLines(by: 1) }

    private func moveLines(by offset: Int) {
        guard let document = currentDocument, let textView = currentTextView,
              let storage = textView.textStorage, storage.length > 0 else { return }
        let index = document.lineIndex
        let selection = textView.selectedRange()
        let firstLine = index.lineIndex(containing: selection.location)
        let lastLine = index.lineIndex(containing: max(selection.location,
                                                       selection.location + selection.length - 1))
        let targetLine = offset < 0 ? firstLine - 1 : lastLine + 1
        guard targetLine >= 0, targetLine < index.lineCount else { NSSound.beep(); return }

        let blockRange = index.range(fromLine: min(firstLine, targetLine), toLine: max(lastLine, targetLine))
        let text = storage.string as NSString
        let safe = NSRange(location: blockRange.location,
                           length: min(blockRange.length, text.length - blockRange.location))
        let body = text.substring(with: safe)
        let hadTrailingNewline = body.hasSuffix("\n")
        var lines = (hadTrailingNewline ? String(body.dropLast()) : body).components(separatedBy: "\n")

        let count = lastLine - firstLine + 1
        if offset < 0 {
            let moved = Array(lines[1...count])
            lines = moved + [lines[0]]
        } else {
            let moved = Array(lines[0..<count])
            lines = [lines[count]] + moved
        }
        var updated = lines.joined(separator: "\n")
        if hadTrailingNewline { updated += "\n" }

        guard textView.shouldChangeText(in: safe, replacementString: updated) else { return }
        storage.replaceCharacters(in: safe, with: updated)
        textView.didChangeText()

        // Keep the moved block selected so the shortcut can be pressed again.
        document.lineIndex.rebuild(storage.string as NSString)
        let newFirst = firstLine + offset
        let newLast = lastLine + offset
        let newRange = document.lineIndex.range(fromLine: newFirst, toLine: newLast)
        textView.setSelectedRange(NSRange(location: newRange.location,
                                          length: max(0, newRange.length - 1)))
        currentPane?.reveal(textView.selectedRange(), select: false)
    }

    @objc func toggleComment(_ sender: Any?) {
        guard let document = currentDocument,
              let token = document.language.commentToken else { NSSound.beep(); return }
        transformSelectedLines { TextOps.toggleLineComment($0, token: token) }
    }

    @objc func indentMore(_ sender: Any?) { currentTextView?.indentSelection(by: 1) }
    @objc func indentLess(_ sender: Any?) { currentTextView?.indentSelection(by: -1) }

    @objc func base64Encode(_ sender: Any?) { transformSelection(TextOps.base64Encode) }
    @objc func base64Decode(_ sender: Any?) {
        transformSelection { TextOps.base64Decode($0) ?? $0 }
    }
    @objc func urlEncode(_ sender: Any?) { transformSelection(TextOps.urlEncode) }
    @objc func urlDecode(_ sender: Any?) { transformSelection { TextOps.urlDecode($0) ?? $0 } }
    @objc func escapeString(_ sender: Any?) { transformSelection(TextOps.escapeForCode) }
    @objc func unescapeString(_ sender: Any?) { transformSelection(TextOps.unescapeFromCode) }
    @objc func hashMD5(_ sender: Any?) { transformSelection(TextOps.md5) }
    @objc func hashSHA1(_ sender: Any?) { transformSelection(TextOps.sha1) }
    @objc func hashSHA256(_ sender: Any?) { transformSelection(TextOps.sha256) }

    @objc func showDocumentStatistics(_ sender: Any?) {
        guard let document = currentDocument, let textView = currentTextView else { return }
        let selection = textView.selectedRange()
        let target = selection.length > 0
            ? (textView.string as NSString).substring(with: selection)
            : document.text
        let stats = TextOps.stats(target)
        let alert = NSAlert()
        alert.messageText = selection.length > 0 ? "Selection summary" : "Document summary"
        alert.informativeText = """
        Characters:            \(stats.characters)
        Characters (no space): \(stats.charactersNoSpaces)
        Words:                 \(stats.words)
        Lines:                 \(stats.lines)
        Bytes (UTF-8):         \(stats.bytesUTF8)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Workspace housekeeping

    /// Show what is stale in the workspace, and remove it if the user agrees.
    @objc func cleanUpWorkspace(_ sender: Any?) {
        let live = Set(documents.map { Workspace.backupFilename(for: $0) })
        let report = SessionStore.shared.inspectForCleanup(liveBackups: live)

        let alert = NSAlert()
        guard !report.isEmpty else {
            alert.messageText = "Nothing to clean up"
            alert.informativeText = "Every file in the workspace belongs to an open tab or a recently closed one."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let size = ByteCountFormatter.string(fromByteCount: Int64(report.reclaimedBytes), countStyle: .file)
        let backups = report.orphanedBackups.count
        let closed = report.expiredClosed.count
        alert.alertStyle = .warning
        alert.messageText = "Remove \(report.totalFiles) unused file\(report.totalFiles == 1 ? "" : "s")?"
        alert.informativeText = """
        \(backups) leftover backup\(backups == 1 ? "" : "s") and \(closed) expired \
        recently-closed file\(closed == 1 ? "" : "s"), freeing about \(size).

        Nothing belonging to an open tab is touched.
        """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        SessionStore.shared.performCleanup(report)
        persistSession()
    }

    /// Empty the Recently Closed folder outright.
    @objc func clearRecentlyClosed(_ sender: Any?) {
        let count = SessionStore.shared.recentlyClosed.count
        guard count > 0 else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard \(count) recently closed tab\(count == 1 ? "" : "s")?"
        alert.informativeText = "Their text is deleted from the workspace and cannot be reopened. Open tabs are unaffected."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        SessionStore.shared.discardAllRecentlyClosed()
        persistSession()
    }

    // MARK: - Menu state

    /// Drives checkmarks and greying across every menu.
    ///
    /// Without this a toggle like Word Wrap looks identical whether it is on or
    /// off, which makes it read as missing rather than merely unticked.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        let document = currentDocument

        switch action {
        case #selector(PlusPadCommands.toggleWordWrap(_:)):
            item.state = settings.wordWrap ? .on : .off
        case #selector(PlusPadCommands.toggleInvisibles(_:)):
            item.state = settings.showInvisibles ? .on : .off
        case #selector(PlusPadCommands.toggleIndentGuides(_:)):
            item.state = settings.showIndentGuides ? .on : .off
        case #selector(PlusPadCommands.toggleLineNumbers(_:)):
            item.state = settings.showLineNumbers ? .on : .off
        case #selector(MainWindowController.toggleCurrentLineHighlight(_:)):
            item.state = settings.highlightCurrentLine ? .on : .off
        case #selector(MainWindowController.toggleFoldMargin(_:)):
            item.state = settings.showFoldMargin ? .on : .off
        case #selector(MainWindowController.toggleToolbar(_:)):
            item.state = settings.showToolbar ? .on : .off
        case #selector(MainWindowController.toggleStatusBar(_:)):
            item.state = settings.showStatusBar ? .on : .off
        case #selector(MainWindowController.toggleOverwrite(_:)):
            item.state = isOverwriteMode ? .on : .off

        case #selector(MainWindowController.selectTheme(_:)):
            item.state = (item.representedObject as? String == settings.themeName) ? .on : .off
        case #selector(MainWindowController.setEncoding(_:)):
            item.state = (item.representedObject as? String == document?.encoding.rawValue) ? .on : .off
        case #selector(MainWindowController.setLineEnding(_:)):
            item.state = (item.representedObject as? String == document?.lineEnding.rawValue) ? .on : .off
        case #selector(MainWindowController.setLanguage(_:)):
            item.state = (item.representedObject as? String == document?.language.name) ? .on : .off

        case #selector(PlusPadCommands.reopenClosedTab(_:)),
             #selector(MainWindowController.clearRecentlyClosed(_:)):
            return !SessionStore.shared.recentlyClosed.isEmpty
        case #selector(MainWindowController.revertDocument(_:)):
            return document?.hasFile == true
        case #selector(PlusPadCommands.saveDocument(_:)):
            return document.map { $0.isDirty || !$0.hasFile } ?? false
        case #selector(PlusPadCommands.saveAllDocuments(_:)):
            return documents.contains { $0.isDirty && $0.hasFile }
        case #selector(MainWindowController.toggleComment(_:)):
            return document?.language.commentToken != nil
        case #selector(PlusPadCommands.nextBookmark(_:)),
             #selector(PlusPadCommands.previousBookmark(_:)),
             #selector(PlusPadCommands.clearBookmarks(_:)):
            return !(document?.bookmarks.isEmpty ?? true)
        case #selector(MainWindowController.foldAll(_:)),
             #selector(MainWindowController.unfoldAll(_:)),
             #selector(MainWindowController.toggleFoldAtCursor(_:)):
            return !(document?.foldModel.isEmpty ?? true)
        case #selector(MainWindowController.selectNextTab(_:)),
             #selector(MainWindowController.selectPreviousTab(_:)):
            return documents.count > 1
        default:
            break
        }
        return true
    }

    // MARK: - Tab navigation

    @objc func selectNextTab(_ sender: Any?) {
        guard documents.count > 1 else { return }
        selectTab((currentIndex + 1) % documents.count)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard documents.count > 1 else { return }
        selectTab((currentIndex - 1 + documents.count) % documents.count)
    }

    @objc func selectTabByNumber(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        let index = number - 1
        if documents.indices.contains(index) { selectTab(index) }
    }
}
