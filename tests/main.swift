import AppKit

// Tests for the parts of PlusPad that are pure logic: encoding detection, the
// incremental line index, the syntax scanner's cross-line state, the line
// transforms, and the search engine.
//
// Deliberately not a UI test. These are the pieces where a defect is silent --
// a line index that drifts by one shows up as highlighting on the wrong line
// three screens down, not as a crash -- and they are the pieces that can be
// checked without a window server.
//
// Run with ./run-tests.sh  (named main.swift because Swift only allows
// top-level statements in a file with that name)

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !condition {
        failures += 1
        let extra = detail()
        print("FAIL  \(label)" + (extra.isEmpty ? "" : "\n      \(extra)"))
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    check(actual == expected, label, "got \(actual)\n      want \(expected)")
}

func section(_ name: String) { print("\n\(name)") }

// MARK: - Encoding

section("TextCodec")

do {
    var utf8BOM = Data([0xEF, 0xBB, 0xBF])
    utf8BOM.append(contentsOf: Array("héllo".utf8))
    let decoded = TextCodec.decode(utf8BOM)
    equal(decoded.encoding, .utf8BOM, "UTF-8 BOM is detected")
    equal(decoded.text, "héllo", "UTF-8 BOM is stripped from the text")
}

do {
    // FF FE 00 00 is a valid prefix of both UTF-32 LE and UTF-16 LE. Checking
    // the shorter mark first would misread every UTF-32 LE file, so this pins
    // the ordering.
    let data = Data([0xFF, 0xFE, 0x00, 0x00]) + Data([0x41, 0x00, 0x00, 0x00])
    equal(TextCodec.decode(data).encoding, .utf32LE, "UTF-32 LE wins over UTF-16 LE on FF FE 00 00")
}

do {
    let text = "abcdef"
    var utf16 = Data()
    for unit in text.utf16 { utf16.append(UInt8(unit & 0xFF)); utf16.append(UInt8(unit >> 8)) }
    let decoded = TextCodec.decode(utf16)
    equal(decoded.encoding, .utf16LE, "BOM-less UTF-16 LE is detected from NUL placement")
    equal(decoded.text, text, "BOM-less UTF-16 LE decodes correctly")
}

do {
    equal(TextCodec.detectLineEnding("a\r\nb\r\nc"), .crlf, "CRLF detected")
    equal(TextCodec.detectLineEnding("a\nb\nc"), .lf, "LF detected")
    equal(TextCodec.detectLineEnding("a\rb\rc"), .cr, "CR detected")
    equal(TextCodec.detectLineEnding("a\r\nb\nc\n"), .lf, "mixed reports the majority")
    equal(TextCodec.normalizeToLF("a\r\nb\rc\n"), "a\nb\nc\n", "every terminator normalises to LF")
}

do {
    let data = TextCodec.encode("a\nb", as: .utf8BOM, lineEnding: .crlf)
    equal([UInt8](data!.prefix(3)), [0xEF, 0xBB, 0xBF], "BOM is written")
    equal(String(data: data!.dropFirst(3), encoding: .utf8), "a\r\nb", "line ending applied on write")
}

// MARK: - LineIndex

section("LineIndex")

/// The incremental path must agree with a full rebuild after every edit. This is
/// checked against randomly generated edits rather than a handful of cases,
/// because the failure mode is an off-by-one on a boundary nobody thinks to
/// write a case for.
do {
    var generator = SystemRandomNumberGenerator()
    var mismatches = 0
    var sampleFailure = ""

    for trial in 0..<400 {
        let seedLines = Int.random(in: 1...40, using: &generator)
        var text = (0..<seedLines).map { "line \($0) some text" }.joined(separator: "\n")
        if Bool.random(using: &generator) { text += "\n" }

        let incremental = LineIndex()
        incremental.rebuild(text as NSString)

        for _ in 0..<8 {
            let storage = NSMutableString(string: text)
            guard storage.length > 0 else { break }
            let location = Int.random(in: 0...storage.length, using: &generator)
            let removable = min(storage.length - location, Int.random(in: 0...6, using: &generator))
            let inserts = ["", "x", "\n", "\n\n", "ab\ncd", "\r\n", "hello world", "\n\nzz\n"]
            let insert = inserts.randomElement(using: &generator)!

            let editedRange = NSRange(location: location, length: (insert as NSString).length)
            let delta = (insert as NSString).length - removable
            storage.replaceCharacters(in: NSRange(location: location, length: removable), with: insert)
            text = storage as String

            incremental.update(text as NSString, editedRange: editedRange, delta: delta)

            let fresh = LineIndex()
            fresh.rebuild(text as NSString)
            if incremental.starts != fresh.starts {
                mismatches += 1
                if sampleFailure.isEmpty {
                    sampleFailure = "trial \(trial): incremental \(incremental.starts) vs fresh \(fresh.starts)"
                }
                break
            }
        }
    }
    check(mismatches == 0, "incremental line index matches a full rebuild over 400 random edit runs",
          "\(mismatches) mismatches; first: \(sampleFailure)")
}

