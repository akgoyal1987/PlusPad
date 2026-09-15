import AppKit

/// Drives the real menu commands against a real window and checks what they did.
///
/// The action audit proves every menu item is wired to something that exists.
/// That is not the same as the item doing the right thing, and the gap between
/// those two is where a command that quietly converts the wrong document, or
/// flips a setting without applying it, would live. This closes it for
/// everything that can run without a modal panel.
///
/// Run with PLUSPAD_SELFTEST=1. Commands that open a panel or an alert -- Save
/// As, Go to Line, Clean Up Workspace, Choose Workspace, Reload From Disk --
/// block on a modal and are listed as needing a person instead.
enum SelfTest {

    static var isEnabled: Bool { ProcessInfo.processInfo.environment["PLUSPAD_SELFTEST"] == "1" }

    private static var failures = 0
    private static var checks = 0
    private static var log = ""

    private static func check(_ condition: Bool, _ label: String,
                              _ detail: @autoclosure () -> String = "") {
        checks += 1
        if condition {
            log += "  ok    \(label)\n"
        } else {
            failures += 1
            let extra = detail()
            log += "  FAIL  \(label)\(extra.isEmpty ? "" : "\n          " + extra)\n"
        }
    }

    private static func section(_ name: String) { log += "\n\(name)\n" }

    // MARK: - Runner

