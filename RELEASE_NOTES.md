# v0.1.0

First public release.

A Notepad++-style text editor for macOS that never asks you to save. Tabs,
syntax highlighting for around thirty languages, regex find and replace, find in
files, encoding and line-ending conversion, code folding, bookmarks, and the
line operations Notepad++ users reach for.

Unsaved tabs survive quitting, closing a tab is reversible from Recently Closed,
and a crash loses nothing: every buffer is mirrored continuously into a
workspace folder you choose, under its original name, so you can recover your
text from the Finder without PlusPad running at all. Deleting the app does not
touch that folder.

Verified by 82 logic checks, 127 checks driving the real menu commands against a
real window, and an audit of all 196 menu and control actions.

Not there yet: column-mode editing and multiple cursors, macro record and
playback, function list, document map, split view, plugins. Folding is by
indentation rather than by language.

## Installing

`PlusPad-0.1.0-macos-arm64.zip`, macOS 14 or later, Apple silicon only. Unzip
and drag `PlusPad.app` to `/Applications`.

The binary is **ad-hoc signed and not notarised**, so Gatekeeper refuses the
first launch with "cannot be opened because the developer cannot be verified".
Either right-click the app and choose Open, or clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/PlusPad.app
```

Notarising needs a paid Apple Developer account, which this project does not
have. Building from source avoids it entirely and takes about fifteen seconds.

Verify the download:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## Licence

MIT.
