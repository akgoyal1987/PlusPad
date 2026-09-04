import Foundation

/// How the search string is interpreted. These are Notepad++'s three modes, and
/// keeping Extended separate from Regular expression matters: most people want
/// `\n` and `\t` to mean something without also having `.` and `*` change
/// meaning under them.
enum SearchMode: Int, CaseIterable {
    case normal
    case extended
    case regex

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .extended: return "Extended (\\n, \\t, \\0, \\x...)"
        case .regex: return "Regular expression"
        }
    }
}

struct SearchOptions {
    var mode: SearchMode = .normal
    var matchCase = false
    var wholeWord = false
    var wrapAround = true
    var inSelection = false
    /// Regex only: let `.` match a newline.
    var dotMatchesNewline = false
}

/// A compiled query, ready to run repeatedly without re-parsing.
struct SearchQuery {
    let pattern: String
    let options: SearchOptions
    let regex: NSRegularExpression?
    /// For non-regex modes, the literal text actually being looked for.
    let literal: String
    let error: String?

    var isEmpty: Bool { pattern.isEmpty }
    var isValid: Bool { error == nil && !pattern.isEmpty }

    init(pattern: String, options: SearchOptions) {
        self.pattern = pattern
        self.options = options

        guard !pattern.isEmpty else {
            self.regex = nil; self.literal = ""; self.error = nil
            return
        }

        switch options.mode {
        case .normal:
            self.literal = pattern
            if options.wholeWord {
                // Whole-word on a literal is expressed as a regex so one code
                // path handles boundaries; \Q...\E keeps the literal literal.
                let escaped = NSRegularExpression.escapedPattern(for: pattern)
                var flags: NSRegularExpression.Options = []
                if !options.matchCase { flags.insert(.caseInsensitive) }
                self.regex = try? NSRegularExpression(pattern: "\\b" + escaped + "\\b", options: flags)
            } else {
                self.regex = nil
            }
            self.error = nil

        case .extended:
            let expanded = SearchQuery.expandEscapes(pattern)
            self.literal = expanded
            if options.wholeWord {
                let escaped = NSRegularExpression.escapedPattern(for: expanded)
                var flags: NSRegularExpression.Options = []
                if !options.matchCase { flags.insert(.caseInsensitive) }
                self.regex = try? NSRegularExpression(pattern: "\\b" + escaped + "\\b", options: flags)
            } else {
                self.regex = nil
            }
            self.error = nil

        case .regex:
            self.literal = ""
            var flags: NSRegularExpression.Options = [.anchorsMatchLines]
            if !options.matchCase { flags.insert(.caseInsensitive) }
            if options.dotMatchesNewline { flags.insert(.dotMatchesLineSeparators) }
            let source = options.wholeWord ? "\\b(?:" + pattern + ")\\b" : pattern
            do {
                self.regex = try NSRegularExpression(pattern: source, options: flags)
                self.error = nil
            } catch {
                self.regex = nil
                self.error = (error as NSError).localizedDescription
            }
        }
    }

    /// Expand the Extended-mode escapes. Deliberately a small, fixed set: this
    /// is not a regex, and quietly accepting more would blur the distinction the
    /// mode exists to draw.
    static func expandEscapes(_ s: String) -> String {
        var out = ""
        var chars = Array(s)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\\", i + 1 < chars.count else {
                out.append(chars[i]); i += 1; continue
            }
            let next = chars[i + 1]
            switch next {
            case "n": out.append("\n"); i += 2
            case "r": out.append("\r"); i += 2
            case "t": out.append("\t"); i += 2
            case "0": out.append("\0"); i += 2
            case "a": out.append("\u{07}"); i += 2
            case "b": out.append("\u{08}"); i += 2
            case "f": out.append("\u{0C}"); i += 2
            case "v": out.append("\u{0B}"); i += 2
            case "\\": out.append("\\"); i += 2
            case "x", "u":
                let want = (next == "x") ? 2 : 4
                let digits = String(chars[(i + 2)..<min(i + 2 + want, chars.count)])
                if digits.count == want, let value = UInt32(digits, radix: 16),
                   let scalar = Unicode.Scalar(value) {
                    out.append(Character(scalar))
                    i += 2 + want
                } else {
                    out.append(chars[i]); i += 1
                }
            default:
                out.append(chars[i]); i += 1
            }
        }
        chars = []
        return out
    }
}

/// One found occurrence, with its capture groups so Replace can expand `$1`.
struct SearchMatch {
    var range: NSRange
    var groups: [NSRange]
}

enum FindEngine {

