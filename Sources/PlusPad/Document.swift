import AppKit

/// One open buffer.
///
/// A document is not required to have a file. An untitled buffer is a
/// first-class thing that survives quitting, relaunching and being closed, and
/// it is never nagged about. `fileURL` is therefore optional everywhere and the
/// dirty flag is not a reason to interrupt anyone.
final class TextDocument {

    let id: UUID
    private(set) var fileURL: URL?

    /// The TextKit 1 stack, built explicitly. Constructing the storage,
    /// layout manager and container by hand is what keeps this on TextKit 1,
    /// where the gutter ruler and the attribute work below are supported.
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer()

    var encoding: FileEncoding = .utf8
    var lineEnding: LineEnding = .systemDefault

    /// The language in force. `languageIsExplicit` records that the user chose
    /// it, so re-detecting on save does not overrule them.
    var language: LanguageDef = LanguageRegistry.plainText
    var languageIsExplicit = false

    let lineIndex = LineIndex()
    let highlighter = SyntaxHighlighter()
    let foldModel = FoldModel()

    /// Restored or last-known editor state. Kept on the document rather than the
    /// view so a tab that has been restored but never opened still remembers
    /// where the cursor was.
    var selectedRange = NSRange(location: 0, length: 0)
    var scrollOffset: CGFloat = 0
    var bookmarks: Set<Int> = []

    /// Name shown on the tab for a document with no file yet.
    var untitledName: String

    /// Modification date of the file when we last read or wrote it, used to
    /// notice that something else changed it underneath us.
    var lastKnownDiskDate: Date?
    /// Set when the file existed at restore time but has since disappeared.
    var fileMissing = false

    /// Content as of the last save, so the dirty flag reflects the text rather
    /// than merely whether an edit event fired. Typing a character and deleting
    /// it again leaves the document clean, which matters when the alternative is
    /// a permanently dirty tab that nags forever.
    private var savedSnapshot: String = ""
    private var cachedDirty = false
    private var cachedDirtyGeneration = -1
    private var generation = 0

    weak var delegate: TextDocumentDelegate?

    init(id: UUID = UUID(), untitledName: String) {
        self.id = id
        self.untitledName = untitledName
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        // A very large container height keeps the layout manager from capping
        // long documents; the scroll view provides the real bounds.
        textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        lineIndex.rebuild(textStorage.string as NSString)
    }

    // MARK: - Identity

    var displayName: String {
        fileURL?.lastPathComponent ?? untitledName
    }

    var directoryDisplay: String {
        fileURL?.deletingLastPathComponent().path ?? "Not saved"
    }

    var hasFile: Bool { fileURL != nil }

    var isDirty: Bool {
        if cachedDirtyGeneration == generation { return cachedDirty }
        let dirty = textStorage.string != savedSnapshot
        cachedDirty = dirty
        cachedDirtyGeneration = generation
        return dirty
    }

    /// Called by the editor after any change to the text.
    func noteTextChanged() {
        generation += 1
    }

    var text: String { textStorage.string }

    // MARK: - Loading

    /// Populate from bytes already read off disk.
    func adopt(decoded: DecodedFile, url: URL?, modificationDate: Date?) {
        fileURL = url
        encoding = decoded.encoding
        lineEnding = decoded.lineEnding
        lastKnownDiskDate = modificationDate
        fileMissing = false
        replaceAllText(decoded.text)
        savedSnapshot = decoded.text
        generation += 1
        cachedDirtyGeneration = -1
        if !languageIsExplicit {
            language = LanguageRegistry.detect(url: url, firstLine: firstLine())
            highlighter.language = language
        }
    }

