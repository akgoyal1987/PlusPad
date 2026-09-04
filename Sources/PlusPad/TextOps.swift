import Foundation
import CryptoKit

/// The line and text transforms behind the Edit menu.
///
/// Every function here is pure: text in, text out, no editor state. That makes
/// them trivially testable and means the same transform can be driven from a
/// menu item, a keyboard shortcut or a macro without three implementations.
enum TextOps {

    // MARK: - Case

    static func upper(_ s: String) -> String { s.uppercased() }
    static func lower(_ s: String) -> String { s.lowercased() }

    /// Every word's first letter capitalised, the rest lowered.
    static func properCase(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var atWordStart = true
        for ch in s {
            if ch.isLetter || ch.isNumber {
                out.append(atWordStart ? Character(ch.uppercased()) : Character(ch.lowercased()))
                atWordStart = false
            } else {
                out.append(ch)
                // An apostrophe keeps a word going, so "o'brien" does not become
                // "O'Brien" split into two words -- but "don't" would give
                // "Don'T", so only a following letter+letter pair continues it.
                atWordStart = (ch != "'")
            }
        }
        return out
    }

    /// First letter of each sentence capitalised.
    static func sentenceCase(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var atSentenceStart = true
        for ch in s {
            if ch.isLetter {
                out.append(atSentenceStart ? Character(ch.uppercased()) : Character(ch.lowercased()))
                atSentenceStart = false
            } else {
                out.append(ch)
                if ch == "." || ch == "!" || ch == "?" || ch == "\n" { atSentenceStart = true }
            }
        }
        return out
    }

    /// Swap the case of every character. Notepad++ calls this iNVERT cASE.
    static func invertCase(_ s: String) -> String {
        String(s.map { ch in
            if ch.isUppercase { return Character(ch.lowercased()) }
            if ch.isLowercase { return Character(ch.uppercased()) }
            return ch
        })
    }

    /// snake_case, kebab-case and spaced words to camelCase.
    static func camelCase(_ s: String, upperFirst: Bool = false) -> String {
        var out = ""
        var capitaliseNext = upperFirst
        for ch in s {
            if ch == "_" || ch == "-" || ch == " " {
                capitaliseNext = true
                continue
            }
            out.append(capitaliseNext ? Character(ch.uppercased()) : ch)
            capitaliseNext = false
        }
        return out
    }

    /// camelCase and PascalCase to snake_case.
    static func snakeCase(_ s: String) -> String {
        var out = ""
        var previousWasLower = false
        for ch in s {
            if ch.isUppercase && previousWasLower { out.append("_") }
            if ch == "-" || ch == " " { out.append("_"); previousWasLower = false; continue }
            out.append(Character(ch.lowercased()))
            previousWasLower = ch.isLowercase || ch.isNumber
        }
        return out
    }

    // MARK: - Lines

    /// Split preserving the fact that a trailing newline means a final empty
    /// line, which `components(separatedBy:)` and `split` disagree about.
    static func lines(_ s: String) -> [String] {
        s.components(separatedBy: "\n")
    }

    static func joined(_ parts: [String]) -> String {
        parts.joined(separator: "\n")
    }

    enum SortMode {
        case ascending, descending
        case ascendingCaseInsensitive, descendingCaseInsensitive
        case ascendingNumeric, descendingNumeric
        case reverse, shuffle
    }

    static func sortLines(_ text: String, _ mode: SortMode) -> String {
        var parts = lines(text)
        // A trailing newline produces an empty final element that must not be
        // sorted to the top; hold it aside and put it back.
        let hasTrailingNewline = parts.count > 1 && parts.last == ""
        if hasTrailingNewline { parts.removeLast() }

        switch mode {
        case .ascending:
            parts.sort { $0.compare($1, options: [], range: nil, locale: nil) == .orderedAscending }
        case .descending:
            parts.sort { $0.compare($1, options: [], range: nil, locale: nil) == .orderedDescending }
        case .ascendingCaseInsensitive:
            parts.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        case .descendingCaseInsensitive:
            parts.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedDescending }
        case .ascendingNumeric:
            parts.sort { numericKey($0) < numericKey($1) }
        case .descendingNumeric:
            parts.sort { numericKey($0) > numericKey($1) }
        case .reverse:
            parts.reverse()
        case .shuffle:
            parts.shuffle()
        }