do {
    let index = LineIndex()
    index.rebuild("alpha\nbeta\ngamma" as NSString)
    equal(index.lineCount, 3, "line count")
    equal(index.lineIndex(containing: 0), 0, "offset 0 is line 0")
    equal(index.lineIndex(containing: 5), 0, "the newline belongs to the line it ends")
    equal(index.lineIndex(containing: 6), 1, "offset after newline is the next line")
    equal(index.lineIndex(containing: 15), 2, "last offset is the last line")
    equal(index.range(ofLine: 1), NSRange(location: 6, length: 5), "line range includes its terminator")
}

do {
    // A trailing newline means a real, empty final line: the cursor can sit on
    // it and the gutter must number it.
    let index = LineIndex()
    index.rebuild("a\nb\n" as NSString)
    equal(index.lineCount, 3, "a trailing newline creates a final empty line")
}

// MARK: - Syntax scanning

section("SyntaxHighlighter")

func tokenKinds(_ source: String, _ languageName: String) -> [(String, TokenKind)] {
    let language = LanguageRegistry.named(languageName)!
    let highlighter = SyntaxHighlighter(language: language)
    let text = source as NSString
    let index = LineIndex()
    index.rebuild(text)
    return highlighter.tokens(in: text, index: index, firstLine: 0, lastLine: index.lineCount - 1)
        .map { (text.substring(with: $0.range), $0.kind) }
}

do {
    let tokens = tokenKinds("let url = \"http://example.com\" // real comment", "Swift")
    let strings = tokens.filter { $0.1 == .string }.map(\.0)
    let comments = tokens.filter { $0.1 == .comment }.map(\.0)
    check(strings.contains("\"http://example.com\""), "a URL inside a string stays one string token",
          "strings: \(strings)")
    equal(comments, ["// real comment"], "only the trailing // starts a comment")
}

do {
    let source = """
    /* opens here
       still inside
       closes */ let after = 1
    """
    let tokens = tokenKinds(source, "Swift")
    let comments = tokens.filter { $0.1 == .comment || $0.1 == .docComment }
    check(comments.count == 3, "a block comment carries across all three lines",
          "got \(comments.count) comment spans")
    check(tokens.contains { $0.0 == "let" && $0.1 == .keyword },
          "code after the block comment closes is highlighted again")
}

do {
    let source = """
    def f():
        \"\"\"Doc with # hash and 'quotes'.

        Second paragraph.
        \"\"\"
        return 1
    """
    let tokens = tokenKinds(source, "Python")
    check(tokens.contains { $0.0 == "return" && $0.1 == .keyword },
          "code after a triple-quoted string is highlighted again")
    let comments = tokens.filter { $0.1 == .comment }
    check(comments.isEmpty, "a # inside a triple-quoted string does not start a comment",
          "got \(comments.map(\.0))")
}

do {
    let tokens = tokenKinds("x = 1 # trailing\ny = 2", "Python")
    equal(tokens.filter { $0.1 == .comment }.map(\.0), ["# trailing"],
          "a line comment ends at the newline")
    check(tokens.contains { $0.0 == "2" && $0.1 == .number }, "the next line is scanned normally")
}

do {
    let tokens = tokenKinds("{\"name\": \"value\", \"n\": 12}", "JSON")
    check(tokens.contains { $0.0 == "\"name\"" && $0.1 == .attribute },
          "a JSON string followed by a colon is a key")
    check(tokens.contains { $0.0 == "\"value\"" && $0.1 == .string },
          "a JSON string not followed by a colon is a value")
    check(tokens.contains { $0.0 == "12" && $0.1 == .number }, "JSON numbers")
}