    /// Replace the buffer wholesale, e.g. on load or on an encoding
    /// reinterpretation, without going through the undo stack.
    func replaceAllText(_ new: String) {
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: new)
        textStorage.endEditing()
        lineIndex.rebuild(textStorage.string as NSString)
        highlighter.invalidateAll()
        generation += 1
        cachedDirtyGeneration = -1
    }

    func firstLine() -> String {
        let s = textStorage.string as NSString
        guard s.length > 0 else { return "" }
        let end = s.range(of: "\n", options: [], range: NSRange(location: 0, length: min(512, s.length)))
        let cut = (end.location == NSNotFound) ? min(512, s.length) : end.location
        return s.substring(to: cut)
    }

    // MARK: - Saving

    enum SaveError: LocalizedError {
        case cannotEncode(FileEncoding)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotEncode(let encoding):
                return "The text cannot be written as \(encoding.displayName). Choose a different encoding, or use UTF-8."
            case .writeFailed(let message):
                return message
            }
        }
    }

    /// Write to `url`, or to the document's own file when `url` is nil.
    @discardableResult
    func save(to url: URL? = nil) throws -> URL {
        guard let target = url ?? fileURL else {
            throw SaveError.writeFailed("This document has no file to save to.")
        }
        let body = text
        guard let data = TextCodec.encode(body, as: encoding, lineEnding: lineEnding) else {
            throw SaveError.cannotEncode(encoding)
        }
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw SaveError.writeFailed(error.localizedDescription)
        }

        fileURL = target
        fileMissing = false
        savedSnapshot = body
        generation += 1
        cachedDirtyGeneration = -1
        lastKnownDiskDate = (try? FileManager.default
            .attributesOfItem(atPath: target.path)[.modificationDate] as? Date) ?? Date()

        if !languageIsExplicit {
            let detected = LanguageRegistry.detect(url: target, firstLine: firstLine())
            if detected.name != language.name {
                language = detected
                highlighter.language = detected
                delegate?.documentLanguageChanged(self)
            }
        }
        delegate?.documentStateChanged(self)
        return target
    }

    /// Reattach a restored buffer to the file it came from, without reading it.
    /// The text is already in place from the backup; only the association is
    /// missing, and going through `adopt` would overwrite the recovered text
    /// with whatever is on disk.
    func fileURLRestored(_ url: URL?) {
        fileURL = url
        if url != nil, !FileManager.default.fileExists(atPath: url!.path) {
            fileMissing = true
        }
    }

    /// Mark the current text as the saved baseline without writing anything.
    /// Used when a restored buffer matches what is on disk.
    func acceptCurrentTextAsSaved() {
        savedSnapshot = text
        generation += 1
        cachedDirtyGeneration = -1
    }

    /// Force the document dirty against a known-different baseline, used when a
    /// restored backup differs from the file on disk.
    func markDirty(against baseline: String) {
        savedSnapshot = baseline
        generation += 1
        cachedDirtyGeneration = -1
    }

    // MARK: - External changes

    /// Whether the file has changed on disk since we last read or wrote it.
    func diskChangedExternally() -> Bool {
        guard let url = fileURL else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return !fileMissing
        }
        guard let date = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date else { return false }
        guard let known = lastKnownDiskDate else { return false }
        // A one-second slack absorbs filesystems that store whole seconds.
        return date.timeIntervalSince(known) > 1.0
    }

    /// Re-read the file, discarding in-memory edits.
    func revertFromDisk() throws {
        guard let url = fileURL else { return }
        let data = try Data(contentsOf: url)
        let decoded = TextCodec.decode(data, forcing: encoding)
        let date = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        adopt(decoded: decoded, url: url, modificationDate: date ?? Date())
        delegate?.documentStateChanged(self)
    }

    /// Re-read the bytes on disk under a different encoding, discarding edits.
    func reinterpret(as newEncoding: FileEncoding) throws {
        guard let url = fileURL else {
            encoding = newEncoding
            delegate?.documentStateChanged(self)
            return
        }
        let data = try Data(contentsOf: url)
        let decoded = TextCodec.decode(data, forcing: newEncoding)
        let date = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        adopt(decoded: decoded, url: url, modificationDate: date ?? Date())
        delegate?.documentStateChanged(self)
    }

    /// Keep the text as it is and simply write it differently next time.
    func convert(to newEncoding: FileEncoding) {
        encoding = newEncoding
        generation += 1
        cachedDirtyGeneration = -1
        delegate?.documentStateChanged(self)
    }

    func convert(to newLineEnding: LineEnding) {
        lineEnding = newLineEnding
        generation += 1
        cachedDirtyGeneration = -1
        delegate?.documentStateChanged(self)
    }

    func setLanguage(_ new: LanguageDef, explicit: Bool) {
        language = new
        languageIsExplicit = explicit
        highlighter.language = new
        delegate?.documentLanguageChanged(self)
        delegate?.documentStateChanged(self)
    }
}

protocol TextDocumentDelegate: AnyObject {
    func documentStateChanged(_ document: TextDocument)
    func documentLanguageChanged(_ document: TextDocument)
}
