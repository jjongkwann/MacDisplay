// macdisplay CLI — status / off / on / toggle.
//
// Top-level dispatch lives here because Swift requires executable top-level code to be in a
// file named main.swift when compiling multiple files. All real work is in core.swift; the
// off/on/toggle commands are thin wrappers over disableDisplay/enableDisplay. core.swift reports
// failures as values; turning them into stderr output and the 0/1/2/3 exit codes happens here.

import CoreGraphics
import Foundation

// MARK: - commands

func cmdStatus() throws -> Int32 {
    let ids = try enumerateDisplays()
    let main = CGMainDisplayID()
    let online = onlineNames()
    let cache = refreshNameCache()
    let names = ids.map { displayName($0, online, cache) ?? "Display \($0)" }
    let width = names.map(\.count).max().map { max($0, 4) } ?? 4

    print("Displays (CGSGetDisplayList) — \(ids.count) found:")
    print("  \(pad("id", 4)) \(pad("name", width)) \(pad("kind", 9)) \(pad("state", 9)) main")
    for (id, name) in zip(ids, names) {
        let builtin = CGDisplayIsBuiltin(id) != 0
        let online  = CGDisplayIsOnline(id) != 0
        let active  = CGDisplayIsActive(id) != 0
        let state   = isGhost(id) ? "ghost" : (!online ? "disabled" : (active ? "active" : "online"))
        let kind    = builtin ? "built-in" : "external"
        let isMain  = id == main ? "yes" : ""
        print("  #\(pad(String(id), 3)) \(pad(name, width)) \(pad(kind, 9)) \(pad(state, 9)) \(isMain)")
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

func cmdOff(_ spec: String?) throws -> Int32 {
    let ids = try enumerateDisplays()

    guard let target = resolveTarget(ids, spec) else {
        eprint(describeMissing(spec) + " Nothing to disable.")
        return 2
    }
    let r = disableDisplay(target)
    r.ok ? print(r.message) : eprint(r.message)
    return r.code
}

func cmdOn(_ spec: String?) throws -> Int32 {
    let ids = try enumerateDisplays()

    guard let target = resolveTarget(ids, spec) else {
        // The built-in is absent (lid closed), but on was asked for: forget the keep-off memory,
        // or the menu bar app would turn the panel off again when the lid opens.
        if spec == nil { forgetKeepOff(ids) }
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

func cmdToggle(_ spec: String?) throws -> Int32 {
    let ids = try enumerateDisplays()
    guard let target = resolveTarget(ids, spec) else {
        if spec == nil { forgetKeepOff(ids) } // an absent built-in is off, so toggle means on (see cmdOn)
        eprint(describeMissing(spec) + " Cannot toggle.")
        return 2
    }
    return CGDisplayIsOnline(target) != 0 ? try cmdOff(spec) : try cmdOn(spec)
}

func printUsage(toStderr: Bool = false) {
    let text = """
    macdisplay — turn the MacBook built-in display off/on while using external monitors

    Usage: macdisplay <command> [display-id]

      status        List all displays and the built-in panel's state (read-only)
      off [id]      Software-disconnect a display (only if another display stays active)
      on [id]       Re-enable a display (retries; prints recovery steps on failure)
      toggle [id]   Off or on depending on the display's current state
      --version     Print the version

    [id] is a display id from `status`; omit it to target the built-in display.
    Offline displays are labeled in `status` with their last-seen device name.
    """
    if toStderr { eprint(text) } else { print(text) }
}

// MARK: - dispatch

let cmd = CommandLine.arguments.count >= 2 ? CommandLine.arguments[1] : ""
let arg = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : nil
do {
    switch cmd {
    case "status":            exit(try cmdStatus())
    case "off":               exit(try cmdOff(arg))
    case "on":                exit(try cmdOn(arg))
    case "toggle":            exit(try cmdToggle(arg))
    case "--version", "version": print("macdisplay \(version)"); exit(0)
    case "", "-h", "--help", "help": printUsage(); exit(0)
    default:
        eprint("Unknown command: \(cmd)\n")
        printUsage(toStderr: true)
        exit(2)
    }
} catch {
    let r = failure(error)
    eprint(r.message)
    exit(r.code)
}
