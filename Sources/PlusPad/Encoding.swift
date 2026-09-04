import AppKit

/// Text encodings PlusPad can read and write.
///
/// Notepad++ treats encoding as a visible, switchable property of a document
/// rather than something guessed once and hidden. This enum is the model behind
/// that: every document carries one, the status bar shows it, and the Encoding
/// menu can either reinterpret the bytes on disk or convert the text in place.
enum FileEncoding: String, CaseIterable {
    case utf8
    case utf8BOM
    case utf16LE
    case utf16BE
    case utf32LE
    case utf32BE
    case windows1252
    case iso8859_1
    case macRoman
    case shiftJIS
    case gb18030
    case big5
    case koi8r
    case windows1251

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 BOM"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .utf32LE: return "UTF-32 LE"
        case .utf32BE: return "UTF-32 BE"
        case .windows1252: return "Windows-1252"
        case .iso8859_1: return "ISO-8859-1"
        case .macRoman: return "Mac Roman"
        case .shiftJIS: return "Shift-JIS"
        case .gb18030: return "GB18030"
        case .big5: return "Big5"
        case .koi8r: return "KOI8-R"
        case .windows1251: return "Windows-1251"
        }
    }

    /// The Cocoa encoding used for the actual byte conversion.
    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .utf32LE: return .utf32LittleEndian
        case .utf32BE: return .utf32BigEndian
        case .windows1252: return .windowsCP1252
        case .iso8859_1: return .isoLatin1
        case .macRoman: return .macOSRoman
        case .shiftJIS: return .shiftJIS
        case .gb18030: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .big5: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case .koi8r: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))
        case .windows1251: return .windowsCP1251
        }
    }

    /// Bytes written ahead of the text. Only the Unicode encodings carry one,
    /// and UTF-8 only when the user has explicitly asked for `utf8BOM`.
    var byteOrderMark: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        case .utf32LE: return [0xFF, 0xFE, 0x00, 0x00]
        case .utf32BE: return [0x00, 0x00, 0xFE, 0xFF]
        default: return []
        }
    }

    /// Encodings offered in the menu, grouped the way Notepad++ groups them.
    static var menuGroups: [(String, [FileEncoding])] {
        [
            ("Unicode", [.utf8, .utf8BOM, .utf16LE, .utf16BE, .utf32LE, .utf32BE]),
            ("Western", [.windows1252, .iso8859_1, .macRoman]),
            ("Cyrillic", [.windows1251, .koi8r]),
            ("East Asian", [.shiftJIS, .gb18030, .big5]),
        ]
    }
}

/// How a document terminates its lines.
///
/// Kept separate from the text itself: the buffer in memory is always LF, and
/// the document's `lineEnding` is applied on write. That keeps every regex,
/// line-count and column calculation in the editor working on one form.
enum LineEnding: String, CaseIterable {
    case lf
    case crlf
    case cr

    var displayName: String {
        switch self {
        case .lf: return "Unix (LF)"
        case .crlf: return "Windows (CR LF)"
        case .cr: return "Macintosh (CR)"
        }
    }

    var shortName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    var literal: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    /// The platform default for a brand new document.
    static var systemDefault: LineEnding { .lf }
}

/// Result of reading a file off disk.
struct DecodedFile {
    var text: String
    var encoding: FileEncoding
    var lineEnding: LineEnding
    /// True when the bytes did not decode cleanly and a lossy fallback was used.
    var hadDecodingFallback: Bool
}

enum TextCodec {

    /// Read `data` into a normalised (LF-only) string, working out its encoding
    /// and original line ending.
    ///
    /// Detection order matters. A byte order mark is definitive, so it wins. A
    /// strict UTF-8 decode is next because it has a very low false-positive rate
    /// on non-UTF-8 bytes. Only then do we fall back to a byte-frequency guess,
    /// and finally to Windows-1252, which never fails and so guarantees the file
    /// always opens rather than refusing.
    static func decode(_ data: Data, forcing forced: FileEncoding? = nil) -> DecodedFile {
        if let forced {
            let body = stripBOM(data, for: forced)
            let text = String(data: body, encoding: forced.stringEncoding)
            let raw = text ?? String(decoding: body, as: UTF8.self)
            return finish(raw, forced, fallback: text == nil)
        }

        if let bomEncoding = detectBOM(data) {
            let body = stripBOM(data, for: bomEncoding)
            if let text = String(data: body, encoding: bomEncoding.stringEncoding) {
                return finish(text, bomEncoding, fallback: false)
            }
        }

        // UTF-16 without a BOM is common on Windows-authored files. A high
        // proportion of interleaved NUL bytes is the giveaway; plain text in a
        // single-byte encoding essentially never contains NULs at all.
        if let guess = detectBOMlessUTF16(data),
           let text = String(data: data, encoding: guess.stringEncoding) {
            return finish(text, guess, fallback: false)
        }

        if let text = String(data: data, encoding: .utf8), !containsNUL(data) {
            return finish(text, .utf8, fallback: false)
        }

        // NUL bytes present and no confident UTF-16 verdict: take the better of
        // the two UTF-16 orderings rather than emitting text with a NUL between
        // every character.
        if containsNUL(data) {
            for candidate in [FileEncoding.utf16LE, .utf16BE] {
                if let text = String(data: data, encoding: candidate.stringEncoding),
                   !text.unicodeScalars.contains(where: { $0.value == 0 }) {
                    return finish(text, candidate, fallback: false)
                }
            }
        }

        if let text = String(data: data, encoding: .windowsCP1252) {
            return finish(text, .windows1252, fallback: false)
        }

        // Nothing decoded cleanly; take the lossy path so the file still opens.
        return finish(String(decoding: data, as: UTF8.self), .utf8, fallback: true)
    }

