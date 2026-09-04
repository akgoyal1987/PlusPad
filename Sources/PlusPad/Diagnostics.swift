import AppKit

/// Runtime view-tree dump, enabled with PLUSPAD_DIAG=1.
///
/// Exists because the layout is manual: when a strip fails to appear there is
/// nothing in a log to say whether it was never laid out, laid out at zero size,
/// or laid out correctly and simply not drawing. This answers that in one line
/// per view.
enum Diagnostics {

    static var isEnabled: Bool { ProcessInfo.processInfo.environment["PLUSPAD_DIAG"] == "1" }

    /// Append a one-line note. Used to record whether a `draw` override ran at
    /// all, which the frame dump cannot tell us.
    static func note(_ line: String) {
        guard isEnabled else { return }
        let path = URL(fileURLWithPath: "/tmp/pluspad-diag.log")
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    static func dump(_ window: NSWindow?, label: String) {
        guard isEnabled, let window else { return }
        var out = "\n===== \(label) =====\n"
        out += "window frame: \(window.frame)\n"
        out += "contentView bounds: \(window.contentView?.bounds ?? .zero)\n"
        if let root = window.contentView {
            describe(root, depth: 0, into: &out)
        }
        let path = URL(fileURLWithPath: "/tmp/pluspad-diag.log")
        if let existing = try? String(contentsOf: path, encoding: .utf8) {
            out = existing + out
        }
        try? out.write(to: path, atomically: true, encoding: .utf8)
    }

    private static func describe(_ view: NSView, depth: Int, into out: inout String) {
        let indent = String(repeating: "  ", count: depth)
        let name = String(describing: type(of: view))
        out += "\(indent)\(name) frame=\(shortRect(view.frame)) hidden=\(view.isHidden) "
        out += "alpha=\(view.alphaValue) subviews=\(view.subviews.count)\n"
        if let text = view as? NSTextView {
            out += "\(indent)  textLength=\(text.textStorage?.length ?? -1) "
            out += "container=\(text.textContainer?.containerSize ?? .zero) "
            out += "usedRect=\(shortRect(text.layoutManager?.usedRect(for: text.textContainer!) ?? .zero))\n"
        }
        for child in view.subviews { describe(child, depth: depth + 1, into: &out) }
    }

    /// Render the window's content into a PNG.
    ///
    /// The app drawing itself needs no Screen Recording grant, which is the only
    /// way to see what actually renders from a terminal session.
    static func capture(_ window: NSWindow?, to path: String) {
        guard let root = window?.contentView else { return }
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }


    // MARK: - Action audit

    /// Walk every menu item and every control, and report any whose action
    /// nothing in the responder chain implements.
    ///
    /// A menu item wired to a selector that no longer exists is completely
    /// silent: it looks normal, it is enabled, and clicking it does nothing.
    /// This is the only cheap way to find all of them at once.
    static func auditActions(app: NSApplication, window: NSWindow?) -> String {
        var out = "\n===== action audit =====\n"
        var dead: [String] = []
        var checked = 0
        var keyEquivalents: [String: [String]] = [:]

        func resolves(_ action: Selector, target: AnyObject?, sender: Any?) -> Bool {
            app.target(forAction: action, to: target, from: sender) != nil
        }

        func walk(_ menu: NSMenu, path: String) {
            for item in menu.items {
                let label = path.isEmpty ? item.title : "\(path) > \(item.title)"
                if let submenu = item.submenu {
                    walk(submenu, path: label)
                    continue
                }
                guard !item.isSeparatorItem, let action = item.action else { continue }
                checked += 1

                if !item.keyEquivalent.isEmpty {
                    var mods = ""
                    let m = item.keyEquivalentModifierMask
                    if m.contains(.control) { mods += "ctrl-" }
                    if m.contains(.option) { mods += "alt-" }
                    if m.contains(.shift) { mods += "shift-" }
                    if m.contains(.command) { mods += "cmd-" }
                    keyEquivalents[mods + item.keyEquivalent, default: []].append(label)
                }

                if !resolves(action, target: item.target, sender: item) {
                    dead.append("MENU  \(label)  ->  \(NSStringFromSelector(action))")
                }
            }
        }

        if let main = app.mainMenu { walk(main, path: "") }

        func walkViews(_ view: NSView, path: String) {
            if let control = view as? NSControl, let action = control.action {
                checked += 1
                let label = "\(path)/\(type(of: control))"
                    + (control.toolTip.map { " [\($0)]" } ?? "")
                if !resolves(action, target: control.target, sender: control) {
                    dead.append("CONTROL  \(label)  ->  \(NSStringFromSelector(action))")
                }
            }
            for child in view.subviews { walkViews(child, path: path + "/" + String(describing: type(of: view))) }
        }
        if let root = window?.contentView { walkViews(root, path: "") }

        out += "checked \(checked) actions\n"
        if dead.isEmpty {
            out += "all actions resolve\n"
        } else {
            out += "\(dead.count) DEAD ACTION(S):\n"
            for entry in dead { out += "  \(entry)\n" }
        }

        let clashes = keyEquivalents.filter { $0.value.count > 1 }
        if clashes.isEmpty {
            out += "no duplicate key equivalents\n"
        } else {
            out += "\(clashes.count) DUPLICATE KEY EQUIVALENT(S):\n"
            for (key, owners) in clashes.sorted(by: { $0.key < $1.key }) {
                out += "  \(key): \(owners.joined(separator: " | "))\n"
            }
        }
        return out
    }

    private static func shortRect(_ r: NSRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }
}