    /// Every match of `query` inside `range` of `text`, in document order.
    static func matches(of query: SearchQuery, in text: NSString, range: NSRange) -> [SearchMatch] {
        guard query.isValid else { return [] }
        let bounded = NSRange(location: max(0, range.location),
                              length: min(range.length, text.length - max(0, range.location)))
        guard bounded.length >= 0 else { return [] }

        if let regex = query.regex {
            return regex.matches(in: text as String, options: [], range: bounded).map { result in
                SearchMatch(range: result.range,
                            groups: (0..<result.numberOfRanges).map { result.range(at: $0) })
            }
        }

        // Literal path. NSString's own search is a good deal faster than
        // building a regex for what is usually a short, plain needle.
        var found: [SearchMatch] = []
        var searchStart = bounded.location
        let end = bounded.location + bounded.length
        let opts: NSString.CompareOptions = query.options.matchCase ? [.literal] : [.caseInsensitive]
        while searchStart < end {
            let scope = NSRange(location: searchStart, length: end - searchStart)
            let hit = text.range(of: query.literal, options: opts, range: scope)
            guard hit.location != NSNotFound else { break }
            found.append(SearchMatch(range: hit, groups: [hit]))
            // Advance by at least one so an empty needle cannot loop forever.
            searchStart = hit.location + max(1, hit.length)
        }
        return found
    }

    /// The next match at or after `from`, wrapping to the top if allowed.
    static func next(_ query: SearchQuery, in text: NSString, from: Int,
                     within scope: NSRange? = nil) -> SearchMatch? {
        guard query.isValid else { return nil }
        let bounds = scope ?? NSRange(location: 0, length: text.length)
        let start = max(from, bounds.location)
        if start < bounds.location + bounds.length {
            let ahead = NSRange(location: start, length: bounds.location + bounds.length - start)
            if let hit = matches(of: query, in: text, range: ahead).first { return hit }
        }
        guard query.options.wrapAround else { return nil }
        return matches(of: query, in: text, range: bounds).first
    }

    /// The last match ending at or before `before`, wrapping to the bottom.
    static func previous(_ query: SearchQuery, in text: NSString, before: Int,
                         within scope: NSRange? = nil) -> SearchMatch? {
        guard query.isValid else { return nil }
        let bounds = scope ?? NSRange(location: 0, length: text.length)
        let end = min(before, bounds.location + bounds.length)
        if end > bounds.location {
            let behind = NSRange(location: bounds.location, length: end - bounds.location)
            if let hit = matches(of: query, in: text, range: behind).last { return hit }
        }
        guard query.options.wrapAround else { return nil }
        return matches(of: query, in: text, range: bounds).last
    }

    /// Build the replacement text for one match.
    ///
    /// In regex mode `$1` and `\1` both name a capture group, because users
    /// arrive from both conventions. In the other modes the template is taken
    /// literally, apart from Extended's escapes.
    static func expand(template: String, for match: SearchMatch, in text: NSString,
                       mode: SearchMode) -> String {
        switch mode {
        case .normal:
            return template
        case .extended:
            return SearchQuery.expandEscapes(template)
        case .regex:
            var out = ""
            let chars = Array(template)
            var i = 0
            while i < chars.count {
                let ch = chars[i]
                if (ch == "$" || ch == "\\"), i + 1 < chars.count, chars[i + 1].isNumber {
                    var j = i + 1
                    var number = ""
                    while j < chars.count, chars[j].isNumber, number.count < 2 {
                        number.append(chars[j]); j += 1
                    }
                    if let index = Int(number), index < match.groups.count {
                        let groupRange = match.groups[index]
                        if groupRange.location != NSNotFound {
                            out += text.substring(with: groupRange)
                        }
                        i = j
                        continue
                    }
                }
                if ch == "\\", i + 1 < chars.count {
                    // Escapes are useful in a replacement too: \n inserts a real
                    // newline rather than the two characters.
                    switch chars[i + 1] {
                    case "n": out.append("\n"); i += 2; continue
                    case "t": out.append("\t"); i += 2; continue
                    case "r": out.append("\r"); i += 2; continue
                    case "\\": out.append("\\"); i += 2; continue
                    default: break
                    }
                }
                out.append(ch)
                i += 1
            }
            return out
        }
    }

    /// Apply `template` to every match in `range`, returning the new text for
    /// that range and how many replacements were made.
    ///
    /// Replacements are computed back to front so each one's range stays valid
    /// against the text it was found in.
    static func replaceAll(_ query: SearchQuery, template: String, in storage: NSMutableString,
                           range: NSRange) -> Int {
        let hits = matches(of: query, in: storage, range: range)
        guard !hits.isEmpty else { return 0 }
        for hit in hits.reversed() {
            let replacement = expand(template: template, for: hit, in: storage, mode: query.options.mode)
            storage.replaceCharacters(in: hit.range, with: replacement)
        }
        return hits.count
    }
}
