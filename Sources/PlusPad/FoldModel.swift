import AppKit

/// Which lines can be folded, and which are currently folded away.
///
/// Notepad++ derives folding from its lexer, so braces fold in C and
/// indentation folds in Python. Doing it from indentation alone covers both:
/// a `{` block's body is indented, so the header lands on the same line either
/// way, and it means every language gets folding without a per-language fold
/// parser. Where the two disagree is unindented code, which has no visible
/// structure to fold anyway.
///
/// Levels are measured in columns, not characters, so a file indented with tabs
/// and one indented with spaces fold identically.
final class FoldModel {

    /// Indent level per line, in columns. Blank lines carry `blankLevel`.
    private(set) var levels: [Int] = []
    /// Lines that open a foldable region.
    private(set) var headers: Set<Int> = []
    /// Headers the user has collapsed.
    private(set) var collapsed: Set<Int> = []

    /// A blank line belongs to whichever region surrounds it rather than
    /// breaking one in half, so it gets a sentinel instead of level zero.
    private static let blankLevel = Int.min

    private var cachedHiddenLines: Set<Int> = []
    private var hiddenDirty = true

    var isEmpty: Bool { headers.isEmpty }

    // MARK: - Building

    func recompute(text: NSString, index: LineIndex, tabWidth: Int) {
        let lineCount = index.lineCount
        var newLevels = [Int](repeating: FoldModel.blankLevel, count: lineCount)

        for line in 0..<lineCount {
            let range = index.range(ofLine: line)
            var columns = 0
            var offset = range.location
            let limit = min(range.location + range.length, text.length)
            var sawContent = false
            while offset < limit {
                let ch = text.character(at: offset)
                if ch == 32 { columns += 1 }
                else if ch == 9 { columns += tabWidth - (columns % tabWidth) }
                else if ch == 10 || ch == 13 { break }
                else { sawContent = true; break }
                offset += 1
            }
            newLevels[line] = sawContent ? columns : FoldModel.blankLevel
        }

        levels = newLevels
        headers = []
        for line in 0..<lineCount {
            let level = newLevels[line]
            guard level != FoldModel.blankLevel else { continue }
            // A header is a line the next real line is indented under.
            var probe = line + 1
            while probe < lineCount && newLevels[probe] == FoldModel.blankLevel { probe += 1 }
            if probe < lineCount && newLevels[probe] > level { headers.insert(line) }
        }

        // Collapsed headers that no longer exist would hide their old body
        // forever, so drop them.
        collapsed = collapsed.filter { headers.contains($0) }
        hiddenDirty = true
    }

    /// Last line belonging to the region opened at `header`.
    func regionEnd(for header: Int) -> Int {
        guard header < levels.count, levels[header] != FoldModel.blankLevel else { return header }
        let level = levels[header]
        var last = header
        var line = header + 1
        while line < levels.count {
            let current = levels[line]
            if current == FoldModel.blankLevel {
                // Trailing blank lines are only included if real content follows
                // at a deeper level; otherwise the fold would swallow the gap
                // before the next top-level block.
                line += 1
                continue
            }
            if current > level { last = line; line += 1; continue }
            break
        }
        return last
    }

    func isHeader(_ line: Int) -> Bool { headers.contains(line) }
    func isCollapsed(_ line: Int) -> Bool { collapsed.contains(line) }

    /// True when `line` sits inside a region opened at or above it that is
    /// collapsed, and so should not be displayed.
    func isHidden(_ line: Int) -> Bool {
        if hiddenDirty { rebuildHidden() }
        return cachedHiddenLines.contains(line)
    }

    private func rebuildHidden() {
        var hidden = Set<Int>()
        for header in collapsed.sorted() {
            let end = regionEnd(for: header)
            if end > header { hidden.formUnion((header + 1)...end) }
        }
        cachedHiddenLines = hidden
        hiddenDirty = false
    }

    // MARK: - Toggling

    func toggle(_ header: Int) {
        guard headers.contains(header) else { return }
        if collapsed.contains(header) { collapsed.remove(header) } else { collapsed.insert(header) }
        hiddenDirty = true
    }

    func collapseAll() {
        collapsed = headers
        hiddenDirty = true
    }

    func expandAll() {
        collapsed = []
        hiddenDirty = true
    }

    /// Reveal `line` by expanding every collapsed region containing it, so Go To
    /// Line and a search hit inside a fold can still land on it.
    func reveal(_ line: Int) {
        guard isHidden(line) else { return }
        for header in collapsed.sorted(by: >) where header < line && regionEnd(for: header) >= line {
            collapsed.remove(header)
        }
        hiddenDirty = true
    }

    /// The character ranges currently folded away, for the layout manager.
    ///
    /// Each range starts at the end of the header line's text so the header
    /// itself stays visible, and runs to the end of the region.
    func hiddenCharacterRanges(index: LineIndex) -> [NSRange] {
        var ranges: [NSRange] = []
        for header in collapsed.sorted() {
            let end = regionEnd(for: header)
            guard end > header else { continue }
            let start = index.end(ofLine: header)
            let stop = index.end(ofLine: end)
            guard stop > start else { continue }
            // Nested collapsed regions are already inside this one; merging keeps
            // the list short and non-overlapping.
            if let last = ranges.last, last.location + last.length >= start {
                let merged = max(last.location + last.length, stop)
                ranges[ranges.count - 1] = NSRange(location: last.location,
                                                   length: merged - last.location)
            } else {
                ranges.append(NSRange(location: start, length: stop - start))
            }
        }
        return ranges
    }
}
