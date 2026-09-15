import AppKit

/// Everything in Settings, persisted as JSON in the workspace.
struct Settings: Codable {
    var themeName = Theme.classic.name
    var fontName = "Menlo"
    var fontSize: Double = 13
    var tabWidth = 4
    var insertSpaces = false
    var wordWrap = false
    var showLineNumbers = true
    var showBookmarkMargin = true
    var showFoldMargin = true
    var showInvisibles = false
    var showIndentGuides = true
    var highlightCurrentLine = true
    var autoIndent = true
    var autoCloseBrackets = true
    var smartHighlight = true
    var showToolbar = true
    var showStatusBar = true
    /// The rendered Markdown pane. Remembered across launches, but only ever
    /// shown for a Markdown document -- see MainWindowController.
    var showMarkdownPreview = false
    /// How much of the editor area the document keeps when the preview is up.
    var markdownPreviewFraction = 0.5
    /// Height of the Find result dock, remembered once it has been dragged.
    var searchResultsHeight = 200.0
    var showTabCloseButtons = true
    var recentFiles: [String] = []
    var maxRecentFiles = 20
    var maxRecentlyClosed = 30
    /// Days after which an untouched Recently Closed entry is discarded.
    var recentlyClosedRetentionDays = 30

    var theme: Theme { Theme.named(themeName) ?? .classic }

    var editorFont: NSFont {
        NSFont(name: fontName, size: CGFloat(fontSize))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }

    var indentUnit: String {
        insertSpaces ? String(repeating: " ", count: max(1, tabWidth)) : "\t"
    }

    mutating func noteRecentFile(_ url: URL) {
        let path = url.standardizedFileURL.path
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > maxRecentFiles {
            recentFiles.removeSubrange(maxRecentFiles...)
        }
    }
}

/// One tab's worth of persisted state.
struct SessionDocument: Codable {
    var id: UUID
    /// Absolute path of the file this buffer belongs to, if any.
    var path: String?
    /// Filename inside Backups/ (or Recently Closed/) holding the text.
    var backupFile: String?
    var hadUnsavedChanges: Bool
    var encoding: String
    var lineEnding: String
    var language: String
    var languageExplicit: Bool
    var selectionLocation: Int
    var selectionLength: Int
    var scrollOffset: Double
    var bookmarks: [Int]
    var untitledName: String
    var diskDate: Date?
    var closedAt: Date?
    var lastTouched: Date

    var fileURL: URL? { path.map { URL(fileURLWithPath: $0) } }
}

extension SessionDocument {

    /// Decode a record field by field, defaulting anything missing.
    ///
    /// The synthesised decoder requires every non-optional key, so a session
    /// written by a build with a different field set throws -- and because the
    /// caller uses `try?`, the whole file is discarded and every tab silently
    /// disappears, unsaved ones included. Losing text to a schema change is
    /// exactly what this app promises cannot happen, so nothing here is allowed
    /// to be fatal: a record with only a backup filename in it still restores
    /// the text, which is the part that cannot be recreated.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` on `decodeIfPresent` gives a double optional: the outer one is
        // "the key was malformed", the inner "the key was absent". Both mean
        // "use the default" here.
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        func optional<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        id = read(.id, UUID())
        path = optional(.path, String.self)
        backupFile = optional(.backupFile, String.self)
        hadUnsavedChanges = read(.hadUnsavedChanges, false)
        encoding = read(.encoding, FileEncoding.utf8.rawValue)
        lineEnding = read(.lineEnding, LineEnding.systemDefault.rawValue)
        language = read(.language, "")
        languageExplicit = read(.languageExplicit, false)
        selectionLocation = read(.selectionLocation, 0)
        selectionLength = read(.selectionLength, 0)
        scrollOffset = read(.scrollOffset, 0)
        bookmarks = read(.bookmarks, [Int]())
        untitledName = read(.untitledName, "recovered")
        diskDate = optional(.diskDate, Date.self)
        closedAt = optional(.closedAt, Date.self)
        lastTouched = read(.lastTouched, Date())
    }

    /// Build a record from nothing but a file sitting in `Backups/`.
    ///
    /// Used when the session index is gone but the text is not.
    init(recoveredBackup name: String, origin: String?, displayName: String) {
        self.init(id: UUID(),
                  path: origin,
                  backupFile: name,
                  hadUnsavedChanges: true,
                  encoding: FileEncoding.utf8.rawValue,
                  lineEnding: LineEnding.systemDefault.rawValue,
                  language: "",
                  languageExplicit: false,
                  selectionLocation: 0,
                  selectionLength: 0,
                  scrollOffset: 0,
                  bookmarks: [],
                  untitledName: displayName,
                  diskDate: nil,
                  closedAt: nil,
                  lastTouched: Date())
    }
}