do {
    let tokens = tokenKinds("<a href=\"x.html\" class='c'>text</a>", "HTML")
    check(tokens.contains { $0.0 == "a" && $0.1 == .tag }, "tag name")
    check(tokens.contains { $0.0 == "href" && $0.1 == .attribute }, "attribute name")
    check(tokens.contains { $0.0 == "\"x.html\"" && $0.1 == .string }, "attribute value")
}

do {
    // Case-insensitive languages must match keywords in any case, and must not
    // match an identifier that merely contains one.
    let tokens = tokenKinds("SELECT id FROM users WHERE selected = 1", "SQL")
    let keywords = tokens.filter { $0.1 == .keyword }.map { $0.0.lowercased() }
    check(keywords.contains("select") && keywords.contains("from") && keywords.contains("where"),
          "SQL keywords match regardless of case", "got \(keywords)")
    check(!tokens.contains { $0.0 == "selected" && $0.1 == .keyword },
          "'selected' is not the keyword 'select'")
}

// MARK: - Language detection

section("LanguageRegistry")

do {
    equal(LanguageRegistry.detect(url: URL(fileURLWithPath: "/x/a.swift")).name, "Swift", "by extension")
    equal(LanguageRegistry.detect(url: URL(fileURLWithPath: "/x/Makefile")).name, "Makefile",
          "by exact filename, with no extension")
    equal(LanguageRegistry.detect(url: URL(fileURLWithPath: "/x/Dockerfile")).name, "Dockerfile",
          "Dockerfile by name")
    equal(LanguageRegistry.detect(url: URL(fileURLWithPath: "/x/script"),
                                  firstLine: "#!/usr/bin/env python3").name, "Python",
          "by shebang when there is no extension")
    equal(LanguageRegistry.detect(url: URL(fileURLWithPath: "/x/notes.unknownext")).name, "Plain Text",
          "unknown extensions fall back to plain text")
}

// MARK: - TextOps

section("TextOps")

do {
    equal(TextOps.sortLines("c\na\nb", .ascending), "a\nb\nc", "sort ascending")
    equal(TextOps.sortLines("c\na\nb\n", .ascending), "a\nb\nc\n",
          "a trailing newline stays at the end rather than sorting to the top")
    equal(TextOps.sortLines("10\n9\n100", .ascendingNumeric), "9\n10\n100", "numeric sort")
    equal(TextOps.sortLines("10\n9\n100", .ascending), "10\n100\n9", "lexicographic sort differs")
    equal(TextOps.removeDuplicateLines("a\nb\na\nc\nb"), "a\nb\nc", "duplicates keep first occurrence")
    equal(TextOps.removeConsecutiveDuplicateLines("a\na\nb\na"), "a\nb\na", "uniq removes runs only")
    equal(TextOps.removeEmptyLines("a\n\n  \nb"), "a\nb", "blank lines count as empty")
    equal(TextOps.trimTrailingWhitespace("a   \nb\t\nc"), "a\nb\nc", "trailing space and tab")
}

do {
    equal(TextOps.tabsToSpaces("\tx", width: 4), "    x", "a leading tab is one full stop")
    equal(TextOps.tabsToSpaces("ab\tx", width: 4), "ab  x",
          "a tab pads to the next stop, not by a fixed width")
    equal(TextOps.leadingSpacesToTabs("        x", width: 4), "\t\tx", "leading spaces to tabs")
    equal(TextOps.leadingSpacesToTabs("a    b", width: 4), "a    b",
          "interior spaces are left alone")
}

do {
    equal(TextOps.properCase("hello world"), "Hello World", "proper case")
    equal(TextOps.invertCase("Hello World"), "hELLO wORLD", "invert case")
    equal(TextOps.sentenceCase("one. two? three"), "One. Two? Three", "sentence case")
    equal(TextOps.camelCase("hello_world_now"), "helloWorldNow", "snake to camel")
    equal(TextOps.snakeCase("helloWorldNow"), "hello_world_now", "camel to snake")
}

