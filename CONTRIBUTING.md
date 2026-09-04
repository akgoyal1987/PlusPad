# Contributing

Issues and pull requests are welcome. This is a small personal project, so the
process is light -- but there are a few things about how it is built that will
save you time.

## Getting set up

There is nothing to install beyond the Xcode command line tools:

```bash
xcode-select --install
git clone https://github.com/akgoyal1987/PlusPad.git
cd PlusPad && ./build.sh
```

No package manager, no Xcode project, no generated files. `build.sh` renders
the icon, runs `swiftc` once over `Sources/`, writes the `Info.plist` and ad-hoc
signs the bundle into `build/`.
A build takes about fifteen seconds.

`build/` and `dist/` are gitignored. Do not commit build output.

## Layout

```
Sources/PlusPad/*.swift    two dozen files, AppKit + TextKit 1
tests/main.swift          logic tests, no window needed
tools/make-icon.swift     icon generation, run by build.sh
run-tests.sh              the logic tests
run-selftest.sh           the self test, against a throwaway workspace
build.sh                  the whole build
```

## Before you open a pull request

All three must be green:

```bash
./run-tests.sh                                              # 82 logic checks
./run-selftest.sh                                           # 127 checks against a real window
PLUSPAD_DIAG=1 ./build/PlusPad.app/Contents/MacOS/PlusPad   # action audit, must report no dead actions
```

Run `run-selftest.sh` rather than setting `PLUSPAD_SELFTEST=1` yourself. The
self test closes tabs, flips settings and writes backups; the script points it
at a throwaway workspace first, and the app refuses to run it otherwise, because
against a real workspace it would throw away whatever you had open.

If you add a menu command, add a self test check for it. The action audit proves
the item is wired to something that exists, which is not the same as the item
doing the right thing, and the gap between those two is exactly where a command
that silently converts the wrong document lives.

## Things that have bitten before

Worth knowing before you spend an afternoon on one of these.

- **Never write `dirtyRect.fill()` in a custom `draw`.** Since macOS 14,
  `NSView.clipsToBounds` defaults to `false`, and `dirtyRect` is the *window's*
  dirty region in your view's coordinates -- so filling it paints over the whole
  window. Use `bounds.intersection(dirtyRect).fill()` and set
  `clipsToBounds = true`. The same applies to any geometry taken from
  `dirtyRect`: take x/y/width/height from `bounds` and use `dirtyRect` only to
  cull. This made every view invisible once, and later drew the gutter's divider
  up through the tab bar.
- **A clip view's resting bounds origin is not zero.** `NSScrollView` pays for
  the ruler and the content insets out of it, so a text view with a line number
  gutter rests at about `(-65.5, -24)`. `scroll(to: NSPoint(x: 0, y: target))`
  therefore does not mean "leave the horizontal position alone", it means
  "scroll 65pt right". Ask `constrainBoundsRect` for the resting origin, or read
  the axis you are not changing back off `bounds.origin`. This was a real bug:
  every Find Next slid the text out from under the gutter.
- **A correct frame is not proof anything drew.** Both of the above present as a
  view with a perfect frame, `hidden=false`, `alpha=1`, whose `draw` provably
  runs, and nothing on screen. Use `PLUSPAD_DIAG=1`, which dumps the view tree
  with frames and has the app render itself to a PNG -- an app screenshotting
  itself needs no Screen Recording permission, so it works over SSH and in a
  terminal where `screencapture` fails.
- **Nothing may silently lose text.** The rules that follow from that are in the
  README under "The one rule" and "The workspace folder". A change that adds a
  save prompt, deletes a backup it cannot prove is redundant, or makes recovery
  depend on `session.json` being readable will not be merged.

## Style

Match what is already there. Briefly:

- Four spaces, no tabs. Swift API Design Guidelines naming.
- **Comments explain why, not what.** A comment that restates the line below it
  is noise; a comment recording the defect a piece of code exists to prevent is
  the most valuable thing in the file. Most comments here are the second kind,
  and several name the bug they came from.
- **No icons or emoji** anywhere -- source, comments, log messages, commit
  messages, pull request descriptions.
- Commits use [Conventional Commits](https://www.conventionalcommits.org/):
  `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`.

## Releases

`./release.sh` builds the app, zips the bundle into `dist/` as
`PlusPad-<version>-macos-arm64.zip` and writes `SHA256SUMS.txt`. It prints the
`gh release create` command to run. Binaries are ad-hoc signed and not
notarised, so the release notes must keep the quarantine instructions.

## Licence

By contributing you agree that your contributions are licensed under the MIT
licence, as with the rest of the project.
