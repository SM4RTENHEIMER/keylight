# keylight

Rekordbox's key "traffic light" for **Serato DJ Pro 4**: a small floating panel that shows,
for every deck with a track loaded, the key and BPM, the keys that mix with it, and whether
the loaded decks fit each other. Keys are drawn in exactly the colours Serato uses in its
own Key column.

```
sh make-app.sh        # builds ~/Applications/keylight.app (drag it to the Dock)
./keylight-start      # alternative: build and run the bare binary in the background
```

macOS only. Needs nothing but Xcode's command line tools (Swift); no dependencies.

## What it shows

- One row per deck: the deck number, the key as a coloured chip (Camelot, standard
  notation, or both), the BPM, and the track name.
- Below it the four keys that mix with that track, following Rekordbox's rule: the same
  key, its two neighbours on the Camelot wheel, and the relative major/minor. The current
  key is outlined.
- The deck number turns green when the track fits the key of at least one other loaded
  deck. The green is one Serato never uses for a key, so it cannot be mistaken for one.

The panel floats above every window, also while Serato has focus, and never takes focus
itself. Drag it by its body; its position is remembered. The menu lives in two places, the
`♪` icon in the menu bar and a right-click on the panel: show/hide, notation, size
(small/medium/large), "show only while Serato is running" and "start at login". With
the last two enabled the panel appears when Serato starts and disappears when it quits.

## Matching tracks (optional)

"Vis matchende numre" in the menu adds one line to the panel, e.g. "23 tracks fit deck 1 ·
±6 % · MAIN & POP"; click it to unfold the list itself (up to eight rows, scrollable) and
click again to fold it away. The list holds the tracks that fit the deck you are mixing
from: compatible key and, by default, within ±6 % BPM. Pick the crate
to search in (or the whole library), the BPM window (±3/6/8/12 %, or any), and which deck
is the reference: by default the one that has been playing longest, marked with ▸; click
a deck row to pin that deck instead (click again to go back to automatic). The list is
sorted by kind of match (same key, relative key, neighbours) and then by BPM distance.
Clicking a row copies "artist title" to the clipboard so it can be pasted into Serato's
search box. Tracks already on a deck are left out.

## How it works

Serato DJ Pro 4 keeps its library in SQLite
(`~/Library/Application Support/Serato/Library/master.sqlite`) and writes a row into
`history_entry` within a second of a track being loaded on a deck; the row's `end_time`
stays `-1` until the deck is cleared or reloaded. The matching list reads `asset`,
`container` and `container_asset` from the same file. keylight opens the database
read-only once a second, and only actually queries it when the database files changed.
It never writes to it. Should a Serato update change the layout, the panel simply shows nothing.

Cost while running: under 1 % of one core, about 15 MB of memory.

## Colours

The 24 key colours were read off a screenshot of Serato's Key column with
`tools/rowsample.swift`: A (minor) keys are the bright colours, B (major) keys the dimmer
versions. 12B was outside the screenshot and is derived from 12A. `tools/wheelsample.swift`
does the same for a Camelot-wheel image and `tools/colorsample.swift` lists the dominant
colours of any image.

## Files

```
main.swift            window, menu, Serato reader
camelot.swift         key parsing (Camelot, Open Key, standard notation) and compatibility
camelot_test.swift    tests for the key logic: sh test.sh
build.sh              compile the binary
make-app.sh           compile and wrap as keylight.app with an icon (make-icon.swift)
keylight-start        run the bare binary in the background
tools/                colour samplers used to extract Serato's palette
```

MIT licence.
