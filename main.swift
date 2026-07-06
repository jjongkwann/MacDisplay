// macdisplay CLI — status / off / on / toggle.
//
// Top-level dispatch lives here because Swift requires executable top-level code to be in a
// file named main.swift when compiling multiple files. All real work is in core.swift; the
// off/on/toggle commands are thin wrappers over disableDisplay/enableDisplay. Behavior,
// messages, and the 0/1/2/3 exit-code contract are unchanged from the single-file v1.

import CoreGraphics
import Foundation

// MARK: - commands

func cmdStatus() -> Int32 {
    let getList: GetDisplayListFn = requireSymbol("CGSGetDisplayList")
    let ids = enumerateDisplays(getList)
    let main = CGMainDisplayID()
    let names = onlineNames()
    let cache = refreshNameCache()

    print("Displays (CGSGetDisplayList) — \(ids.count) found:")
    print("  \(pad("id", 4)) \(pad("name", 22)) \(pad("kind", 9)) \(pad("state", 9)) main")
    for id in ids {
        let builtin = CGDisplayIsBuiltin(id) != 0
        let online  = CGDisplayIsOnline(id) != 0
        let active  = CGDisplayIsActive(id) != 0
        let state   = !online ? "disabled" : (active ? "active" : "online")
        let kind    = builtin ? "built-in" : "external"
        let name    = displayName(id, names, cache)
        let isMain  = id == main ? "yes" : ""
        print("  #\(pad(String(id), 3)) \(pad(name, 22)) \(pad(kind, 9)) \(pad(state, 9)) \(isMain)")
    }

    if let builtin = firstBuiltin(ids) {
        if CGDisplayIsOnline(builtin) == 0 {
            // Presence in CGSGetDisplayList doesn't discriminate cause: a lid-closed built-in
            // can stay enumerated-but-offline just like a software-disabled one.
            print("\nBuilt-in: display #\(builtin) is OFFLINE — either software-disabled (try `macdisplay on`) or the lid is closed (physically can't come on until it's open).")
        } else {
            print("\nBuilt-in: display #\(builtin) is online.")
        }
    } else {
        print("\nBuilt-in: NOT enumerated — physically absent (lid closed / clamshell). Open the lid to use it.")
    }
    return 0
}

func cmdOff(_ spec: String?) -> Int32 {
    let getList: GetDisplayListFn = requireSymbol("CGSGetDisplayList")
    let ids = enumerateDisplays(getList)

    guard let target = resolveTarget(ids, spec) else {
        eprint(describeMissing(spec) + " Nothing to disable.")
        return 2
    }
    let r = disableDisplay(target)
    r.ok ? print(r.message) : eprint(r.message)
    return r.code
}

func cmdOn(_ spec: String?) -> Int32 {
    let getList: GetDisplayListFn = requireSymbol("CGSGetDisplayList")
    let ids = enumerateDisplays(getList)

    guard let target = resolveTarget(ids, spec) else {
        eprint(describeMissing(spec))
        if spec == nil { recoveryLadder() }
        return 2
    }
    let r = enableDisplay(target)
    if r.ok { print(r.message); return 0 }
    eprint(r.message)
    // Ladder on exhausted retries always; on a vanished target only for the built-in (spec == nil).
    if r.code == 1 || spec == nil { recoveryLadder() }
    return r.code
}

func cmdToggle(_ spec: String?) -> Int32 {
    let getList: GetDisplayListFn = requireSymbol("CGSGetDisplayList")
    let ids = enumerateDisplays(getList)
    guard let target = resolveTarget(ids, spec) else {
        eprint(describeMissing(spec) + " Cannot toggle.")
        return 2
    }
    return CGDisplayIsOnline(target) != 0 ? cmdOff(spec) : cmdOn(spec)
}

func printUsage(toStderr: Bool = false) {
    let text = """
    macdisplay — turn the MacBook built-in display off/on while using external monitors

    Usage: macdisplay <command> [display-id]

      status        List all displays and the built-in panel's state (read-only)
      off [id]      Software-disconnect a display (only if another display stays active)
      on [id]       Re-enable a display (retries; prints recovery steps on failure)
      toggle [id]   Off or on depending on the display's current state

    [id] is a display id from `status`; omit it to target the built-in display.
    Offline displays are labeled in `status` with their last-seen device name.
    """
    if toStderr { eprint(text) } else { print(text) }
}

// MARK: - dispatch

let cmd = CommandLine.arguments.count >= 2 ? CommandLine.arguments[1] : ""
let arg = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : nil
switch cmd {
case "status":            exit(cmdStatus())
case "off":               exit(cmdOff(arg))
case "on":                exit(cmdOn(arg))
case "toggle":            exit(cmdToggle(arg))
case "", "-h", "--help", "help": printUsage(); exit(0)
default:
    eprint("Unknown command: \(cmd)\n")
    printUsage(toStderr: true)
    exit(2)
}
