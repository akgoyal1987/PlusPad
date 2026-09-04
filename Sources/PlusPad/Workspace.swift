import AppKit

/// The folder where PlusPad keeps everything it knows.
///
/// The whole point of this type is that a person can recover their work with
/// the Finder and nothing else. After a crash, a kernel panic or a force quit,
/// the unsaved text is sitting in `Backups/` under a name that says what it is,
/// with the original extension so double-clicking opens it in the right app,
/// and `Backups/index.txt` maps each one back to where it came from. Nothing
/// about recovery requires PlusPad to start successfully.
///
/// The location is the user's choice. Only the path itself lives in
/// `UserDefaults`, because it is the one thing that cannot live inside the
/// folder it points at.
final class Workspace {

    static let shared = Workspace()

    private enum Keys {
        static let root = "workspaceRoot"
        static let configured = "workspaceConfigured"
    }

    private(set) var root: URL

    /// False until the user has been asked where they want the workspace. The
    /// app runs perfectly well on the default before then; this only drives the
    /// one-time first-launch prompt.
    var hasBeenConfigured: Bool {
        // A forced workspace never prompts: it is not the user's own.
        get { isOverridden || UserDefaults.standard.bool(forKey: Keys.configured) }
        set { if !isOverridden { UserDefaults.standard.set(newValue, forKey: Keys.configured) } }
    }