    static func run(_ host: MainWindowController) -> String {
        failures = 0; checks = 0; log = "===== self test =====\n"

        // The test closes tabs, flips settings and writes backups. Running that
        // against somebody's real workspace would throw away their open
        // documents, so it only proceeds in a throwaway one.
        guard Workspace.shared.isOverridden else {
            return log + """
            REFUSED: this test mutates the workspace it runs against.
            Set PLUSPAD_WORKSPACE to a throwaway directory first, or use
            ./run-selftest.sh which does it for you.
            """
        }

        // Start from a known state: one buffer whose contents we control.
        while host.documents.count > 1 { host.closeTab(at: host.documents.count - 1, archive: false) }
        let document = host.currentDocument!
        let editor = host.currentTextView!

        func setText(_ text: String) {
            document.replaceAllText(text)
            document.lineIndex.rebuild(text as NSString)
            editor.rebuildBaseAttributes()
            editor.recomputeFolds()
            editor.setSelectedRange(NSRange(location: 0, length: 0))
        }
        func selectAll() {
            editor.setSelectedRange(NSRange(location: 0, length: document.textStorage.length))
        }
        var text: String { document.textStorage.string }

        section("Encoding menu")
        for encoding in [FileEncoding.utf16LE, .windows1252, .utf8BOM, .utf8] {
            let item = NSMenuItem()
            item.representedObject = encoding.rawValue
            host.setEncoding(item)
            check(document.encoding == encoding, "convert to \(encoding.displayName)",
                  "document reports \(document.encoding.displayName)")
        }

        section("Line ending menu")
        for ending in [LineEnding.crlf, .cr, .lf] {
            let item = NSMenuItem()
            item.representedObject = ending.rawValue
            host.setLineEnding(item)
            check(document.lineEnding == ending, "convert to \(ending.displayName)")
        }
        setText("a\nb\n")
        document.convert(to: .crlf)
        let written = TextCodec.encode(text, as: .utf8, lineEnding: document.lineEnding)
        check(String(data: written!, encoding: .utf8) == "a\r\nb\r\n",
              "CRLF is applied on write, not held in the buffer")

        section("Language menu")
        for name in ["Python", "JSON", "Swift", "Plain Text"] {
            let item = NSMenuItem()
            item.representedObject = name
            host.setLanguage(item)
            check(document.language.name == name, "select \(name)")
            check(document.languageIsExplicit, "choosing a language marks it explicit")
        }
        setText("def f():\n    return 1\n")
        let pythonItem = NSMenuItem(); pythonItem.representedObject = "Python"
        host.setLanguage(pythonItem)
        let tokens = document.highlighter.tokens(in: text as NSString, index: document.lineIndex,
                                                 firstLine: 0, lastLine: 1)
        check(tokens.contains { $0.kind == .keyword }, "the chosen language actually highlights")

        section("Edit > Convert Case")
        setText("hello world"); selectAll(); host.makeUpperCase(nil)
        check(text == "HELLO WORLD", "UPPERCASE", text)
        selectAll(); host.makeLowerCase(nil)
        check(text == "hello world", "lowercase", text)
        selectAll(); host.makeProperCase(nil)
        check(text == "Hello World", "Proper Case", text)
        selectAll(); host.makeInvertCase(nil)
        check(text == "hELLO wORLD", "iNVERT cASE", text)

        section("Edit > Line Operations")
        setText("c\na\nb"); selectAll(); host.sortAscending(nil)
        check(text == "a\nb\nc", "Sort Ascending", text)
        selectAll(); host.reverseLines(nil)
        check(text == "c\nb\na", "Reverse Line Order", text)
        setText("a\na\nb"); selectAll(); host.removeDuplicateLines(nil)
        check(text == "a\nb", "Remove Duplicate Lines", text)
        setText("x  \ny\t"); selectAll(); host.trimTrailingSpaces(nil)
        check(text == "x\ny", "Trim Trailing Space", text)

        setText("one\ntwo\n")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        host.duplicateLine(nil)
        check(text.hasPrefix("one\none"), "Duplicate Line", text)
        setText("one\ntwo\nthree\n")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        host.deleteLine(nil)
        check(text == "two\nthree\n", "Delete Line", text)
        setText("one\ntwo\nthree\n")
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        host.moveLineUp(nil)
        check(text.hasPrefix("two\none"), "Move Line Up", text)

        section("Edit > Toggle Comment")
        setText("x = 1\ny = 2")
        let py = NSMenuItem(); py.representedObject = "Python"
        host.setLanguage(py)
        selectAll(); host.toggleComment(nil)
        check(text.contains("# x = 1"), "comment inserted", text)
        selectAll(); host.toggleComment(nil)
        check(text == "x = 1\ny = 2", "uncomment round-trips", text)

        section("Tools")
        setText("hello"); selectAll(); host.base64Encode(nil)
        check(text == "aGVsbG8=", "Base64 encode", text)
        selectAll(); host.base64Decode(nil)
        check(text == "hello", "Base64 decode", text)
        setText("abc"); selectAll(); host.hashMD5(nil)
        check(text == "900150983cd24fb0d6963f7d28e17f72", "MD5", text)

        section("View menu toggles")
        let wrapWas = host.settings.wordWrap
        host.toggleWordWrap(nil)
        check(host.settings.wordWrap != wrapWas, "Word Wrap flips the setting")
        check(host.currentTextView?.textContainer?.widthTracksTextView == host.settings.wordWrap,
              "Word Wrap reaches the text container")
        host.toggleWordWrap(nil)
        check(host.settings.wordWrap == wrapWas, "Word Wrap toggles back")

        let sizeWas = host.settings.fontSize
        host.zoomIn(nil)
        check(host.settings.fontSize == sizeWas + 1, "Zoom In")
        host.zoomOut(nil)
        check(host.settings.fontSize == sizeWas, "Zoom Out")
        host.zoomReset(nil)
        check(host.settings.fontSize == 13, "Restore Default Zoom")

        for (label, toggle, read) in [
            ("Show Line Numbers", { host.toggleLineNumbers(nil) }, { host.settings.showLineNumbers }),
            ("Show All Characters", { host.toggleInvisibles(nil) }, { host.settings.showInvisibles }),
            ("Show Indent Guide", { host.toggleIndentGuides(nil) }, { host.settings.showIndentGuides }),
            ("Show Fold Margin", { host.toggleFoldMargin(nil) }, { host.settings.showFoldMargin }),
        ] as [(String, () -> Void, () -> Bool)] {
            let before = read()
            toggle()
            check(read() != before, "\(label) flips")
            toggle()
            check(read() == before, "\(label) restores")
        }

        section("Bookmarks")
        setText("1\n2\n3\n4\n")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        host.toggleBookmark(nil)
        check(document.bookmarks.contains(0), "Toggle Bookmark sets one")
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        host.toggleBookmark(nil)
        host.nextBookmark(nil)
        check(!document.bookmarks.isEmpty, "Next Bookmark runs with marks present")
        host.clearBookmarks(nil)
        check(document.bookmarks.isEmpty, "Clear All Bookmarks")

        section("Folding")
        setText("def f():\n    a = 1\n    b = 2\ndef g():\n    c = 3\n")
        editor.recomputeFolds()
        check(document.foldModel.isHeader(0), "line 1 is a fold header")
        check(document.foldModel.regionEnd(for: 0) == 2, "region covers the indented body",
              "ends at \(document.foldModel.regionEnd(for: 0))")
        host.foldAll(nil)
        check(document.foldModel.isHidden(1), "Fold All hides the body")
        check(!editor.hiddenRanges.isEmpty, "folded ranges reach the layout manager")
        check(document.textStorage.length == (text as NSString).length,
              "folding does not remove any text")
        host.unfoldAll(nil)
        check(!document.foldModel.isHidden(1), "Unfold All reveals it")
        check(editor.hiddenRanges.isEmpty, "layout manager is cleared")

        section("Search")
        setText("alpha beta alpha gamma alpha")
        let plain = SearchQuery(pattern: "alpha", options: SearchOptions())
        let ns = text as NSString
        let hits = FindEngine.matches(of: plain, in: ns,
                                      range: NSRange(location: 0, length: ns.length))
        check(hits.count == 3, "find counts every occurrence", "got \(hits.count)")
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        host.findSelectionNext(nil)
        check(editor.selectedRange().location == 11, "Use Selection for Find advances",
              "landed at \(editor.selectedRange().location)")

        let storage = NSMutableString(string: text)
        let replaced = FindEngine.replaceAll(plain, template: "X", in: storage,
                                             range: NSRange(location: 0, length: storage.length))
        check(replaced == 3 && storage as String == "X beta X gamma X",
              "replace all rewrites every hit", storage as String)

        // Revealing a hit must move the document vertically and not one pixel
        // sideways. With the gutter showing, the clip view rests at a negative
        // bounds origin (the ruler is paid for out of it), so code that scrolls
        // to a literal x of 0 slides the text out from under the gutter -- which
        // is what every Find Next did until the origin was read back from
        // `constrainBoundsRect` instead of being assumed to be zero.
        if let pane = host.currentPane {
            setText((1...400).map { "line \($0) padding padding padding" }
                        .joined(separator: "\n") + "\nneedle at the very bottom")
            let restingX = pane.scrollView.contentView.bounds.origin.x
            let top = pane.scrollView.contentView.bounds.origin.y
            let needle = (text as NSString).range(of: "needle")
            pane.reveal(needle)
            let afterX = pane.scrollView.contentView.bounds.origin.x
            let afterY = pane.scrollView.contentView.bounds.origin.y
            check(afterX == restingX, "revealing a hit does not scroll sideways",
                  "x moved \(restingX) -> \(afterX)")
            check(afterY > top, "revealing an off-screen hit scrolls down to it",
                  "y stayed at \(afterY)")
            pane.reveal((text as NSString).range(of: "line 1 padding"))
            check(pane.scrollView.contentView.bounds.origin.x == restingX,
                  "scrolling back to the top does not scroll sideways either",
                  "x is \(pane.scrollView.contentView.bounds.origin.x)")
        }

        section("Tabs and recovery")
        let before = host.documents.count
        host.newDocument(nil)
        check(host.documents.count == before + 1, "New opens a tab")
        host.currentDocument?.replaceAllText("scratch text that was never saved")
        host.currentDocument?.noteTextChanged()
        check(host.currentDocument?.isDirty == true, "an untitled buffer with text is unsaved")
        host.closeCurrentTab(nil)
        check(host.documents.count == before, "Close removes it")
        check(!SessionStore.shared.recentlyClosed.isEmpty,
              "closing an unsaved tab parks it in Recently Closed rather than discarding it")
        host.reopenClosedTab(nil)
        check(host.currentDocument?.text == "scratch text that was never saved",
              "Reopen Closed Tab restores the exact text",
              host.currentDocument?.text ?? "nil")
        host.closeCurrentTab(nil)

        section("Find panel")
        let panel = FindPanelController(host: host)
        panel.show(tab: .find, seedingFromSelection: false)
        for (name, control) in panel.requiredControls {
            check(control.superview != nil, "\(name) is in the panel",
                  "control has no superview, so it never appears")
        }
        check(panel.visibleActionButtonTitles.contains("Find Next"), "Find mode shows Find Next",
              panel.visibleActionButtonTitles.joined(separator: ", "))
        check(panel.visibleActionButtonTitles.contains("Find All in All Files"),
              "Find mode shows Find All in All Files")
        panel.show(tab: .replace, seedingFromSelection: false)
        check(panel.visibleActionButtonTitles.contains("Replace All"), "Replace mode shows Replace All",
              panel.visibleActionButtonTitles.joined(separator: ", "))
        panel.show(tab: .findInFiles, seedingFromSelection: false)
        check(panel.visibleActionButtonTitles.contains("Find All"), "Find in Files shows Find All")
        check(panel.window?.hidesOnDeactivate == true,
              "the panel hides when PlusPad is not the active app")

        // Drive a real find through the panel's own field.
        setText("alpha beta alpha")
        panel.show(tab: .find, seedingFromSelection: false)
        panel.setSearchTextForTesting("alpha")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        panel.findNext()
        check(editor.selectedRange().length == 5, "Find Next from the panel selects a match",
              "selected \(editor.selectedRange())")
        panel.show(tab: .replace, seedingFromSelection: false)
        panel.setSearchTextForTesting("alpha")
        panel.setReplaceTextForTesting("ZZ")
        panel.replaceAll()
        check(text == "ZZ beta ZZ", "Replace All from the panel rewrites the document", text)
        panel.close()

        section("New and untitled files, Notepad++ behaviour")
        // Notepad++ names fresh buffers "new 1", "new 2", and the counter only
        // ever goes up: a number belonging to a closed tab is never handed out
        // again, so two tabs can never share a name.
        while host.documents.count > 1 { host.closeTab(at: host.documents.count - 1, archive: false) }
        host.newDocument(nil)
        let firstNew = host.currentDocument?.displayName ?? ""
        host.newDocument(nil)
        let secondNew = host.currentDocument?.displayName ?? ""
        check(firstNew.hasPrefix("new ") && secondNew.hasPrefix("new "),
              "a fresh buffer is called \"new N\"", "got \(firstNew) then \(secondNew)")
        check(firstNew != secondNew, "two new buffers never share a name",
              "both were \(firstNew)")
        let firstNumber = Int(firstNew.dropFirst(4)) ?? -1
        let secondNumber = Int(secondNew.dropFirst(4)) ?? -1
        check(secondNumber == firstNumber + 1, "the counter goes up by one",
              "\(firstNumber) then \(secondNumber)")

        // Closing the newest tab and making another must not reuse its number.
        host.closeTab(at: host.documents.count - 1, archive: false)
        host.newDocument(nil)
        let thirdNumber = Int((host.currentDocument?.displayName ?? "").dropFirst(4)) ?? -1
        check(thirdNumber > secondNumber, "a closed tab's number is never reused",
              "reused \(thirdNumber) after \(secondNumber)")

        // An untouched empty buffer has nothing to lose, so it is not dirty and
        // closing it puts nothing in Recently Closed.
        let virgin = host.currentDocument!
        check(!virgin.isDirty, "a brand new empty buffer is not modified")
        let closedBefore = SessionStore.shared.recentlyClosed.count
        host.closeTab(at: host.documents.firstIndex(where: { $0 === virgin })!)
        check(SessionStore.shared.recentlyClosed.count == closedBefore,
              "closing an empty untouched buffer archives nothing",
              "Recently Closed grew to \(SessionStore.shared.recentlyClosed.count)")

        // Typing into one makes it modified, exactly as in Notepad++.
        host.newDocument(nil)
        host.currentDocument?.replaceAllText("x")
        check(host.currentDocument?.isDirty == true, "typing marks the buffer modified")
        host.closeTab(at: host.documents.count - 1)

        // Opening a file when the only tab is an untouched empty buffer replaces
        // it rather than opening beside it -- Notepad++ does not leave "new 1"
        // sitting next to the file you just opened.
        while host.documents.count > 1 { host.closeTab(at: host.documents.count - 1, archive: false) }
        let sample = Workspace.shared.root.appendingPathComponent("selftest-open.txt")
        try? "opened from disk".write(to: sample, atomically: true, encoding: .utf8)
        if host.currentDocument?.hasFile == true || host.currentDocument?.isDirty == true {
            host.newDocument(nil)
            while host.documents.count > 1 { host.closeTab(at: 0, archive: false) }
        }
        let tabsBeforeOpen = host.documents.count
        host.open(url: sample)
        check(host.documents.count == tabsBeforeOpen,
              "opening a file replaces a single untouched empty buffer",
              "went from \(tabsBeforeOpen) tabs to \(host.documents.count)")
        check(host.currentDocument?.displayName == "selftest-open.txt",
              "the opened file is the tab that is showing",
              host.currentDocument?.displayName ?? "none")

        // But a buffer with something in it is never thrown away for a file.
        host.newDocument(nil)
        host.currentDocument?.replaceAllText("do not lose me")
        let tabsBeforeSecondOpen = host.documents.count
        let sample2 = Workspace.shared.root.appendingPathComponent("selftest-open-2.txt")
        try? "second file".write(to: sample2, atomically: true, encoding: .utf8)
        host.open(url: sample2)
        check(host.documents.count == tabsBeforeSecondOpen + 1,
              "opening a file never replaces a buffer that has text in it",
              "tabs went \(tabsBeforeSecondOpen) -> \(host.documents.count)")

        // Opening a file that is already open focuses its tab instead of
        // opening a duplicate.
        let tabsBeforeReopen = host.documents.count
        host.open(url: sample)
        check(host.documents.count == tabsBeforeReopen,
              "opening an already-open file focuses its tab rather than duplicating it",
              "tabs went \(tabsBeforeReopen) -> \(host.documents.count)")
        check(host.currentDocument?.displayName == "selftest-open.txt",
              "and brings that tab to the front")

        // The window never ends up with no tabs at all.
        while host.documents.count > 1 { host.closeTab(at: host.documents.count - 1, archive: false) }
        host.closeTab(at: 0, archive: false)
        check(host.documents.count == 1, "closing the last tab leaves a fresh empty one",
              "left \(host.documents.count) tabs")
        check(host.currentDocument?.hasFile == false && host.currentDocument?.isDirty == false,
              "and that replacement is an untouched untitled buffer")
        try? FileManager.default.removeItem(at: sample)
        try? FileManager.default.removeItem(at: sample2)

        section("Surviving the app being removed or upgraded")

        // Backup names must reverse, because the workspace README tells people
        // to do exactly this by hand when recovering without the app.
        check(Workspace.originalName(fromBackup: "config~3f9a2b1c.yaml") == "config.yaml",
              "a backup name reverses to the original filename",
              Workspace.originalName(fromBackup: "config~3f9a2b1c.yaml"))
        check(Workspace.originalName(fromBackup: "notabackup.txt") == "notabackup.txt",
              "a name with no id is left alone")
        check(Workspace.originalName(fromBackup: "my~file~aabbccdd.md") == "my~file.md",
              "only the last tilde separates the id, so tildes in a name survive",
              Workspace.originalName(fromBackup: "my~file~aabbccdd.md"))

        // Adopting orphans means opening whatever is in Backups/, so it has to
        // tell a backup from litter. A real workspace was found holding a macOS
        // atomic-write temporary, which without this check opened as a tab.
        check(Workspace.isBackupFilename("config~3f9a2b1c.yaml"), "a real backup name is recognised")
        check(!Workspace.isBackupFilename("index.txt"), "the index is not a backup")
        check(!Workspace.isBackupFilename("index.txt.sb-4b911b25-tJHkF8"),
              "a macOS atomic-write temporary is not a backup")
        check(!Workspace.isBackupFilename(".DS_Store"), "a dotfile is not a backup")
        check(!Workspace.isBackupFilename("notes.txt"), "a plain file with no id is not a backup")
        check(!Workspace.isBackupFilename("notes~short.txt"),
              "a tilde followed by something other than an 8-digit id is not a backup")

        // A session file written by a build with a different set of fields must
        // not be discarded. The synthesised decoder requires every non-optional
        // key and the caller uses `try?`, so before this decoding a schema
        // change silently emptied the window -- unsaved tabs included.
        let lenient = JSONDecoder()
        lenient.dateDecodingStrategy = .iso8601
        let sparse: SessionDocument? = try? lenient.decode(
            SessionDocument.self, from: Data(#"{"backupFile":"notes~aabbccdd.txt"}"#.utf8))
        check(sparse != nil, "a record missing almost every field still decodes")
        check(sparse?.backupFile == "notes~aabbccdd.txt",
              "and keeps the backup filename, the one part that cannot be recreated")
        check(sparse?.encoding == FileEncoding.utf8.rawValue, "a missing field takes a default")
        let wrongType: SessionDocument? = try? lenient.decode(
            SessionDocument.self,
            from: Data(#"{"backupFile":"a~bbbbcccc.txt","selectionLocation":"not a number"}"#.utf8))
        check(wrongType?.backupFile == "a~bbbbcccc.txt",
              "a field of the wrong type is defaulted rather than losing the record")
        let emptyRecord: SessionDocument? = try? lenient.decode(
            SessionDocument.self, from: Data("{}".utf8))
        check(emptyRecord != nil, "an empty record decodes rather than throwing")

        // End to end: delete the session index and leave the backups. This is
        // what a corrupted session, an interrupted write, or a reinstall that
        // resets preferences looks like from the workspace's point of view, and
        // the text must still come back.
        host.persistSession()
        Thread.sleep(forTimeInterval: 0.4)   // the store writes off the main thread
        let strandedName = "stranded~deadbeef.txt"
        try? "text nobody should lose".write(
            to: Workspace.shared.backupsDirectory.appendingPathComponent(strandedName),
            atomically: true, encoding: .utf8)
        let untitledStranded = "new 41~deadbee2.txt"
        try? "an unsaved buffer".write(
            to: Workspace.shared.backupsDirectory.appendingPathComponent(untitledStranded),
            atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: Workspace.shared.sessionFile)

        let rebuilt = SessionStore.shared.loadSession()
        check(rebuilt != nil, "a missing session file still yields a session when backups exist")
        let names = Set(rebuilt?.documents.compactMap(\.backupFile) ?? [])
        check(names.contains(strandedName),
              "a backup with no session entry is restored rather than stranded",
              "recovered \(names)")
        check(rebuilt?.documents.contains { $0.untitledName == "new 41" } == true,
              "a recovered untitled buffer keeps its \"new N\" name",
              (rebuilt?.documents.map(\.untitledName) ?? []).joined(separator: ", "))
        check(SessionStore.shared.nextUntitledName() == "new 42",
              "and the counter continues past it instead of handing out a duplicate")
        check(SessionStore.shared.backupText(named: strandedName) == "text nobody should lose",
              "the recovered record points at the real text")

        // The workspace is the user's, not the app's: nothing here deletes it.
        check(FileManager.default.fileExists(atPath: Workspace.shared.root.path),
              "recovery leaves the workspace folder in place")

        // An orphan alongside an intact session must also be adopted. Before
        // this, the session was believed over the folder and the next autosave
        // pruned the file away -- deleting the only copy of that text.
        host.persistSession()
        Thread.sleep(forTimeInterval: 0.4)
        let orphanName = "orphan~feedface.txt"
        try? "orphaned but not lost".write(
            to: Workspace.shared.backupsDirectory.appendingPathComponent(orphanName),
            atomically: true, encoding: .utf8)
        try? "not mine".write(
            to: Workspace.shared.backupsDirectory.appendingPathComponent("index.txt.sb-1234abcd-XyZ"),
            atomically: true, encoding: .utf8)
        let withOrphan = SessionStore.shared.loadSession()
        check(withOrphan?.documents.contains { $0.backupFile == orphanName } == true,
              "an orphaned backup is adopted even when the session file is intact",
              "session listed \((withOrphan?.documents.compactMap(\.backupFile) ?? []).joined(separator: ", "))")
        check(withOrphan?.documents.contains { ($0.backupFile ?? "").contains(".sb-") } == false,
              "but an atomic-write temporary in the folder is not opened as a tab")

        section("Markdown preview")
        let markdownSource = """
        # Title

        Body with **bold**, *italic*, `code` and a [link](https://example.com).

        - bullet
        - [x] done

        > quoted

        ---

        | A | B |
        | - | - |
        | 1 | 2 |

        ```swift
        let x = 1
        ```

        [ref]: https://example.org
        See the [reference][ref] and ![remote](https://example.com/a.png).
        """
        let options = MarkdownRenderer.Options(theme: host.theme,
                                               editorFont: host.settings.editorFont,
                                               baseURL: nil)
        let rendered = MarkdownRenderer.render(markdownSource, options: options)
        let renderedText = rendered.string
        let wholeRender = NSRange(location: 0, length: rendered.length)

        check(rendered.length > 0, "a document renders to something")
        check(!renderedText.contains("**") && !renderedText.contains("`"),
              "the markers themselves are gone from the rendered text",
              "rendered: \(renderedText.prefix(120))")
        check(renderedText.contains("Title"), "the heading text survives")

        var sawHeadingFont = false
        var sawBold = false
        var sawItalic = false
        var sawMonospace = false
        rendered.enumerateAttribute(.font, in: wholeRender) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let traits = NSFontManager.shared.traits(of: font)
            let text = (renderedText as NSString).substring(with: range)
            if text.contains("Title"), font.pointSize > host.settings.editorFont.pointSize + 2 {
                sawHeadingFont = true
            }
            if text.contains("bold"), traits.contains(.boldFontMask) { sawBold = true }
            if text.contains("italic"), traits.contains(.italicFontMask) { sawItalic = true }
            if text.contains("code"), font.fontName == host.settings.editorFont.fontName {
                sawMonospace = true
            }
        }
        check(sawHeadingFont, "a heading is set larger than body text")
        check(sawBold, "bold renders bold rather than as asterisks")
        check(sawItalic, "italic renders italic")
        check(sawMonospace, "a code span keeps the editor's own face")

        var linkedURLs: [String] = []
        rendered.enumerateAttribute(.link, in: wholeRender) { value, _, _ in
            if let url = value as? URL { linkedURLs.append(url.absoluteString) }
        }
        check(linkedURLs.contains("https://example.com"), "a link carries a real URL",
              "found \(linkedURLs)")
        check(linkedURLs.contains("https://example.org"),
              "a reference-style link resolves against its definition further down")
        check(!renderedText.contains("[ref]: https://example.org"),
              "and the definition itself is not printed as body text")

        // The preview must never reach the network. A remote image is shown as
        // its alt text, so nothing about opening a file tells its author that
        // you did.
        var attachments = 0
        rendered.enumerateAttribute(.attachment, in: wholeRender) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        check(renderedText.contains("remote"), "a remote image is shown as its alt text, not fetched")
        check(attachments == 1, "the only attachment is the horizontal rule",
              "attachments: \(attachments)")

        let dangerous = MarkdownRenderer.render("[x](javascript:alert(1))", options: options)
        var dangerousLinks = 0
        dangerous.enumerateAttribute(.link, in: NSRange(location: 0, length: dangerous.length)) { value, _, _ in
            if value != nil { dangerousLinks += 1 }
        }
        check(dangerousLinks == 0, "a javascript: URL is rendered as text and never linked")

        let htmlRender = MarkdownRenderer.render("<b>not bold</b>", options: options)
        check(htmlRender.string.contains("<b>"), "embedded HTML is shown literally, never executed")

        var sawTableBlock = false
        rendered.enumerateAttribute(.paragraphStyle, in: wholeRender) { value, _, _ in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { sawTableBlock = true }
        }
        check(sawTableBlock, "a table becomes real cells rather than a row of pipes")

        var codeIsColoured = false
        rendered.enumerateAttribute(.foregroundColor, in: wholeRender) { value, range, _ in
            let text = (renderedText as NSString).substring(with: range)
            guard text.contains("let"), let colour = value as? NSColor else { return }
            if colour != host.theme.foreground { codeIsColoured = true }
        }
        check(codeIsColoured, "a fenced block is coloured by the editor's own scanner")
        check(renderedText.contains("[x]"), "a task item keeps its checkbox")

        // The pane itself, and the rule that it only appears for Markdown.
        let markdownDocument = TextDocument(untitledName: "preview test")
        markdownDocument.delegate = host
        markdownDocument.replaceAllText("# Hello")
        markdownDocument.setLanguage(LanguageRegistry.named("Markdown") ?? LanguageRegistry.plainText,
                                     explicit: true)
        host.addDocument(markdownDocument)
        host.settings.showMarkdownPreview = false
        host.updateMarkdownPreview()
        check(host.currentDocumentIsMarkdown, "a Markdown document is recognised as one")
        host.toggleMarkdownPreview(nil)
        check(host.settings.showMarkdownPreview, "the View menu toggle turns the preview on")
        check(host.isMarkdownPreviewVisible, "and the pane appears beside the editor")

        let plainDocument = TextDocument(untitledName: "not markdown")
        plainDocument.delegate = host
        plainDocument.setLanguage(LanguageRegistry.plainText, explicit: true)
        host.addDocument(plainDocument)
        check(!host.isMarkdownPreviewVisible,
              "switching to a document that is not Markdown hides it again")
        host.selectTab(host.documents.count - 2)
        check(host.isMarkdownPreviewVisible, "switching back brings it straight back")
        host.toggleMarkdownPreview(nil)
        check(!host.isMarkdownPreviewVisible, "and the toggle puts it away")

        // A pane built while the window is already on screen -- every File >
        // Open -- used to sit 65pt right of its resting position, hiding the
        // first characters of every line behind the gutter.
        if let pane = host.currentPane {
            pane.layoutSubtreeIfNeeded()
            let clip = pane.scrollView.contentView
            let far = NSRect(origin: NSPoint(x: -1_000_000, y: -1_000_000), size: clip.bounds.size)
            let resting = clip.constrainBoundsRect(far).origin.x
            check(abs(clip.bounds.origin.x - resting) < 1,
                  "a pane opened into a live window is not scrolled sideways",
                  "clip x \(clip.bounds.origin.x), resting \(resting)")
        }

        section("Workspace")
        let live = Set(host.documents.map { Workspace.backupFilename(for: $0) })
        _ = SessionStore.shared.inspectForCleanup(liveBackups: live)
        check(FileManager.default.fileExists(atPath: Workspace.shared.backupsDirectory.path),
              "Backups folder exists")
        check(FileManager.default.fileExists(atPath: Workspace.shared.readmeFile.path),
              "workspace README exists for recovery without the app")

        log += "\nNeeds a person (opens a panel or alert): Save As, Reload From Disk, "
        log += "Go to Line, Find in Files, Clean Up Workspace, Clear Recently Closed, "
        log += "Choose Workspace Folder, Choose Editor Font, Print.\n"
        log += "\n\(checks - failures)/\(checks) checks passed"
        log += failures > 0 ? "  -- \(failures) FAILED\n" : "  -- all good\n"
        return log
    }
}
