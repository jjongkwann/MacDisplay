// macdisplay — turn the MacBook built-in display off/on while using external monitors.
//
// Shared core: private-API symbol loading, display enumeration, the last-seen name cache, the
// keep-built-in-off memory, and the disable/enable operations used by BOTH the CLI (main.swift)
// and the menu bar app (menubar.swift).
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

/// The one place the version is written; the Makefile reads this line for the app bundle's Info.plist.
let version = "1.3.0"

// MARK: - exit codes
// 0 success · 1 operation failed · 2 refused/precondition (guard, built-in absent) · 3 private symbol gone

/// A failure the caller decides how to surface: the CLI prints it and exits with `code`, the
/// menu bar app shows it. Nothing in this file terminates the process.
struct DisplayError: Error { let message: String; let code: Int32 }

// MARK: - private SkyLight symbols, resolved at runtime (never at link time)

let skylightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
let skylightHandle: UnsafeMutableRawPointer? = dlopen(skylightPath, RTLD_LAZY)

typealias GetDisplayListFn = @convention(c)
    (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
typealias ConfigureEnabledFn = @convention(c)
    (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

func requireSymbol<T>(_ name: String) throws -> T {
    guard let h = skylightHandle else {
        throw DisplayError(message: "Could not load SkyLight private framework at \(skylightPath). A macOS update may have moved it.", code: 3)
    }
    guard let sym = dlsym(h, name) else {
        throw DisplayError(message: "Private symbol \(name) not found — a macOS update likely removed it.", code: 3)
    }
    return unsafeBitCast(sym, to: T.self)
}

// MARK: - small helpers

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

/// All display ids the window server knows about — INCLUDING software-disabled ones,
/// which the public CGGetOnlineDisplayList / NSScreen APIs omit.
func enumerateDisplays() throws -> [CGDirectDisplayID] {
    let getList: GetDisplayListFn = try requireSymbol("CGSGetDisplayList")
    // ponytail: fixed 16-slot cap — a 17th display would silently be dropped; bump if that's ever real.
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    let err = getList(16, &ids, &count)
    if err != .success { throw DisplayError(message: "CGSGetDisplayList failed (CGError \(err.rawValue)).", code: 1) }
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
// We remember the name whenever a display is seen online (~/Library/Preferences/macdisplay.plist)
// purely for LABELS. Unlike DisplayDeck's stale-id bug, the cache never picks a target by
// itself: every target must still be present in the CURRENT CGSGetDisplayList.
// Keyed by hardware identity, not display id: ids reshuffle across replugs and reboots, while a
// software-disabled display keeps its vendor/model (verified: an offline built-in keeps 0x610/0xa050).

let prefs = UserDefaults(suiteName: "macdisplay")

/// Serial is left out on purpose: the cached value is a model name, so two panels of the same
/// model sharing an entry is harmless, and vendor/model is what was verified to survive a disable.
func hardwareKey(_ id: CGDirectDisplayID) -> String { "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id))" }

func refreshNameCache() -> [String: String] {
    var cache = prefs?.dictionary(forKey: "names") as? [String: String] ?? [:]
    // Migration: entries used to be keyed by display id. Carry over the ones whose id still
    // names real hardware (a disabled display would otherwise lose its label); drop the rest.
    let legacy = cache.filter { !$0.key.contains(":") }
    if !legacy.isEmpty {
        let ids = (try? enumerateDisplays()) ?? []
        for (key, name) in legacy {
            cache[key] = nil
            if let id = UInt32(key), ids.contains(id), !isGhost(id) { cache[hardwareKey(id)] = name }
        }
    }
    for (id, name) in onlineNames() { cache[hardwareKey(id)] = name }
    prefs?.set(cache, forKey: "names")
    return cache
}

/// The device name: live when online, else last seen for this hardware. nil when it was never
/// seen online — except the built-in panel, which always gets at least a generic name.
func displayName(_ id: CGDirectDisplayID, _ online: [CGDirectDisplayID: String], _ cache: [String: String]) -> String? {
    online[id] ?? cache[hardwareKey(id)] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : nil)
}

/// "#3 (LG HDR 4K)" — or just "#3" when no name is known.
func label(_ id: CGDirectDisplayID) -> String {
    displayName(id, onlineNames(), refreshNameCache()).map { "#\(id) (\($0))" } ?? "#\(id)"
}

// MARK: - keep-built-in-off memory
// macOS brings a software-disabled display back on wake, lid open and hotplug, and a reboot or a
// redock starts with it on. So turning the built-in off remembers which external displays were
// active at that moment, and turning it on forgets the ones connected then. The menu bar app
// turns the built-in off whenever a remembered display is active: at the desk it stays off,
// while an unknown projector or TV never triggers it. Only the built-in is managed this way.

/// Identity of a physical display. The serial keeps two desks with the same monitor model apart,
/// unless the monitor reports serial 0.
func displayIdentity(_ id: CGDirectDisplayID) -> String {
    "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id)):\(CGDisplaySerialNumber(id))"
}

/// Real external displays (not the built-in, not ghosts): active ones, or all online ones.
func externalIdentities(_ ids: [CGDirectDisplayID], activeOnly: Bool) -> Set<String> {
    Set(ids.filter {
        CGDisplayIsBuiltin($0) == 0 && !isGhost($0)
            && (activeOnly ? CGDisplayIsActive($0) != 0 : CGDisplayIsOnline($0) != 0)
    }.map(displayIdentity))
}

var keepOffWith: Set<String> {
    get {
        // Migration from v1.2.0's single flag: a set flag meant "keep it off here", which is the
        // external displays active now.
        if prefs?.object(forKey: "keepBuiltinOff") != nil {
            let wasSet = prefs?.bool(forKey: "keepBuiltinOff") ?? false
            prefs?.removeObject(forKey: "keepBuiltinOff")
            if wasSet {
                let here = externalIdentities((try? enumerateDisplays()) ?? [], activeOnly: true)
                prefs?.set(here.union(prefs?.stringArray(forKey: "keepOffWith") ?? []).sorted(), forKey: "keepOffWith")
            }
        }
        return Set(prefs?.stringArray(forKey: "keepOffWith") ?? [])
    }
    set { prefs?.set(newValue.sorted(), forKey: "keepOffWith") }
}

/// The built-in was turned off: keep it off whenever these external displays are active again.
func rememberKeepOff(_ ids: [CGDirectDisplayID]) { keepOffWith.formUnion(externalIdentities(ids, activeOnly: true)) }
/// The built-in was asked on: stop turning it off with the external displays connected now.
func forgetKeepOff(_ ids: [CGDirectDisplayID]) { keepOffWith.subtract(externalIdentities(ids, activeOnly: false)) }

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

func failure(_ error: Error) -> OpResult {
    let e = error as? DisplayError ?? DisplayError(message: "\(error)", code: 1)
    return OpResult(ok: false, code: e.code, message: e.message)
}

/// Software-disconnect a display. Refuses if it is the only ACTIVE display (never black out
/// everything), then commits the transaction and verifies the change actually took.
func disableDisplay(_ id: CGDirectDisplayID) -> OpResult {
    let setEnabled: ConfigureEnabledFn
    let ids: [CGDirectDisplayID]
    do {
        setEnabled = try requireSymbol("CGSConfigureDisplayEnabled")
        ids = try enumerateDisplays()
    } catch { return failure(error) }
    let tag = label(id) // capture the name while the display is still online
    let builtin = CGDisplayIsBuiltin(id) != 0

    if CGDisplayIsOnline(id) == 0 {
        if builtin { rememberKeepOff(ids) }
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
        if builtin { rememberKeepOff(ids) }
        let note = builtin
            ? "While MacDisplay.app runs, it keeps it off whenever these external displays are connected; without the app, run `off` again after sleep/wake."
            : "Note: it may return after sleep/wake — run `off` again."
        return OpResult(ok: true, code: 0, message: "Display \(tag) disabled. \(note)")
    }
    return OpResult(ok: false, code: 1, message: "Commit reported success but display \(tag) is still online.")
}

/// Re-enable a display, re-deriving the id from CGSGetDisplayList before EACH of up to 3
/// attempts (~400 ms apart) — the whole point of the design (see KEY correctness fact above).
func enableDisplay(_ id: CGDirectDisplayID) -> OpResult {
    // Asking for on forgets the keep-off memory for the displays connected now, even if the
    // enable then fails, so a later lid open or replug (the recovery ladder) is not undone by the
    // menu bar app.
    if CGDisplayIsBuiltin(id) != 0, let ids = try? enumerateDisplays() { forgetKeepOff(ids) }
    let setEnabled: ConfigureEnabledFn
    do { setEnabled = try requireSymbol("CGSConfigureDisplayEnabled") } catch { return failure(error) }

    for attempt in 1...3 {
        // Re-derive the id from CGSGetDisplayList EVERY attempt — never reuse a stale integer.
        let ids: [CGDirectDisplayID]
        do { ids = try enumerateDisplays() } catch { return failure(error) }
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