    /// `~/Documents/PlusPad`, chosen over Application Support on purpose:
    /// recovery means opening the folder in the Finder, and Application Support
    /// is hidden from users by default and excluded from some backup setups.
    static var defaultRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return documents.appendingPathComponent("PlusPad", isDirectory: true)
    }

    /// True when the workspace was forced by the environment rather than chosen
    /// by the user. Nothing in that mode writes to `UserDefaults`.
    private(set) var isOverridden = false

    private init() {
        // PLUSPAD_WORKSPACE points the app at a throwaway folder. The self test
        // closes tabs and flips settings, so without this it would run against
        // the real workspace and destroy whatever the person had open.
        if let override = ProcessInfo.processInfo.environment["PLUSPAD_WORKSPACE"],
           !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
            isOverridden = true
        } else if let stored = UserDefaults.standard.string(forKey: Keys.root), !stored.isEmpty {
            root = URL(fileURLWithPath: stored, isDirectory: true)
        } else {
            root = Workspace.defaultRoot
        }
        try? prepare()
    }

    // MARK: - Layout

    var backupsDirectory: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    var closedDirectory: URL { root.appendingPathComponent("Recently Closed", isDirectory: true) }
    var sessionFile: URL { root.appendingPathComponent("session.json") }
    var settingsFile: URL { root.appendingPathComponent("settings.json") }
    var backupIndexFile: URL { backupsDirectory.appendingPathComponent("index.txt") }
    var readmeFile: URL { root.appendingPathComponent("README.txt") }
    /// Present while the app is running. Left behind means the last run died.
    var lockFile: URL { root.appendingPathComponent(".running") }

    /// Create the folder structure and drop in the explanatory README.
    func prepare() throws {
        let fm = FileManager.default
        for dir in [root, backupsDirectory, closedDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Rewritten whenever it differs, not just when it is absent: this file
        // is the recovery instructions, and an existing workspace is exactly the
        // one whose owner has work in it to recover.
        let existing = try? String(contentsOf: readmeFile, encoding: .utf8)
        if existing != Workspace.readmeText {
            try? Workspace.readmeText.write(to: readmeFile, atomically: true, encoding: .utf8)
        }
    }

    static let readmeText = """
    PlusPad workspace
    =================

    This folder holds everything PlusPad remembers between launches. You can open
    it in the Finder at any time; nothing here needs PlusPad to be running, or
    even to start successfully.

    Backups/
        A live copy of every open tab, including tabs that have never been saved
        to a file and tabs with unsaved changes. Each file keeps the original
        name and extension, with a short id added so two files with the same name
        do not collide.

        THIS IS THE RECOVERY FOLDER. If PlusPad crashes, the machine loses power,
        or anything else goes wrong, your text is here. Copy the file you want
        back out, drop the "~id" part off the name, and carry on.

    Backups/index.txt
        A plain list saying which backup came from which file, whether it had
        unsaved changes, and when it was last written. Read this first.

    Recently Closed/
        Tabs you closed that had unsaved changes. PlusPad never asks you to save
        before closing a tab; it puts the text here instead, and File > Reopen
        Closed Tab brings it back. Old entries are cleaned up over time.

    session.json
        Which tabs are open, in what order, which one is active, and where the
        cursor was in each.

    settings.json
        Preferences: theme, font, tab width, and the rest.

    Moving this folder
        Use Settings > Workspace Folder inside PlusPad rather than moving it by
        hand, so the contents come with it.

    If you uninstall PlusPad
        This folder is yours, not the app's. It lives outside the application
        bundle and outside the system's application-support folders, so deleting
        PlusPad -- by dragging it to the Trash or any other way -- does not touch
        anything in here. Your unsaved text stays exactly where it is, readable
        in any editor, for as long as you keep the folder.

        Nothing in here is in a private format. Backups are plain UTF-8 text.
        session.json and settings.json are plain JSON. You never need PlusPad,
        or any other particular program, to get your work back.

        If you reinstall later and point PlusPad at this same folder, it picks
        the tabs back up, including ones that were never saved to a file. It
        does that even if session.json is missing or damaged, by reading the
        files in Backups/ directly.
    """

    // MARK: - Relocation

    enum WorkspaceError: LocalizedError {
        case notWritable(URL)
        case migrationFailed(String)

        var errorDescription: String? {
            switch self {
            case .notWritable(let url):
                return "PlusPad cannot write to \(url.path). Choose a folder you have permission to change."
            case .migrationFailed(let message):
                return "The workspace could not be moved: \(message)"
            }
        }
    }

    /// Point the workspace at `newRoot`, carrying the existing contents across.
    ///
    /// Existing files at the destination are never overwritten. A collision
    /// keeps the destination's copy and leaves ours beside it with a suffix,
    /// because the one thing this function must not do is destroy a backup.
    func relocate(to newRoot: URL) throws {
        let fm = FileManager.default
        guard newRoot.standardizedFileURL != root.standardizedFileURL else { return }

        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        guard fm.isWritableFile(atPath: newRoot.path) else {
            throw WorkspaceError.notWritable(newRoot)
        }

        let oldRoot = root
        do {
            if fm.fileExists(atPath: oldRoot.path) {
                try copyTree(from: oldRoot, to: newRoot, fileManager: fm)
            }
        } catch {
            throw WorkspaceError.migrationFailed(error.localizedDescription)
        }

        root = newRoot
        if !isOverridden {
            UserDefaults.standard.set(newRoot.path, forKey: Keys.root)
            hasBeenConfigured = true
        }
        try prepare()

        // The old folder is left in place deliberately. Deleting a directory the
        // user chose, that contains the only copy of their unsaved work, on the
        // strength of a copy that has not yet been verified, is not a trade this
        // app makes.
    }

    private func copyTree(from source: URL, to destination: URL, fileManager fm: FileManager) throws {
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [])
        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try copyTree(from: entry, to: target, fileManager: fm)
            } else if !fm.fileExists(atPath: target.path) {
                try fm.copyItem(at: entry, to: target)
            } else {
                let alternate = destination.appendingPathComponent(
                    uniqueName(base: entry.lastPathComponent, in: destination, fileManager: fm))
                try? fm.copyItem(at: entry, to: alternate)
            }
        }
    }

    private func uniqueName(base: String, in directory: URL, fileManager fm: FileManager) -> String {
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            if !fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            counter += 1
        }
    }

    func revealInFinder() {
        try? prepare()
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: - Crash detection

    /// True when the previous run did not shut down cleanly.
    ///
    /// Checked once at launch, before the lock is retaken. A stale lock whose
    /// recorded process is gone means the last run died; a lock whose process is
    /// still alive means a second copy is running, which is reported separately.
    private(set) var previousRunCrashed = false

    func takeLock() {
        let fm = FileManager.default
        if let contents = try? String(contentsOf: lockFile, encoding: .utf8) {
            let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            // kill(pid, 0) tests for the process without signalling it.
            let alive = pid > 0 && kill(pid, 0) == 0
            previousRunCrashed = !alive
            if alive { previousRunCrashed = false }
        }
        try? prepare()
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: lockFile, atomically: true, encoding: .utf8)
        _ = fm
    }

    func releaseLock() {
        try? FileManager.default.removeItem(at: lockFile)
    }

    // MARK: - Backup naming

    /// A backup filename that a person can recognise in the Finder.
    ///
    /// `config.yaml` from any folder becomes `config~3f9a2b1c.yaml`: same stem,
    /// same extension so it opens in the right app, plus enough of the document
    /// id to keep two files of the same name apart.
    static func backupFilename(for document: TextDocument) -> String {
        let shortID = String(document.id.uuidString.prefix(8)).lowercased()
        let source = document.fileURL?.lastPathComponent ?? document.untitledName
        let stem = sanitize((source as NSString).deletingPathExtension)
        var ext = (source as NSString).pathExtension
        if ext.isEmpty { ext = "txt" }
        let safeStem = stem.isEmpty ? "untitled" : stem
        return "\(safeStem)~\(shortID).\(ext)"
    }

    /// Whether a filename is one this app wrote, rather than something else
    /// that happens to be sitting in the folder.
    ///
    /// Adopting orphaned backups means opening whatever is in `Backups/`, so it
    /// has to be able to tell a backup from litter. macOS leaves atomic-write
    /// temporaries like "index.txt.sb-4b911b25-tJHkF8" behind when a write is
    /// interrupted, and one of those was found in a real workspace -- without
    /// this it would have opened as a tab.
    static func isBackupFilename(_ name: String) -> Bool {
        guard !name.hasPrefix("."), !name.contains(".sb-") else { return false }
        let stem = (name as NSString).deletingPathExtension
        guard !(name as NSString).pathExtension.isEmpty,
              let tilde = stem.lastIndex(of: "~") else { return false }
        let id = stem[stem.index(after: tilde)...]
        return id.count == 8 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Reverse of `backupFilename`: "config~3f9a2b1c.yaml" -> "config.yaml".
    ///
    /// The README tells people to do this by hand when recovering without the
    /// app; this is the same rule, for when the app is doing the recovering.
    static func originalName(fromBackup name: String) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard let tilde = stem.lastIndex(of: "~") else { return name }
        let original = String(stem[stem.startIndex..<tilde])
        guard !original.isEmpty else { return name }
        return ext.isEmpty ? original : "\(original).\(ext)"
    }

    private static func sanitize(_ name: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>\u{0}")
        return String(name.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
    }
}
