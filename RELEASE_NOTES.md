# v0.2.0

A Markdown preview, a proper search results dock, and one real bug fixed.

## Markdown preview

View > Markdown Preview (Cmd Shift M) splits the window and renders the
document beside its source, updating as you type. Headings, emphasis, inline
code, bullet, ordered and task lists, blockquotes, setext headings, horizontal
rules, tables as real cells, strikethrough, links, reference links and local
images. Fenced code is coloured by the same scanners that colour a real file, so
a `swift` fence in a README reads as Swift. A link to a local file opens it as a
tab. The divider drags and its position is remembered.

Two things it deliberately will not do:

- **It fetches nothing.** A remote image is drawn as its alt text and a link
  rather than requested. PlusPad contains no networking code at all, and a
  preview that quietly fetched whatever a file referenced would be the one place
  that changed -- opening someone else's Markdown would tell them you had.
- **It renders no HTML.** Embedded tags are shown as the text they are, and a
  `javascript:` URL is never made into a link. Executing them would need a web
  view, which is both a second rendering engine and a way for a file to run
  script with the app's file access.

## Search results dock

Find All in This File, Find All in All Files and Find in Files now fill a panel
along the bottom of the window, as Notepad++ does: a summary line, one
collapsible group per file, and every matching line with its number and the
match highlighted. Clicking a row goes to that hit and selects it; a row from a
file that is not open opens it first. Draggable by its top edge, remembers its
height, toggled by View > Search Results (Cmd Shift R).

Results previously opened as an untitled tab, which made them look like a
document in four ways they are not -- and the one thing every line in them is
for, going to that line, was not possible at all.

## Fixed

- **Opening a file no longer shifts it 65pt to the right.** The first characters
  of every line were hidden behind the line-number gutter for the life of that
  tab: a file opened showing "ding one" where "# Heading one" had been written.
  AppKit constrains a scroll view's clip when it scrolls, not when a ruler
  appears beside it, so a pane built while the window was already on screen --
  every File > Open -- started 65pt off. Restoring a session was never affected,
  which is why it survived: the path everyone sees at launch was always right.

## Verified

82 logic checks, 164 checks driving the real menu commands against a real
window, and an audit of all 198 menu and control actions. All green.

## Installing

`PlusPad-0.2.0-macos-arm64.zip`, macOS 14 or later, Apple silicon only. Unzip
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
