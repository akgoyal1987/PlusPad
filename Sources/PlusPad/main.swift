import AppKit

/// Builds the menu bar.
///
/// The menu titles and their order are Notepad++'s -- File, Edit, Search, View,
/// Encoding, Language, Settings, Tools, Window -- rather than the Mac
/// convention, because that ordering is most of what people mean when they say
/// they know their way around the app. Key equivalents are translated to Command
/// where the Windows original used Control; the three that could not be carried
/// over verbatim are noted at their definitions.
enum MenuBuilder {

    static func build(app: NSApplication) {
        let main = NSMenu()

        main.addItem(appMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(searchMenu())
        main.addItem(viewMenu())
        main.addItem(encodingMenu())
        main.addItem(languageMenu())
        main.addItem(settingsMenu())
        main.addItem(toolsMenu())
        main.addItem(windowMenu(app: app))
        main.addItem(helpMenu())

        app.mainMenu = main
    }

    private static func container(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?,
                            _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command],
                            represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.representedObject = represented
        menu.addItem(item)
        return item
    }

    // MARK: - Menus

    private static func appMenu() -> NSMenuItem {
        container("PlusPad") { menu in
            add(menu, "About PlusPad", #selector(AppDelegate.showAbout(_:)))
            menu.addItem(.separator())
            add(menu, "Settings...", #selector(AppDelegate.showPreferences(_:)), ",")
            add(menu, "Workspace Folder...", #selector(MainWindowController.chooseWorkspace(_:)))
            menu.addItem(.separator())
            add(menu, "Hide PlusPad", #selector(NSApplication.hide(_:)), "h")
            add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
                [.command, .option])
            add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            menu.addItem(.separator())
            // Quit never asks about unsaved work; it flushes the workspace and
            // exits, and the next launch restores everything exactly.
            add(menu, "Quit PlusPad", #selector(NSApplication.terminate(_:)), "q")
        }
    }

    private static func fileMenu() -> NSMenuItem {
        container("File") { menu in
            add(menu, "New", #selector(PlusPadCommands.newDocument(_:)), "n")
            add(menu, "Open...", #selector(PlusPadCommands.openDocument(_:)), "o")

            let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            recent.submenu = NSMenu(title: "Open Recent")
            recent.submenu?.delegate = AppDelegate.shared
            recent.submenu?.identifier = NSUserInterfaceItemIdentifier("recentFiles")
            menu.addItem(recent)

            add(menu, "Reopen Closed Tab", #selector(PlusPadCommands.reopenClosedTab(_:)), "t",
                [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Save", #selector(PlusPadCommands.saveDocument(_:)), "s")
            add(menu, "Save As...", #selector(PlusPadCommands.saveDocumentAs(_:)), "s", [.command, .shift])
            add(menu, "Save All", #selector(PlusPadCommands.saveAllDocuments(_:)), "s", [.command, .option])
            menu.addItem(.separator())
            add(menu, "Reload From Disk", #selector(MainWindowController.revertDocument(_:)))
            menu.addItem(.separator())
            add(menu, "Close", #selector(PlusPadCommands.closeCurrentTab(_:)), "w")
            add(menu, "Close All", #selector(MainWindowController.closeAllDocuments(_:)), "w",
                [.command, .shift])
        }
    }

    private static func editMenu() -> NSMenuItem {
        container("Edit") { menu in
            add(menu, "Undo", Selector(("undo:")), "z")
            add(menu, "Redo", Selector(("redo:")), "z", [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Cut", #selector(NSText.cut(_:)), "x")
            add(menu, "Copy", #selector(NSText.copy(_:)), "c")
            add(menu, "Paste", #selector(NSText.paste(_:)), "v")
            add(menu, "Delete", #selector(NSText.delete(_:)))
            add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
            menu.addItem(.separator())

            add(menu, "Indent", #selector(MainWindowController.indentMore(_:)), "]")
            add(menu, "Outdent", #selector(MainWindowController.indentLess(_:)), "[")
            // Notepad++ uses Ctrl-Q; Command-/ is the near-universal Mac binding
            // for the same thing and Command-Q is unavailable.
            add(menu, "Toggle Comment", #selector(MainWindowController.toggleComment(_:)), "/")
            menu.addItem(.separator())

            menu.addItem(container("Convert Case") { sub in
                add(sub, "UPPERCASE", #selector(MainWindowController.makeUpperCase(_:)), "u",
                    [.command, .shift])
                add(sub, "lowercase", #selector(MainWindowController.makeLowerCase(_:)), "u")
                add(sub, "Proper Case", #selector(MainWindowController.makeProperCase(_:)))
                add(sub, "Sentence case", #selector(MainWindowController.makeSentenceCase(_:)))
                add(sub, "iNVERT cASE", #selector(MainWindowController.makeInvertCase(_:)))
                sub.addItem(.separator())
                add(sub, "camelCase", #selector(MainWindowController.makeCamelCase(_:)))
                add(sub, "snake_case", #selector(MainWindowController.makeSnakeCase(_:)))
            })

            menu.addItem(container("Line Operations") { sub in
                add(sub, "Duplicate Line", #selector(MainWindowController.duplicateLine(_:)), "d")
                add(sub, "Delete Line", #selector(MainWindowController.deleteLine(_:)), "l",
                    [.command, .shift])
                add(sub, "Move Line Up", #selector(MainWindowController.moveLineUp(_:)), "\u{F700}",
                    [.command, .shift])
                add(sub, "Move Line Down", #selector(MainWindowController.moveLineDown(_:)), "\u{F701}",
                    [.command, .shift])
                add(sub, "Join Lines", #selector(MainWindowController.joinLines(_:)), "j")
                sub.addItem(.separator())
                add(sub, "Sort Ascending", #selector(MainWindowController.sortAscending(_:)))
                add(sub, "Sort Descending", #selector(MainWindowController.sortDescending(_:)))
                add(sub, "Sort Ascending, Ignoring Case",
                    #selector(MainWindowController.sortAscendingCaseInsensitive(_:)))
                add(sub, "Sort Numerically, Ascending",
                    #selector(MainWindowController.sortNumericAscending(_:)))
                add(sub, "Sort Numerically, Descending",
                    #selector(MainWindowController.sortNumericDescending(_:)))
                add(sub, "Reverse Line Order", #selector(MainWindowController.reverseLines(_:)))
                add(sub, "Shuffle Lines", #selector(MainWindowController.shuffleLines(_:)))
                sub.addItem(.separator())
                add(sub, "Remove Duplicate Lines",
                    #selector(MainWindowController.removeDuplicateLines(_:)))
                add(sub, "Remove Consecutive Duplicate Lines",
                    #selector(MainWindowController.removeConsecutiveDuplicateLines(_:)))
                add(sub, "Remove Empty Lines", #selector(MainWindowController.removeEmptyLines(_:)))
            })

            menu.addItem(container("Blank Operations") { sub in
                add(sub, "Trim Trailing Space", #selector(MainWindowController.trimTrailingSpaces(_:)))
                add(sub, "Trim Leading Space", #selector(MainWindowController.trimLeadingSpaces(_:)))
                sub.addItem(.separator())
                add(sub, "TAB to Space", #selector(MainWindowController.convertTabsToSpaces(_:)))
                add(sub, "Leading Space to TAB", #selector(MainWindowController.convertSpacesToTabs(_:)))
            })
        }
    }

    private static func searchMenu() -> NSMenuItem {
        container("Search") { menu in
            add(menu, "Find...", #selector(PlusPadCommands.showFind(_:)), "f")
            add(menu, "Find Next", #selector(PlusPadCommands.findNext(_:)), "g")
            add(menu, "Find Previous", #selector(PlusPadCommands.findPrevious(_:)), "g", [.command, .shift])
            add(menu, "Use Selection for Find", #selector(MainWindowController.findSelectionNext(_:)),
                "e")
            menu.addItem(.separator())
            // Notepad++ uses Ctrl-H. Command-H is reserved by macOS for Hide, so
            // Replace takes the Mac convention instead.
            add(menu, "Replace...", #selector(PlusPadCommands.showReplace(_:)), "f", [.command, .option])
            add(menu, "Find in Files...", #selector(PlusPadCommands.showFindInFiles(_:)), "f",
                [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Go to Line...", #selector(PlusPadCommands.goToLine(_:)), "l")
            menu.addItem(.separator())
            add(menu, "Toggle Bookmark", #selector(PlusPadCommands.toggleBookmark(_:)), "\u{F70B}")
            add(menu, "Next Bookmark", #selector(PlusPadCommands.nextBookmark(_:)), "\u{F70B}", [.function])
            add(menu, "Previous Bookmark", #selector(PlusPadCommands.previousBookmark(_:)), "\u{F70B}",
                [.function, .shift])
            add(menu, "Clear All Bookmarks", #selector(PlusPadCommands.clearBookmarks(_:)))
        }
    }

    private static func viewMenu() -> NSMenuItem {
        container("View") { menu in
            add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f",
                [.command, .control])
            menu.addItem(.separator())
            add(menu, "Zoom In", #selector(PlusPadCommands.zoomIn(_:)), "+")
            add(menu, "Zoom Out", #selector(PlusPadCommands.zoomOut(_:)), "-")
            add(menu, "Restore Default Zoom", #selector(PlusPadCommands.zoomReset(_:)), "0")
            menu.addItem(.separator())
            add(menu, "Word Wrap", #selector(PlusPadCommands.toggleWordWrap(_:)))
            add(menu, "Show Line Numbers", #selector(PlusPadCommands.toggleLineNumbers(_:)))
            add(menu, "Show Indent Guide", #selector(PlusPadCommands.toggleIndentGuides(_:)))
            add(menu, "Show All Characters", #selector(PlusPadCommands.toggleInvisibles(_:)))
            add(menu, "Highlight Current Line",
                #selector(MainWindowController.toggleCurrentLineHighlight(_:)))
            add(menu, "Show Fold Margin", #selector(MainWindowController.toggleFoldMargin(_:)))
            menu.addItem(.separator())
            add(menu, "Fold All", #selector(MainWindowController.foldAll(_:)), "0", [.command, .option])
            add(menu, "Unfold All", #selector(MainWindowController.unfoldAll(_:)), "9",
                [.command, .option])
            add(menu, "Toggle Fold", #selector(MainWindowController.toggleFoldAtCursor(_:)), "8",
                [.command, .option])
            menu.addItem(.separator())
            add(menu, "Show Toolbar", #selector(MainWindowController.toggleToolbar(_:)))
            add(menu, "Show Status Bar", #selector(MainWindowController.toggleStatusBar(_:)))
            add(menu, "Markdown Preview",
                #selector(MainWindowController.toggleMarkdownPreview(_:)), "m",
                [.command, .shift])
            add(menu, "Search Results",
                #selector(MainWindowController.toggleSearchResults(_:)), "r",
                [.command, .shift])
            menu.addItem(.separator())
            menu.addItem(container("Theme") { sub in
                for theme in Theme.all {
                    add(sub, theme.name, #selector(MainWindowController.selectTheme(_:)),
                        represented: theme.name)
                }
            })
        }
    }

    private static func encodingMenu() -> NSMenuItem {
        container("Encoding") { menu in
            let note = NSMenuItem(title: "Convert the text to:", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            for (group, encodings) in FileEncoding.menuGroups {
                for encoding in encodings {
                    add(menu, "    " + encoding.displayName,
                        #selector(MainWindowController.setEncoding(_:)),
                        represented: encoding.rawValue)
                }
                if group != FileEncoding.menuGroups.last?.0 { menu.addItem(.separator()) }
            }
            menu.addItem(.separator())
            // Reinterpreting re-reads the bytes; converting keeps the characters
            // and changes how they will be written. Conflating the two is the
            // classic way to turn an accented file into mojibake.
            menu.addItem(container("Reopen With Encoding") { sub in
                for (_, encodings) in FileEncoding.menuGroups {
                    for encoding in encodings {
                        add(sub, encoding.displayName,
                            #selector(MainWindowController.reinterpretEncoding(_:)),
                            represented: encoding.rawValue)
                    }
                    sub.addItem(.separator())
                }
            })
            menu.addItem(.separator())
            for ending in LineEnding.allCases {
                add(menu, "Line Endings: " + ending.displayName,
                    #selector(MainWindowController.setLineEnding(_:)),
                    represented: ending.rawValue)
            }
        }
    }

    private static func languageMenu() -> NSMenuItem {
        container("Language") { menu in
            for language in LanguageRegistry.menuOrder {
                add(menu, language.name, #selector(MainWindowController.setLanguage(_:)),
                    represented: language.name)
                if language.name == LanguageRegistry.plainText.name { menu.addItem(.separator()) }
            }
        }
    }

    private static func settingsMenu() -> NSMenuItem {
        container("Settings") { menu in
            add(menu, "Preferences...", #selector(AppDelegate.showPreferences(_:)))
            add(menu, "Choose Editor Font...", #selector(MainWindowController.chooseFont(_:)))
            menu.addItem(.separator())
            add(menu, "Workspace Folder...", #selector(MainWindowController.chooseWorkspace(_:)))
            add(menu, "Reveal Workspace in Finder", #selector(PlusPadCommands.revealWorkspace(_:)))
            menu.addItem(.separator())
            add(menu, "Clean Up Workspace...", #selector(MainWindowController.cleanUpWorkspace(_:)))
            add(menu, "Clear Recently Closed...", #selector(MainWindowController.clearRecentlyClosed(_:)))
        }
    }

    private static func toolsMenu() -> NSMenuItem {
        container("Tools") { menu in
            add(menu, "Summary...", #selector(MainWindowController.showDocumentStatistics(_:)))
            menu.addItem(.separator())
            menu.addItem(container("Base64") { sub in
                add(sub, "Encode Selection", #selector(MainWindowController.base64Encode(_:)))
                add(sub, "Decode Selection", #selector(MainWindowController.base64Decode(_:)))
            })
            menu.addItem(container("URL") { sub in
                add(sub, "Encode Selection", #selector(MainWindowController.urlEncode(_:)))
                add(sub, "Decode Selection", #selector(MainWindowController.urlDecode(_:)))
            })
            menu.addItem(container("Escape") { sub in
                add(sub, "Escape Selection", #selector(MainWindowController.escapeString(_:)))
                add(sub, "Unescape Selection", #selector(MainWindowController.unescapeString(_:)))
            })
            menu.addItem(container("Hash") { sub in
                add(sub, "MD5 of Selection", #selector(MainWindowController.hashMD5(_:)))
                add(sub, "SHA-1 of Selection", #selector(MainWindowController.hashSHA1(_:)))
                add(sub, "SHA-256 of Selection", #selector(MainWindowController.hashSHA256(_:)))
            })
        }
    }

    private static func windowMenu(app: NSApplication) -> NSMenuItem {
        let item = container("Window") { menu in
            // Control-Tab is what Notepad++ uses and it is free on macOS.
            add(menu, "Next Tab", #selector(MainWindowController.selectNextTab(_:)), "\t", [.control])
            add(menu, "Previous Tab", #selector(MainWindowController.selectPreviousTab(_:)), "\t",
                [.control, .shift])
            menu.addItem(.separator())
            add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
            menu.addItem(.separator())
            // Filled in by the delegate each time the menu opens: the entries are
            // the open documents by name, which is what Notepad++ lists here.
            let placeholder = NSMenuItem(title: "No Documents", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        }
        item.submenu?.delegate = AppDelegate.shared
        item.submenu?.identifier = NSUserInterfaceItemIdentifier("windowDocuments")
        // Deliberately not assigned as `app.windowsMenu`: AppKit would append its
        // own window entries and fight the document list.
        return item
    }

    private static func helpMenu() -> NSMenuItem {
        container("Help") { menu in
            add(menu, "About PlusPad", #selector(AppDelegate.showAbout(_:)))
            add(menu, "Open Workspace README", #selector(AppDelegate.openWorkspaceReadme(_:)))
        }
    }
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    static let shared = AppDelegate()
    private var mainWindow: MainWindowController?
    private var preferences: PreferencesController?
    /// Files requested before the window was ready.
    private var pendingOpens: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = Workspace.shared
        workspace.takeLock()
        if !workspace.hasBeenConfigured {
            promptForWorkspace()
        }

        let controller = MainWindowController()
        mainWindow = controller
        controller.restoreSession()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        if !pendingOpens.isEmpty {
            for url in pendingOpens { controller.open(url: url) }
            pendingOpens.removeAll()
        }
        // Write the session immediately rather than waiting for the first edit,
        // so a crash seconds after launch still restores the right tabs.
        controller.persistSession()
        NSApp.activate(ignoringOtherApps: true)

        // Deferred a turn so the window has actually drawn behind the alert.
        DispatchQueue.main.async { controller.reportPendingRecoveryIfNeeded() }

        // PLUSPAD_DIAG=1 runs the app as a one-shot render probe: it draws the
        // window, writes the view tree and a PNG of what actually rendered, and
        // quits. It exists because the app can screenshot itself without the
        // Screen Recording permission that `screencapture` needs, which is the
        // only way to check the UI from a terminal session.
        if SelfTest.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let report = SelfTest.run(controller)
                try? report.write(to: URL(fileURLWithPath: "/tmp/pluspad-selftest.log"),
                                  atomically: true, encoding: .utf8)
                exit(report.contains("FAILED") ? 1 : 0)
            }
            return
        }

        if Diagnostics.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                // PLUSPAD_DIAG_FIND=1 captures the Find panel instead of the
                // main window, which is otherwise unreachable headlessly.
                if ProcessInfo.processInfo.environment["PLUSPAD_DIAG_FIND"] == "1" {
                    controller.showFind(nil)
                    Diagnostics.capture(controller.findController?.window,
                                        to: "/tmp/pluspad-find.png")
                    exit(0)
                }
                // PLUSPAD_DIAG_OPEN=<path> opens that file before capturing.
                // PLUSPAD_DIAG_PREVIEW=1 shows the Markdown preview beside it
                // and PLUSPAD_DIAG_SEARCH=<term> runs Find All in it, so the
                // two surfaces that cannot be reached headlessly -- the
                // rendered pane and the results dock -- can still be seen.
                let environment = ProcessInfo.processInfo.environment
                if let path = environment["PLUSPAD_DIAG_OPEN"] {
                    _ = controller.open(url: URL(fileURLWithPath: path))
                    if environment["PLUSPAD_DIAG_PREVIEW"] == "1" {
                        controller.settings.showMarkdownPreview = true
                        controller.updateMarkdownPreview()
                    }
                    if let term = environment["PLUSPAD_DIAG_SEARCH"] {
                        controller.showFind(nil)
                        controller.findController?.show(tab: .find, seedingFromSelection: false)
                        controller.findController?.setSearchTextForTesting(term)
                        controller.findController?.findAll()
                        controller.findController?.close()
                    }
                    controller.window?.layoutIfNeeded()
                    // The pane restores its scroll position one turn after the
                    // document is installed, so a capture in this same turn
                    // photographs the state before that has happened.
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                    controller.window?.layoutIfNeeded()
                    Diagnostics.capture(controller.window, to: "/tmp/pluspad-probe.png")
                    exit(0)
                }
                Diagnostics.dump(controller.window, label: "render probe")
                Diagnostics.note(Diagnostics.auditActions(app: NSApp, window: controller.window))
                Diagnostics.capture(controller.window, to: "/tmp/pluspad-render.png")
                exit(0)
            }
        }
    }

    /// One-time question at first launch.
    ///
    /// Asked rather than assumed because the folder is where unsaved work will
    /// live, and someone who wants it in a synced or backed-up location needs to
    /// say so before there is anything in it to lose.
    private func promptForWorkspace() {
        let alert = NSAlert()
        alert.messageText = "Where should PlusPad keep your work?"
        alert.informativeText = """
        PlusPad never asks you to save. Unsaved tabs, closed tabs and your \
        session are written continuously to a workspace folder, so they survive \
        quitting, crashing, and losing power -- and you can recover them from the \
        Finder without opening PlusPad at all.

        Default location:
        \(Workspace.defaultRoot.path)
        """
        alert.addButton(withTitle: "Use Default Location")
        alert.addButton(withTitle: "Choose Folder...")

        if alert.runModal() == .alertSecondButtonReturn {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Use This Folder"
            panel.message = "PlusPad will create a folder called PlusPad inside your choice."
            if panel.runModal() == .OK, let chosen = panel.url {
                let target = chosen.lastPathComponent == "PlusPad"
                    ? chosen : chosen.appendingPathComponent("PlusPad", isDirectory: true)
                try? Workspace.shared.relocate(to: target)
                SessionStore.shared.loadSettings()
            }
        }
        Workspace.shared.hasBeenConfigured = true
        try? Workspace.shared.prepare()
    }

    /// Quitting is unconditional. There is nothing to confirm because nothing
    /// is lost: the flush below writes every buffer, and the next launch brings
    /// them all back.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainWindow?.flushNow()
        Workspace.shared.releaseLock()
        return .terminateNow
    }

    func applicationDidResignActive(_ notification: Notification) {
        mainWindow?.flushNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files opened from the Finder, the Dock, or `open -a`.
    ///
    /// Both variants are implemented on purpose. Modern macOS calls
    /// `application(_:open:)` and never calls the `openFiles` form, which is why
    /// only implementing the latter silently drops every file the user
    /// double-clicks.
    func application(_ application: NSApplication, open urls: [URL]) {
        openAll(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openAll(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    private func openAll(_ urls: [URL]) {
        guard let window = mainWindow else {
            // The event can arrive before the window exists on a cold launch;
            // hold the files and open them once it does.
            pendingOpens.append(contentsOf: urls)
            return
        }
        for url in urls { window.open(url: url) }
        window.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.window?.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: - Menu upkeep

    /// The Open Recent submenu is rebuilt each time it opens rather than kept in
    /// sync, which is both simpler and always correct.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier?.rawValue == "windowDocuments" {
            rebuildWindowMenu(menu)
            return
        }
        guard menu.identifier?.rawValue == "recentFiles" else { return }
        menu.removeAllItems()
        let recents = SessionStore.shared.settings.recentFiles
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for path in recents {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent,
                                  action: #selector(MainWindowController.openRecentFile(_:)),
                                  keyEquivalent: "")
            item.toolTip = path
            item.representedObject = path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear Menu",
                                action: #selector(MainWindowController.clearRecentFiles(_:)),
                                keyEquivalent: ""))
    }

    /// Replace everything after the last separator with the open documents.
    private func rebuildWindowMenu(_ menu: NSMenu) {
        guard let controller = mainWindow else { return }
        let keep = (menu.items.lastIndex { $0.isSeparatorItem } ?? -1) + 1
        while menu.items.count > keep { menu.removeItem(at: menu.items.count - 1) }

        guard !controller.documents.isEmpty else {
            let empty = NSMenuItem(title: "No Documents", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for (index, document) in controller.documents.enumerated() {
            let marker = document.isDirty ? " *" : ""
            let entry = NSMenuItem(title: document.displayName + marker,
                                   action: #selector(MainWindowController.selectTabByNumber(_:)),
                                   keyEquivalent: index < 9 ? "\(index + 1)" : "")
            if index < 9 { entry.keyEquivalentModifierMask = [.command] }
            entry.representedObject = index + 1
            entry.state = (index == controller.currentIndex) ? .on : .off
            entry.toolTip = document.fileURL?.path ?? "Not saved to a file"
            menu.addItem(entry)
        }
    }

    @objc func showPreferences(_ sender: Any?) {
        guard let controller = mainWindow else { return }
        if preferences == nil { preferences = PreferencesController(host: controller) }
        preferences?.showWindow(nil)
        preferences?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openWorkspaceReadme(_ sender: Any?) {
        mainWindow?.open(url: Workspace.shared.readmeFile)
    }

    @objc func showAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "PlusPad"
        alert.informativeText = """
        A Notepad++-style text editor for macOS.

        Tabs, syntax highlighting, regular-expression find and replace, find in \
        files, encoding and line-ending control, and line tools.

        Nothing is ever lost to a missed save: every buffer is mirrored \
        continuously into the workspace folder, and closing a tab parks it in \
        Recently Closed rather than discarding it.

        Workspace:
        \(Workspace.shared.root.path)
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Workspace")
        if alert.runModal() == .alertSecondButtonReturn {
            Workspace.shared.revealInFinder()
        }
    }
}

// Must be set before the first NSTextView is built, or press-and-hold has
// already been consulted and holding a key shows the diacritic popup rather than
// repeating the character.
UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = AppDelegate.shared
application.delegate = delegate
MenuBuilder.build(app: application)
application.run()
