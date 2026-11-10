# macdisplay

A tiny CLI and menu bar app to turn the MacBook **built-in display off/on** while you work on
external monitors — keep the lid open (Touch ID, camera, cooling) but leave the internal panel
dark, and bring it back instantly.

Apple Silicon, macOS 13+ (the build targets 13.0). Tested on an M1 Max: off/on on macOS 26.5.1
(Tahoe), `status` and the build also on macOS 27.2.1.

## Build

```sh
make cli      # → ./macdisplay        (the CLI)
make app      # → ./MacDisplay.app    (the menu bar app, with the CLI inside it)
make all      # both
make install  # → /Applications/MacDisplay.app   (make install APPDIR=~/Applications to change)
```

Plain `swiftc` + a `Makefile` — no Xcode project, no SwiftPM, no external dependencies. The
source is three files: `core.swift` (shared logic), `main.swift` (CLI), `menubar.swift` (menu
bar app). Frameworks (CoreGraphics, AppKit, Foundation) are auto-linked from the `import`s.
The app icon is built from `assets/AppIcon.png` with `sips` and `iconutil`, and the bundle is
ad-hoc signed; none of it is notarized, so this is for building on your own Mac.

Run the app from the installed copy rather than from the build folder: `make app` and
`make clean` replace or delete `./MacDisplay.app`. After installing over a running copy, quit
and reopen it to get the new version. The installed bundle also carries the CLI at
`/Applications/MacDisplay.app/Contents/MacOS/macdisplay`; symlink it onto your `PATH` if you
want it there.

## Usage

```sh
./macdisplay status       # list every display + the built-in's state (read-only)
./macdisplay off [id]     # software-disconnect a display (only if another stays active)
./macdisplay on [id]      # re-enable a display (retries, then prints recovery steps)
./macdisplay toggle [id]  # off or on depending on current state
./macdisplay --version
```

`[id]` is a display id from `status` (externals work too); omit it to target the built-in.
You don't need to memorize ids: offline displays are labeled in `status` with the device
name they had when last seen online (cached in `~/Library/Preferences/macdisplay.plist`, by
vendor and model, so the label survives the id changing on a replug or reboot).

`status` reports the built-in's state, but note: on Apple Silicon a lid-closed built-in can
stay enumerated in `CGSGetDisplayList` (just offline) rather than dropping out entirely, so
presence in that list alone can't reliably tell "software-disabled" apart from "lid closed" —
`status` names both possibilities when the built-in shows up offline. Only a built-in missing
from the list entirely is reported as physically absent.

Exit codes: `0` ok · `1` operation failed · `2` refused (guard tripped, or built-in absent) ·
`3` a required private symbol is gone (see caveats).

## Menu bar app

`MacDisplay.app` is a tiny menu bar item (a `display` icon, no Dock icon). It shows one row per
display — device name and id, with a checkmark when the display is on — rebuilt live from
`CGSGetDisplayList` every time the menu opens. Click a row to toggle that display off/on: the
same disconnect/reconnect and the same last-active-display guard as the CLI. Phantom rows (an
offline display never seen online, so with no real name) are hidden, as are ghost rows (a stale
id left over from a sleep/replug re-enumeration, with no hardware behind it — identified by
zeroed vendor/model/serial rather than by name, so a stale cached name can't let one slip
through); the only remaining active display is greyed out so you can't black everything out; and
a failed toggle pops an alert with the recovery ladder below. If a private symbol is gone after
a macOS update, the menu says so instead of listing displays.

```sh
make install
open /Applications/MacDisplay.app
```

To launch it automatically at login, add it under **System Settings → General → Login Items**.

## Sleep/wake — keeping the built-in off

macOS re-adds displays on wake, lid open/close, and hotplug, so a disconnected display can
silently come back after sleep.

- **With the menu bar app running**, MacDisplay remembers which external displays were active
  when you turned the built-in off (from the menu, the CLI or the hotkey), and turns the
  built-in off again about 2 seconds after it comes back while one of those displays is active:
  after sleep/wake, a lid open, a redock, or a login at the desk. Turning the built-in on
  forgets the external displays connected at that moment, so "on" at the desk keeps it on
  there. Undocked, or plugged into a display you never turned it off with (a projector, a TV),
  nothing happens. Displays are told apart by vendor, model and serial; two monitors of the
  same model that report no serial count as one.
- If the panel came back after 3 attempts to turn it off within a minute, the app stops, forgets
  the displays connected then and tells you.
- **The CLI alone** is a one-shot command: nothing re-asserts the state, just run `off` again.
- External displays are never re-asserted, by either.

This part has not been tested across a real sleep/wake cycle yet; see "If the built-in gets
stuck off" for the way back, and **Quit MacDisplay** stops it.

## Hotkey

`karabiner/macdisplay.json` is a [Karabiner-Elements](https://karabiner-elements.pqrs.org)
rule that runs `macdisplay toggle` on **⌃⌥⌘D**. Copy it to
`~/.config/karabiner/assets/complex_modifications/`, then enable it under Karabiner-Elements →
Complex Modifications → Add predefined rule. It calls the CLI inside
`/Applications/MacDisplay.app`, so run `make install` first; edit the key or the path in the
file to taste.

## Safety

- `off` refuses unless at least one **other** display is active — it will not black out your
  only screen.
- `off` refuses gracefully if the built-in is physically absent (lid closed).
- `on` re-derives the display id fresh before each attempt and retries up to 3× (~400 ms
  apart). This avoids the classic re-enable bug (see caveats).

## If the built-in gets stuck off

`on` prints this ladder automatically when it can't recover; try in order:

1. Close and re-open the MacBook lid.
2. Unplug and replug an external display.
3. Log out and back in.
4. Reboot.

## Caveats — private API, handle with care

- **Private symbols.** `off`/`on` use `CGSConfigureDisplayEnabled` and `CGSGetDisplayList`
  from the private **SkyLight** framework, resolved at runtime via `dlopen`/`dlsym`. There is
  no public API for a real disconnect.
- **macOS-update fragility.** Apple can remove or change these symbols in any point release
  (this happened in Sequoia 15.6 — BetterDisplay #4729/#4730). If a symbol is missing,
  `macdisplay` prints a clear message naming it and exits `3` instead of crashing.
- **The re-enable bug we avoid.** A software-disabled display drops out of the public online
  list; reusing a *stored* display id to re-enable it returns `kCGErrorIllegalArgument` and
  can leave the panel undetectable until logout/reboot. This is DisplayDeck
  [issue #1](https://github.com/oabdrabo/DisplayDeck/issues/1). `macdisplay` re-derives the id
  from `CGSGetDisplayList` immediately before every enable transaction, which is exactly why it
  doesn't hit this.
- **Stuck-disconnect reports exist.** Real disconnects can occasionally get stuck across the
  ecosystem (BetterDisplay [#1623](https://github.com/waydabber/BetterDisplay/issues/1623),
  unresolved). Run live toggles with a way back in reach (external display, the recovery ladder
  above).
- **Windows reshuffle.** Disabling a display moves its windows elsewhere; v1 does not try to
  restore their positions.

## Attribution

The display-config transaction wrapper is adapted from
[oabdrabo/DisplayDeck](https://github.com/oabdrabo/DisplayDeck) (MIT). The private-symbol
technique is a documented fact also used by
[janten/disable-monitor](https://github.com/janten/disable-monitor) (GPL-2.0); that source was
not copied — the sequence is reimplemented independently here.