    /// Serialise `text` for writing, applying the BOM and the line ending.
    static func encode(_ text: String, as encoding: FileEncoding, lineEnding: LineEnding) -> Data? {
        let bodyText = applyLineEnding(text, lineEnding)
        guard let body = bodyText.data(using: encoding.stringEncoding, allowLossyConversion: true) else {
            return nil
        }
        var out = Data(encoding.byteOrderMark)
        out.append(body)
        return out
    }

    /// Convert an LF-only string to the requested terminator.
    static func applyLineEnding(_ text: String, _ ending: LineEnding) -> String {
        guard ending != .lf else { return text }
        return text.replacingOccurrences(of: "\n", with: ending.literal)
    }

    /// Collapse every terminator style to LF, which is the only form the editor
    /// buffer ever holds.
    static func normalizeToLF(_ text: String) -> String {
        guard text.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Which terminator dominates the raw text. Mixed files report whichever
    /// style occurs most, matching how Notepad++ labels them.
    static func detectLineEnding(_ raw: String) -> LineEnding {
        var crlf = 0, lf = 0, cr = 0
        var previousWasCR = false
        for unit in raw.utf8 {
            if unit == 0x0A {
                if previousWasCR { crlf += 1 } else { lf += 1 }
                previousWasCR = false
            } else {
                if previousWasCR { cr += 1 }
                previousWasCR = (unit == 0x0D)
            }
        }
        if previousWasCR { cr += 1 }
        if crlf == 0 && lf == 0 && cr == 0 { return .systemDefault }
        if crlf >= lf && crlf >= cr { return .crlf }
        if lf >= cr { return .lf }
        return .cr
    }

    // MARK: - Detection internals

    private static func finish(_ raw: String, _ encoding: FileEncoding, fallback: Bool) -> DecodedFile {
        let ending = detectLineEnding(raw)
        return DecodedFile(text: normalizeToLF(raw),
                           encoding: encoding,
                           lineEnding: ending,
                           hadDecodingFallback: fallback)
    }

    private static func detectBOM(_ data: Data) -> FileEncoding? {
        let bytes = [UInt8](data.prefix(4))
        // UTF-32 is checked before UTF-16: FF FE 00 00 is a valid prefix of both,
        // and testing the shorter mark first would misread every UTF-32 LE file.
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LE }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BE }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if bytes.starts(with: [0xFF, 0xFE]) { return .utf16LE }
        if bytes.starts(with: [0xFE, 0xFF]) { return .utf16BE }
        return nil
    }

    private static func stripBOM(_ data: Data, for encoding: FileEncoding) -> Data {
        let mark = encoding.byteOrderMark
        guard !mark.isEmpty, data.count >= mark.count,
              [UInt8](data.prefix(mark.count)) == mark else { return data }
        return data.dropFirst(mark.count)
    }

    private static func detectBOMlessUTF16(_ data: Data) -> FileEncoding? {
        let sample = [UInt8](data.prefix(4096))
        // Two code units is the least that can show a pattern. The previous
        // sixteen-byte floor meant a short UTF-16 file fell through to the UTF-8
        // branch, which "succeeds" on NUL bytes and produced text with a NUL
        // between every character.
        guard sample.count >= 4, sample.count % 2 == 0 else { return nil }

        var evenNULs = 0, oddNULs = 0
        for (index, byte) in sample.enumerated() where byte == 0 {
            if index % 2 == 0 { evenNULs += 1 } else { oddNULs += 1 }
        }
        let pairs = sample.count / 2
        guard pairs > 0 else { return nil }

        // Ordinary single-byte text contains no NULs at all, so a strong,
        // side-consistent run of them means one half of a UTF-16 code unit.
        // Written as multiplications because `pairs / 8` truncates to zero on
        // small samples, which made the old test impossible to satisfy.
        if oddNULs * 4 >= pairs * 3 && evenNULs * 8 <= pairs { return .utf16LE }
        if evenNULs * 4 >= pairs * 3 && oddNULs * 8 <= pairs { return .utf16BE }
        return nil
    }

    /// True when the bytes contain a NUL, which plain text in any single-byte
    /// or UTF-8 encoding never does.
    private static func containsNUL(_ data: Data) -> Bool {
        data.prefix(4096).contains(0)
    }
}