struct SessionFile: Codable {
    var version = 2
    var activeIndex = 0
    var documents: [SessionDocument] = []
    var recentlyClosed: [SessionDocument] = []
    var savedAt = Date()
    /// Counter behind "untitled-1", "untitled-2", so numbering survives a relaunch.
    var untitledCounter = 0
}

/// Reads and writes the workspace: settings, session, and the live backups that
/// make unsaved work survive anything.
///
/// Writes are atomic and happen off the main thread. The main thread's only job
/// is to hand over a snapshot of the text, which is cheap because Swift strings
/// are copy-on-write.
final class SessionStore {

    static let shared = SessionStore()

    private let workspace = Workspace.shared
    private let queue = DispatchQueue(label: "com.ankitgoyal.pluspad.session", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    var settings = Settings()
    private(set) var recentlyClosed: [SessionDocument] = []
    private(set) var untitledCounter = 0

    /// Text of documents closed in *this* session, keyed by backup filename.
    ///
    /// `archiveClosed` writes the file on a background queue so closing a tab
    /// never waits on the disk, but Reopen Closed Tab is one keystroke away and
    /// read that file straight back on the main thread -- so reopening a tab you
    /// had just closed raced the write and handed back an empty buffer. Losing
    /// text on close is the single thing this app promises cannot happen, so the
    /// text is kept here as well and the file is only the fallback, used for
    /// entries restored from a previous session.
    private var closedText: [String: String] = [:]

    private init() {
        loadSettings()
    }

    // MARK: - Settings

    func loadSettings() {
        guard let data = try? Data(contentsOf: workspace.settingsFile),
              let loaded = try? decoder.decode(Settings.self, from: data) else { return }
        settings = loaded
    }

    func saveSettings() {
        let snapshot = settings
        queue.async { [encoder, workspace] in
            guard let data = try? encoder.encode(snapshot) else { return }
            try? workspace.prepare()
            try? data.write(to: workspace.settingsFile, options: .atomic)
        }
    }

    // MARK: - Session

    func loadSession() -> SessionFile? {
        var stored: SessionFile?
        if let data = try? Data(contentsOf: workspace.sessionFile) {
            stored = try? decoder.decode(SessionFile.self, from: data)
        }
        var result = stored ?? SessionFile()

        // Adopt any backup the session does not account for.
        //
        // `Backups/` is the promise: whatever you had open is in there, under a
        // name you can recognise. But `pruneBackups` keeps only the files
        // belonging to open tabs, so a backup the session has lost track of --
        // because the index was corrupted, a write was interrupted, or the app
        // was reinstalled and the session file went with it -- would be deleted
        // on the very next autosave. Silently throwing away the one copy of
        // someone's unsaved text is the worst thing this app could do, so an
        // orphan is opened as a tab rather than collected as garbage.
        let referenced = Set(result.documents.compactMap(\.backupFile))
        let orphans = documentsRecoveredFromBackups().filter {
            !referenced.contains($0.backupFile ?? "")
        }
        result.documents.append(contentsOf: orphans)

        // Nothing at all: the caller opens a fresh "new 1", as Notepad++ does.
        guard !result.documents.isEmpty else { return nil }
        result.activeIndex = min(max(0, result.activeIndex), result.documents.count - 1)

        recentlyClosed = result.recentlyClosed
        // Never hand out a number a restored tab is already using. The stored
        // counter is normally ahead of them all, but a recovered session has no
        // stored counter, and two tabs called "new 1" is a Notepad++ rule broken
        // and a backup filename collision waiting to happen.
        untitledCounter = max(result.untitledCounter,
                              Self.highestUntitledNumber(in: result.documents))
        return result
    }

    /// Reconstruct one record per file in `Backups/`.
    private func documentsRecoveredFromBackups() -> [SessionDocument] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: workspace.backupsDirectory.path) else {
            return []
        }
        let origins = originsFromIndex()
        return names.sorted()
            .filter { Workspace.isBackupFilename($0) }
            .map { name in
                SessionDocument(recoveredBackup: name,
                                origin: origins[name],
                                displayName: Self.recoveredName(forBackup: name,
                                                                hasOrigin: origins[name] != nil))
            }
    }

    /// Parse `Backups/index.txt` back into backup name -> original path.
    ///
    /// The file is written for a person to read, so this tolerates anything it
    /// does not recognise and simply returns less.
    private func originsFromIndex() -> [String: String] {
        guard let text = try? String(contentsOf: workspace.backupIndexFile, encoding: .utf8) else {
            return [:]
        }
        var map: [String: String] = [:]
        var current: String?
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("    from:") {
                let origin = line.dropFirst("    from:".count).trimmingCharacters(in: .whitespaces)
                if let name = current, origin.hasPrefix("/") { map[name] = origin }
            } else if !line.hasPrefix(" ") && !line.isEmpty && !line.hasPrefix("=") {
                current = line.trimmingCharacters(in: .whitespaces)
            }
        }
        return map
    }

    /// What to call a tab rebuilt from a backup file.
    ///
    /// A backup always has an extension, so an untitled buffer called "new 1"
    /// was stored as "new 1~id.txt". Handing that straight back would name the
    /// tab "new 1.txt" and break the untitled counter, which parses the number
    /// off the end.
    private static func recoveredName(forBackup name: String, hasOrigin: Bool) -> String {
        let restored = Workspace.originalName(fromBackup: name)
        guard !hasOrigin, restored.hasSuffix(".txt") else { return restored }
        let stem = String(restored.dropLast(4))
        guard stem.hasPrefix("new "), Int(stem.dropFirst(4)) != nil else { return restored }
        return stem
    }

    private static func highestUntitledNumber(in documents: [SessionDocument]) -> Int {
        documents.compactMap { record -> Int? in
            guard record.untitledName.hasPrefix("new ") else { return nil }
            return Int(record.untitledName.dropFirst(4))
        }.max() ?? 0
    }

    /// Notepad++ calls a fresh buffer "new 1", and the numbering keeps going up
    /// across launches rather than resetting, so two tabs never share a name.
    func nextUntitledName() -> String {
        untitledCounter += 1
        return "new \(untitledCounter)"
    }

    /// Persist the full session: one backup file per document plus the index.
    ///
    /// `documents` must be snapshotted on the main thread before this is called;
    /// the tuples carry text by value so nothing here touches live objects.
    func persist(documents: [DocumentSnapshot], activeIndex: Int) {
        let closed = recentlyClosed
        let counter = untitledCounter
        queue.async { [self] in
            try? workspace.prepare()

            var records: [SessionDocument] = []
            var indexLines: [String] = []
            var liveBackupNames = Set<String>()

            for snapshot in documents {
                var record = snapshot.record
                // A clean document with a file on disk needs no backup: the disk
                // copy is the backup, and writing a second one doubles the I/O
                // on every keystroke for no benefit.
                if snapshot.needsBackup {
                    let name = snapshot.backupFilename
                    let target = workspace.backupsDirectory.appendingPathComponent(name)
                    if let data = snapshot.text.data(using: .utf8) {
                        try? data.write(to: target, options: .atomic)
                        liveBackupNames.insert(name)
                        record.backupFile = name
                        indexLines.append(Self.indexLine(for: snapshot, backupName: name))
                    }
                } else {
                    record.backupFile = nil
                }
                records.append(record)
            }

            var session = SessionFile()
            session.activeIndex = activeIndex
            session.documents = records
            session.recentlyClosed = closed
            session.savedAt = Date()
            session.untitledCounter = counter

            if let data = try? encoder.encode(session) {
                try? data.write(to: workspace.sessionFile, options: .atomic)
            }

            writeIndex(indexLines)
            pruneBackups(keeping: liveBackupNames)
        }
    }

    private static func indexLine(for snapshot: DocumentSnapshot, backupName: String) -> String {
        let origin = snapshot.record.path ?? "(never saved to a file)"
        let state = snapshot.record.hadUnsavedChanges ? "UNSAVED CHANGES" : "in sync with file"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(backupName)\n    from:    \(origin)\n    state:   \(state)\n    "
             + "written: \(formatter.string(from: Date()))\n"
    }

    private func writeIndex(_ entries: [String]) {
        let header = """
        PlusPad backup index
        ====================
        Each entry below is a live copy of one open tab. To recover, copy the
        named file out of this folder and drop the "~id" part off its name.

        """
        let body = entries.isEmpty ? "(no open tabs with content)\n" : entries.joined(separator: "\n")
        try? (header + "\n" + body).write(to: workspace.backupIndexFile, atomically: true, encoding: .utf8)
    }

    /// Remove backups belonging to documents that are no longer open.
    ///
    /// `Backups/` mirrors the open tabs and nothing else. A closed document's
    /// text has already been copied into `Recently Closed/`, which is a separate
    /// folder, so exempting its name here only left the same text sitting in two
    /// places and growing the workspace for every tab ever closed.
    @discardableResult
    private func pruneBackups(keeping: Set<String>) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: workspace.backupsDirectory,
                                                        includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != "index.txt", !name.hasPrefix(".") else { continue }
            guard !keeping.contains(name) else { continue }
            if (try? fm.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Recently closed

    /// Park a closed document's text so closing a tab never destroys work.
    ///
    /// This is what lets Close skip the "save changes?" question entirely: the
    /// text moves to Recently Closed rather than being discarded, and Reopen
    /// Closed Tab brings it back exactly as it was.
    func archiveClosed(_ snapshot: DocumentSnapshot) {
        guard snapshot.needsBackup else { return }
        var record = snapshot.record
        record.closedAt = Date()
        let name = snapshot.backupFilename
        record.backupFile = name

        recentlyClosed.insert(record, at: 0)
        closedText[name] = snapshot.text
        if recentlyClosed.count > settings.maxRecentlyClosed {
            let dropped = recentlyClosed.suffix(from: settings.maxRecentlyClosed)
            for entry in dropped {
                if let file = entry.backupFile {
                    closedText.removeValue(forKey: file)
                    try? FileManager.default.removeItem(
                        at: workspace.closedDirectory.appendingPathComponent(file))
                }
            }
            recentlyClosed.removeSubrange(settings.maxRecentlyClosed...)
        }

        let text = snapshot.text
        queue.async { [workspace] in
            try? workspace.prepare()
            let target = workspace.closedDirectory.appendingPathComponent(name)
            try? text.data(using: .utf8)?.write(to: target, options: .atomic)
        }
    }

    func takeMostRecentlyClosed() -> (SessionDocument, String)? {
        guard let record = recentlyClosed.first else { return nil }
        recentlyClosed.removeFirst()
        guard let name = record.backupFile else { return (record, "") }
        let url = workspace.closedDirectory.appendingPathComponent(name)
        let text = closedText.removeValue(forKey: name)
            ?? (try? String(contentsOf: url, encoding: .utf8))
            ?? ""
        // Deleted on the same queue that writes it, so the two stay ordered.
        // Removing it here could run before `archiveClosed`'s write and leave
        // the file behind with nothing referring to it.
        queue.async { try? FileManager.default.removeItem(at: url) }
        return (record, text)
    }

    /// Drop Recently Closed entries older than the retention window.
    func pruneRecentlyClosed() {
        let cutoff = Date().addingTimeInterval(-Double(settings.recentlyClosedRetentionDays) * 86400)
        let expired = recentlyClosed.filter { ($0.closedAt ?? Date()) < cutoff }
        guard !expired.isEmpty else { return }
        recentlyClosed.removeAll { ($0.closedAt ?? Date()) < cutoff }
        for entry in expired { closedText.removeValue(forKey: entry.backupFile ?? "") }
        queue.async { [workspace] in
            for entry in expired {
                guard let file = entry.backupFile else { continue }
                try? FileManager.default.removeItem(
                    at: workspace.closedDirectory.appendingPathComponent(file))
            }
        }
    }

    // MARK: - Housekeeping

    /// What a clean-up would remove, without removing it.
    struct CleanupReport {
        var orphanedBackups: [String] = []
        var expiredClosed: [String] = []
        var reclaimedBytes: Int = 0

        var isEmpty: Bool { orphanedBackups.isEmpty && expiredClosed.isEmpty }
        var totalFiles: Int { orphanedBackups.count + expiredClosed.count }
    }

    /// Inspect the workspace for files nothing refers to any more.
    ///
    /// `liveBackups` is the set of backup filenames belonging to currently open
    /// tabs; anything else under `Backups/` is left over from a crash or an
    /// older version and can go.
    func inspectForCleanup(liveBackups: Set<String>) -> CleanupReport {
        let fm = FileManager.default
        var report = CleanupReport()

        func size(_ url: URL) -> Int {
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }

        if let entries = try? fm.contentsOfDirectory(at: workspace.backupsDirectory,
                                                     includingPropertiesForKeys: [.fileSizeKey]) {
            for entry in entries {
                let name = entry.lastPathComponent
                guard name != "index.txt", !name.hasPrefix(".") else { continue }
                guard !liveBackups.contains(name) else { continue }
                report.orphanedBackups.append(name)
                report.reclaimedBytes += size(entry)
            }
        }

        // Recently Closed holds two kinds of rubbish: entries past the retention
        // window, and files on disk the session no longer lists at all.
        let cutoff = Date().addingTimeInterval(-Double(settings.recentlyClosedRetentionDays) * 86400)
        let expiredNames = Set(recentlyClosed.filter { ($0.closedAt ?? Date()) < cutoff }
                                             .compactMap(\.backupFile))
        let referenced = Set(recentlyClosed.compactMap(\.backupFile))
        if let entries = try? fm.contentsOfDirectory(at: workspace.closedDirectory,
                                                     includingPropertiesForKeys: [.fileSizeKey]) {
            for entry in entries {
                let name = entry.lastPathComponent
                guard !name.hasPrefix(".") else { continue }
                guard expiredNames.contains(name) || !referenced.contains(name) else { continue }
                report.expiredClosed.append(name)
                report.reclaimedBytes += size(entry)
            }
        }
        return report
    }

    /// Apply a clean-up. Only ever touches files the report named.
    func performCleanup(_ report: CleanupReport) {
        let fm = FileManager.default
        for name in report.orphanedBackups {
            try? fm.removeItem(at: workspace.backupsDirectory.appendingPathComponent(name))
        }
        for name in report.expiredClosed {
            try? fm.removeItem(at: workspace.closedDirectory.appendingPathComponent(name))
        }
        let gone = Set(report.expiredClosed)
        for name in gone { closedText.removeValue(forKey: name) }
        recentlyClosed.removeAll { gone.contains($0.backupFile ?? "") }
    }

    /// Forget every Recently Closed entry and delete its text.
    func discardAllRecentlyClosed() {
        let fm = FileManager.default
        for entry in recentlyClosed {
            guard let file = entry.backupFile else { continue }
            try? fm.removeItem(at: workspace.closedDirectory.appendingPathComponent(file))
        }
        recentlyClosed.removeAll()
        closedText.removeAll()
    }

    // MARK: - Reading a backup back

    func backupText(named name: String) -> String? {
        let url = workspace.backupsDirectory.appendingPathComponent(name)
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// A value-type copy of a document, taken on the main thread so the background
/// writer never reaches into a live `TextDocument`.
struct DocumentSnapshot {
    var record: SessionDocument
    var text: String
    var backupFilename: String
    var needsBackup: Bool

    init(document: TextDocument, backupFilename: String) {
        let dirty = document.isDirty
        self.text = document.text
        self.backupFilename = backupFilename
        // Back up anything that is not identical to a file already on disk:
        // every unsaved change, and every untitled buffer that has something in
        // it. An empty scratch tab has nothing to recover, so it gets no backup
        // file and no line in the index.
        self.needsBackup = (dirty || !document.hasFile) && !self.text.isEmpty
        self.record = SessionDocument(
            id: document.id,
            path: document.fileURL?.path,
            backupFile: nil,
            hadUnsavedChanges: dirty,
            encoding: document.encoding.rawValue,
            lineEnding: document.lineEnding.rawValue,
            language: document.language.name,
            languageExplicit: document.languageIsExplicit,
            selectionLocation: document.selectedRange.location,
            selectionLength: document.selectedRange.length,
            scrollOffset: Double(document.scrollOffset),
            bookmarks: document.bookmarks.sorted(),
            untitledName: document.untitledName,
            diskDate: document.lastKnownDiskDate,
            closedAt: nil,
            lastTouched: Date())
    }
}
