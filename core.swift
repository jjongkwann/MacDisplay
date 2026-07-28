// macdisplay — turn the MacBook built-in display off/on while using external monitors.
//
// Shared core: private-API symbol loading, display enumeration, the id→name cache, and the
// disable/enable operations used by BOTH the CLI (main.swift) and the menu bar app (menubar.swift).
//
// The display-configuration transaction wrapper (begin / configure / complete-or-cancel,
// commit .permanently) is adapted from oabdrabo/DisplayDeck (MIT). The private symbols
// CGSConfigureDisplayEnabled / CGSGetDisplayList and the re-derive-id-before-enable
// technique are facts also used by janten/disable-monitor (GPL-2.0); that source was NOT
// copied — the sequence is reimplemented here from the documented prototypes.
//
// KEY correctness fact (DisplayDeck issue #1 / kCGErrorIllegalArgument): a software-disabled
// display disappears from the public online/active lists but is STILL returned by the private
// CGSGetDisplayList with a valid CGDirectDisplayID. Re-enable must therefore re-derive the id
// from CGSGetDisplayList immediately before the transaction, never reuse a stored integer.

import CoreGraphics
import Foundation
import AppKit   // NSScreen.localizedName — cheap human-readable names for online displays

// MARK: - exit codes
// 0 success · 1 operation failed · 2 refused/precondition (guard, built-in absent) · 3 private symbol gone

// MARK: - private SkyLight symbols, resolved at runtime (never at link time)

let skylightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
let skylightHandle: UnsafeMutableRawPointer? = dlopen(skylightPath, RTLD_LAZY)

typealias GetDisplayListFn = @convention(c)
    (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
typealias ConfigureEnabledFn = @convention(c)
    (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

func requireSymbol<T>(_ name: String) -> T {
    guard let h = skylightHandle else {
        die("Could not load SkyLight private framework at \(skylightPath). A macOS update may have moved it.", 3)
    }
    guard let sym = dlsym(h, name) else {
        die("Private symbol \(name) not found — a macOS update likely removed it.", 3)
    }
    return unsafeBitCast(sym, to: T.self)
}

// MARK: - small helpers

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func die(_ msg: String, _ code: Int32) -> Never { eprint(msg); exit(code) }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

/// All display ids the window server knows about — INCLUDING software-disabled ones,
/// which the public CGGetOnlineDisplayList / NSScreen APIs omit.
func enumerateDisplays(_ getList: GetDisplayListFn) -> [CGDirectDisplayID] {
    // ponytail: fixed 16-slot cap — a 17th display would silently be dropped; bump if that's ever real.
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    let err = getList(16, &ids, &count)
    if err != .success { die("CGSGetDisplayList failed (CGError \(err.rawValue)).", 1) }
    return Array(ids.prefix(Int(count)))
}

func firstBuiltin(_ ids: [CGDirectDisplayID]) -> CGDirectDisplayID? {
    // Apple Silicon internal panel is usually id 1, but never trust that blindly — verify.
    ids.first { CGDisplayIsBuiltin($0) != 0 }
}

/// Ghost entry: an id the window server still enumerates after a replug/sleep re-enumeration
/// but with no hardware behind it. Real displays — even software-disabled ones — retain
/// vendor/model/serial (verified: an offline built-in keeps 0x610/0xa050); ghosts report all zeros.
func isGhost(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayIsOnline(id) == 0
        && CGDisplayVendorNumber(id) == 0
        && CGDisplayModelNumber(id) == 0
        && CGDisplaySerialNumber(id) == 0
}

// MARK: - last-seen name cache
// AppKit can only name ONLINE displays, so a disabled one would degrade to "Display 3".
// We remember id→name whenever a display is seen online (~/Library/Preferences/macdisplay.plist)
// purely for LABELS and name matching. Unlike DisplayDeck's stale-id bug, the cache never picks
// a target by itself: every target must still be present in the CURRENT CGSGetDisplayList.
// ponytail: keyed by display id, which can reshuffle across reboots — that risk materialized as
// a duplicate menu row (a ghost id wearing a stale cached name). Ghosts are now filtered by
// hardware identity (isGhost), so a stale cache entry can still mislabel but can no longer surface a dead id.

let prefs = UserDefaults(suiteName: "macdisplay")

func refreshNameCache() -> [String: String] {
    var cache = prefs?.dictionary(forKey: "names") as? [String: String] ?? [:]
    for (id, name) in onlineNames() { cache[String(id)] = name }
    prefs?.set(cache, forKey: "names")
    return cache
}

func displayName(_ id: CGDirectDisplayID, _ online: [CGDirectDisplayID: String], _ cache: [String: String]) -> String {
    online[id] ?? cache[String(id)] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)")
}

/// "#3 (LG HDR 4K)" — or just "#3" when no real name is known.
func label(_ id: CGDirectDisplayID) -> String {
    let name = displayName(id, onlineNames(), refreshNameCache())
    return name == "Display \(id)" ? "#\(id)" : "#\(id) (\(name))"
}

/// Target of off/on/toggle: no argument → the built-in panel; a numeric id → that display,
/// if currently enumerated. (Membership check doubles as the fresh-id re-derivation.)
func resolveTarget(_ ids: [CGDirectDisplayID], _ spec: String?) -> CGDirectDisplayID? {
    guard let spec else { return firstBuiltin(ids) }
    guard let id = UInt32(spec), ids.contains(id) else { return nil }
    return id
}

func describeMissing(_ spec: String?) -> String {
    spec == nil
        ? "Built-in display is not enumerated (lid closed / clamshell?)."
        : "Display \(spec!) not found — run `macdisplay status` for valid ids."
}

/// Localized names for the displays AppKit can see (online only). ponytail: no IOKit name
/// spelunking — a disabled/absent built-in just falls back to a generic label.
func onlineNames() -> [CGDirectDisplayID: String] {
    var map: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            map[n.uint32Value] = screen.localizedName
        }
    }
    return map
}

