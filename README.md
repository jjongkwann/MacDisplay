# macdisplay

A tiny CLI to turn the MacBook **built-in display off/on** while you work on external
monitors — keep the lid open (Touch ID, camera, cooling) but leave the internal panel dark,
and bring it back instantly.

Apple Silicon, macOS 13+. Verified on an M1 Max, macOS 26.5.1 (Tahoe).

## Build

```sh
make cli    # → ./macdisplay        (the CLI)
make app    # → ./MacDisplay.app    (the menu bar app)
make all    # both
```

Plain `swiftc` + a `Makefile` — no Xcode project, no SwiftPM, no external dependencies. The
source is three files: `core.swift` (shared logic), `main.swift` (CLI), `menubar.swift` (menu
bar app). Frameworks (CoreGraphics, AppKit, Foundation) are auto-linked from the `import`s.

## Usage

```sh
./macdisplay status       # list every display + the built-in's state (read-only)
./macdisplay off [id]     # software-disconnect a display (only if another stays active)
./macdisplay on [id]      # re-enable a display (retries, then prints recovery steps)
./macdisplay toggle [id]  # off or on depending on current state
```

`[id]` is a display id from `status` (externals work too); omit it to target the built-in.
You don't need to memorize ids: offline displays are labeled in `status` with the device
name they had when last seen online (cached in `~/Library/Preferences/macdisplay.plist`).

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
a failed toggle pops an alert with the recovery ladder below.

```sh
make app
open MacDisplay.app
```

To launch it automatically at login, add it under **System Settings → General → Login Items**.

## Safety

- `off` refuses unless at least one **other** display is active — it will not black out your
  only screen.
- `off` refuses gracefully if the built-in is physically absent (lid closed).
- `on` re-derives the display id fresh before each attempt and retries up to 3× (~400 ms
  apart). This avoids the classic re-enable bug (see caveats).

## v1 limitation — may not survive sleep/wake

This is a **one-shot** command, not a daemon. macOS re-adds displays on wake, lid open/close,
and hotplug, so a disconnect can silently come back after sleep. That's expected in v1 — just
run `off` again. No background process re-asserts the state.

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