        if hasTrailingNewline { parts.append("") }
        return joined(parts)
    }

    /// Leading number on a line, for numeric sorts. Lines with no number sort
    /// below every line that has one rather than all colliding at zero.
    private static func numericKey(_ line: String) -> Double {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var digits = ""
        var seenDot = false
        for ch in trimmed {
            if ch.isNumber { digits.append(ch) }
            else if ch == "-" && digits.isEmpty { digits.append(ch) }
            else if ch == "." && !seenDot && !digits.isEmpty { digits.append(ch); seenDot = true }
            else { break }
        }
        return Double(digits) ?? .greatestFiniteMagnitude
    }

    /// Drop repeats, keeping the first occurrence and the original order.
    static func removeDuplicateLines(_ text: String, ignoringCase: Bool = false) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for line in lines(text) {
            let key = ignoringCase ? line.lowercased() : line
            if seen.insert(key).inserted { out.append(line) }
        }
        return joined(out)
    }

    /// Remove consecutive duplicates only, the `uniq` behaviour.
    static func removeConsecutiveDuplicateLines(_ text: String) -> String {
        var out: [String] = []
        for line in lines(text) where out.last != line { out.append(line) }
        return joined(out)
    }

    static func removeEmptyLines(_ text: String, alsoBlank: Bool = true) -> String {
        joined(lines(text).filter { line in
            alsoBlank ? !line.trimmingCharacters(in: .whitespaces).isEmpty : !line.isEmpty
        })
    }

    static func trimTrailingWhitespace(_ text: String) -> String {
        joined(lines(text).map { line -> String in
            var s = Substring(line)
            while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
            return String(s)
        })
    }

    static func trimLeadingWhitespace(_ text: String) -> String {
        joined(lines(text).map { line -> String in
            var s = Substring(line)
            while let first = s.first, first == " " || first == "\t" { s = s.dropFirst() }
            return String(s)
        })
    }

    static func tabsToSpaces(_ text: String, width: Int) -> String {
        joined(lines(text).map { line -> String in
            var out = ""
            var column = 0
            for ch in line {
                if ch == "\t" {
                    let pad = width - (column % width)
                    out.append(String(repeating: " ", count: pad))
                    column += pad
                } else {
                    out.append(ch)
                    column += 1
                }
            }
            return out
        })
    }

    /// Convert runs of spaces back to tabs, leading whitespace only. Touching
    /// interior spaces would corrupt aligned comments and string literals.
    static func leadingSpacesToTabs(_ text: String, width: Int) -> String {
        joined(lines(text).map { line -> String in
            var indent = 0
            var index = line.startIndex
            while index < line.endIndex, line[index] == " " || line[index] == "\t" {
                indent += (line[index] == "\t") ? width - (indent % width) : 1
                index = line.index(after: index)
            }
            let tabs = indent / width
            let spaces = indent % width
            return String(repeating: "\t", count: tabs) + String(repeating: " ", count: spaces) + String(line[index...])
        })
    }

    /// Join every line into one, separated by `separator`.
    static func joinLines(_ text: String, separator: String = " ") -> String {
        lines(text).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    // MARK: - Indentation

    static func indent(_ text: String, using unit: String) -> String {
        joined(lines(text).map { $0.isEmpty ? $0 : unit + $0 })
    }

    /// Remove one indent level, tolerating lines indented with the other kind of
    /// whitespace or with less than a full level.
    static func outdent(_ text: String, width: Int, usesTabs: Bool) -> String {
        joined(lines(text).map { line -> String in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            var removed = 0
            var index = line.startIndex
            while removed < width, index < line.endIndex, line[index] == " " {
                index = line.index(after: index)
                removed += 1
            }
            return String(line[index...])
        })
    }

    /// Toggle a line comment on every line in `text`.
    ///
    /// The whole block is commented unless every non-blank line is already
    /// commented, which is the behaviour that makes the shortcut safe to hold
    /// down: it never half-comments a selection.
    static func toggleLineComment(_ text: String, token: String) -> String {
        let parts = lines(text)
        let meaningful = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !meaningful.isEmpty else { return text }

        let allCommented = meaningful.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(token)
        }

        if allCommented {
            return joined(parts.map { line -> String in
                guard let range = line.range(of: token) else { return line }
                var result = line
                result.removeSubrange(range)
                // Also eat the single space conventionally written after the
                // token, so a round trip returns the original text exactly.
                if result[range.lowerBound...].hasPrefix(" ") {
                    result.remove(at: range.lowerBound)
                }
                return result
            })
        }

        // Comment at the shallowest common indent so the block stays aligned.
        let indentWidth = meaningful.map { line -> Int in
            line.prefix { $0 == " " || $0 == "\t" }.count
        }.min() ?? 0

        return joined(parts.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            let cut = line.index(line.startIndex, offsetBy: min(indentWidth, line.count))
            return String(line[..<cut]) + token + " " + String(line[cut...])
        })
    }

    // MARK: - Conversions

    static func base64Encode(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    static func base64Decode(_ s: String) -> String? {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func urlEncode(_ s: String) -> String {
        // The default allowed sets leave `&`, `=` and `+` intact, which is wrong
        // for a value being placed into a query string.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func urlDecode(_ s: String) -> String? { s.removingPercentEncoding }

    static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha1(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Escape a string so it can be pasted inside source-code quotes.
    static func escapeForCode(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out
    }

    static func unescapeFromCode(_ s: String) -> String {
        var out = ""
        var iterator = s.makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? iterator.next() {
            pending = nil
            guard ch == "\\" else { out.append(ch); continue }
            guard let next = iterator.next() else { out.append(ch); break }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "\\": out.append("\\")
            case "\"": out.append("\"")
            case "'": out.append("'")
            default: out.append(ch); pending = next
            }
        }
        return out
    }

    // MARK: - Statistics

    struct Stats {
        var characters: Int
        var charactersNoSpaces: Int
        var words: Int
        var lines: Int
        var bytesUTF8: Int
    }

    static func stats(_ s: String) -> Stats {
        let wordCount = s.split(whereSeparator: { $0.isWhitespace }).count
        return Stats(
            characters: s.count,
            charactersNoSpaces: s.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 },
            words: wordCount,
            lines: s.isEmpty ? 1 : s.components(separatedBy: "\n").count,
            bytesUTF8: s.utf8.count)
    }
}