/// One display-config transaction: begin → (unmirror if disabling) → set enabled → commit.
/// Rolls back with CGCancelDisplayConfiguration on any mid-transaction error.
func setDisplayEnabled(_ id: CGDirectDisplayID, _ enabled: Bool, _ setEnabled: ConfigureEnabledFn) -> CGError {
    var config: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&config)
    if begin != .success { return begin }
    guard let cfg = config else { return .failure }

    if !enabled && CGDisplayIsInMirrorSet(id) != 0 {
        let unmirror = CGConfigureDisplayMirrorOfDisplay(cfg, id, 0 /* kCGNullDirectDisplay */)
        if unmirror != .success { CGCancelDisplayConfiguration(cfg); return unmirror }
    }
    let set = setEnabled(cfg, id, enabled)
    if set != .success { CGCancelDisplayConfiguration(cfg); return set }
    return CGCompleteDisplayConfiguration(cfg, .permanently)
}

/// The verified recovery ladder, printed by the CLI and shown in the menu bar app's alert.
let recoveryLadderText = """
Recovery steps (try in order):
  1. Close and re-open the MacBook lid.
  2. Unplug and replug an external display.
  3. Log out and back in.
  4. Reboot.
"""

func recoveryLadder() { eprint(recoveryLadderText) }

// MARK: - reusable operations (shared by the CLI and the menu bar app)
// Both return success/failure + a human-readable message. `code` is the CLI exit code the
// outcome implies (0 ok · 1 failed · 2 refused/precondition); the menu bar app only reads `ok`.

struct OpResult { let ok: Bool; let code: Int32; let message: String }

/// Software-disconnect a display. Refuses if it is the only ACTIVE display (never black out
/// everything), then commits the transaction and verifies the change actually took.
func disableDisplay(_ id: CGDirectDisplayID) -> OpResult {
    let getList: GetDisplayListFn = requireSymbol("CGSGetDisplayList")
    let setEnabled: ConfigureEnabledFn = requireSymbol("CGSConfigureDisplayEnabled")
    let ids = enumerateDisplays(getList)
    let tag = label(id) // capture the name while the display is still online

    if CGDisplayIsOnline(id) == 0 {
        return OpResult(ok: true, code: 0, message: "Display \(tag) is already off.")
    }
    // Guard: never disable the last active display.
    let otherActive = ids.contains { $0 != id && CGDisplayIsActive($0) != 0 }
    if !otherActive {
        return OpResult(ok: false, code: 2, message: "Refusing: display \(tag) is the only active display. Enable another display first.")
    }

    let err = setDisplayEnabled(id, false, setEnabled)
    if err != .success {
        return OpResult(ok: false, code: 1, message: "Failed to disable display \(tag) (CGError \(err.rawValue)).")
    }
    // Verify the change actually took before reporting success.
    if CGDisplayIsOnline(id) == 0 {
        return OpResult(ok: true, code: 0, message: "Display \(tag) disabled. Note: it may return after sleep/wake — run `off` again.")
    }
    return OpResult(ok: false, code: 1, message: "Commit reported success but display \(tag) is still online.")
}

/// Re-enable a display, re-deriving the id from CGSGetDisplayList before EACH of up to 3
/// attempts (~400 ms apart) — the whole point of the design (see KEY correctness fact above).
func enableDisplay(_ id: CGDirectDisplayID) -> OpResult {
    let getList: GetDisplayListFn = requireSymbol("CGSGetDisplayList")
    let setEnabled: ConfigureEnabledFn = requireSymbol("CGSConfigureDisplayEnabled")

    for attempt in 1...3 {
        // Re-derive the id from CGSGetDisplayList EVERY attempt — never reuse a stale integer.
        let ids = enumerateDisplays(getList)
        guard ids.contains(id) else {
            return OpResult(ok: false, code: 2, message: describeMissing(String(id)))
        }
        if isGhost(id) {
            return OpResult(ok: false, code: 2, message: "Display \(label(id)) is a stale window-server entry with no connected hardware. Replug the display or reboot to clear it.")
        }
        let tag = label(id)
        if CGDisplayIsOnline(id) != 0 {
            return OpResult(ok: true, code: 0, message: "Display \(tag) is already on.")
        }

        let err = setDisplayEnabled(id, true, setEnabled)
        if CGDisplayIsOnline(id) != 0 {
            return OpResult(ok: true, code: 0, message: "Display \(tag) re-enabled.")
        }
        eprint("Attempt \(attempt)/3 to re-enable failed (CGError \(err.rawValue)).")
        if attempt < 3 { usleep(400_000) }
    }

    return OpResult(ok: false, code: 1, message: "Failed to re-enable display after 3 attempts.")
}