do {
    // Commenting then uncommenting must return the original text exactly,
    // including the indentation.
    let source = "    if x:\n        pass\n\n    return"
    let commented = TextOps.toggleLineComment(source, token: "#")
    check(commented.contains("    # if x:"), "comment is inserted at the common indent",
          "got:\n\(commented)")
    equal(TextOps.toggleLineComment(commented, token: "#"), source,
          "comment then uncomment round-trips")
}

do {
    equal(TextOps.base64Decode(TextOps.base64Encode("héllo ☺")), "héllo ☺", "base64 round-trip")
    equal(TextOps.urlDecode(TextOps.urlEncode("a b&c=d")), "a b&c=d", "url round-trip")
    equal(TextOps.urlEncode("a b&c=d"), "a%20b%26c%3Dd", "url encoding covers & and =")
    equal(TextOps.unescapeFromCode(TextOps.escapeForCode("a\n\"b\"\t")), "a\n\"b\"\t",
          "escape round-trip")
    equal(TextOps.md5("abc"), "900150983cd24fb0d6963f7d28e17f72", "md5 of abc")
    equal(TextOps.sha256("abc"),
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 of abc")
}

// MARK: - FindEngine

section("FindEngine")

func find(_ pattern: String, _ text: String, _ configure: (inout SearchOptions) -> Void = { _ in })
    -> [String] {
    var options = SearchOptions()
    configure(&options)
    let query = SearchQuery(pattern: pattern, options: options)
    let ns = text as NSString
    return FindEngine.matches(of: query, in: ns, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }
}

do {
    equal(find("ab", "ab AB ab").count, 3, "literal search is case-insensitive by default")
    equal(find("ab", "ab AB ab") { $0.matchCase = true }.count, 2, "match case")
    equal(find("cat", "cat cats concat") { $0.wholeWord = true }, ["cat"], "whole word")
    equal(find("\\d+", "a1 bb 234") { $0.mode = .regex }, ["1", "234"], "regex")
    equal(find("a\\nb", "a\nb") { $0.mode = .extended }, ["a\nb"], "extended escapes")
    equal(find("a\\nb", "a\nb").count, 0, "normal mode treats a backslash literally")
}

do {
    // An empty or zero-width match must advance, or replaceAll spins forever.
    let query = SearchQuery(pattern: "x*", options: { var o = SearchOptions(); o.mode = .regex; return o }())
    let text = "abc" as NSString
    let hits = FindEngine.matches(of: query, in: text, range: NSRange(location: 0, length: 3))
    check(hits.count < 100, "a zero-width regex terminates rather than looping", "got \(hits.count)")
}

do {
    let storage = NSMutableString(string: "one two three")
    var options = SearchOptions()
    options.mode = .regex
    let query = SearchQuery(pattern: "(\\w+) (\\w+)", options: options)
    let count = FindEngine.replaceAll(query, template: "$2 $1", in: storage,
                                      range: NSRange(location: 0, length: storage.length))
    equal(count, 1, "replaceAll reports the count")
    equal(storage as String, "two one three", "capture groups expand in the replacement")
}

do {
    let storage = NSMutableString(string: "a a a")
    let query = SearchQuery(pattern: "a", options: SearchOptions())
    let count = FindEngine.replaceAll(query, template: "bb", in: storage,
                                      range: NSRange(location: 0, length: storage.length))
    equal(count, 3, "every literal occurrence replaced")
    equal(storage as String, "bb bb bb", "replacing right to left keeps later ranges valid")
}

do {
    var options = SearchOptions()
    options.wrapAround = true
    let query = SearchQuery(pattern: "x", options: options)
    let text = "x--x" as NSString
    equal(FindEngine.next(query, in: text, from: 4)?.range.location, 0, "find next wraps to the top")
    equal(FindEngine.previous(query, in: text, before: 0)?.range.location, 3,
          "find previous wraps to the bottom")
    var noWrap = SearchOptions()
    noWrap.wrapAround = false
    check(FindEngine.next(SearchQuery(pattern: "x", options: noWrap), in: text, from: 4) == nil,
          "without wrap, searching past the end finds nothing")
}

do {
    let query = SearchQuery(pattern: "([", options: { var o = SearchOptions(); o.mode = .regex; return o }())
    check(query.error != nil, "an invalid regex reports an error rather than crashing")
    check(!query.isValid, "an invalid regex is not valid")
}

// MARK: - Result

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("all good")
