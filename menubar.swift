// macdisplay menu bar app — an NSStatusItem that lists every display and toggles it on click.
//
// LSUIElement (.accessory): no Dock icon, no menu bar app menu — just the status item. The menu
// is rebuilt fresh on every open (menuWillOpen) straight from CGSGetDisplayList, so it always
// reflects the live topology. All display logic lives in core.swift; this file is the UI, plus
// the one thing only a resident process can do: turning the built-in off again after macOS
// brings it back (see reassertBuiltinOff).

import AppKit
import CoreGraphics

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var attempts: [Date] = [] // recent attempts to turn the built-in off again (see reassertBuiltinOff)

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "MacDisplay")
        let menu = NSMenu()
        menu.delegate = self // menuWillOpen rebuilds it each time
        menu.autoenablesItems = false // we set isEnabled manually; default validation would override it
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displaysChanged(_:)),
            name: NSWorkspace.didWakeNotification, object: nil)
        // Launched at login at the desk: apply the memory once the displays have settled.
        perform(#selector(reassertBuiltinOff), with: nil, afterDelay: 2)
    }

    // Rebuild the menu from the current display list every time it opens.
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        defer {
            menu.addItem(.separator()) // (d)
            menu.addItem(NSMenuItem(title: "Quit MacDisplay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        }
        let ids: [CGDirectDisplayID]
        do { ids = try enumerateDisplays() } catch {
            // e.g. a macOS update removed the private symbol: say so in the menu instead of quitting.
            let item = NSMenuItem(title: failure(error).message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        let names = onlineNames()
        let cache = refreshNameCache() // remember online names so offline ones stay labeled
        let activeCount = ids.filter { CGDisplayIsActive($0) != 0 }.count

        for id in ids {
            let online = CGDisplayIsOnline(id) != 0
            let name   = displayName(id, names, cache)
            // ghosts: stale CGSGetDisplayList ids with no hardware — they would error on click.
            if isGhost(id) { continue }
            // (a) hide phantoms: offline and never seen online, so there is no name to show.
            if !online && name == nil { continue }

            let item = NSMenuItem(title: "\(name ?? "Display \(id)")  (#\(id))", action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(id)
            item.state = online ? .on : .off
            // (b) the last remaining active display is shown but disabled — can't black out everything.
            item.isEnabled = !(activeCount == 1 && CGDisplayIsActive(id) != 0)
            menu.addItem(item)
        }
    }

    @objc func toggle(_ sender: NSMenuItem) {
        let id = CGDirectDisplayID(sender.tag)
        let result = CGDisplayIsOnline(id) != 0 ? disableDisplay(id) : enableDisplay(id)
        if !result.ok { showAlert(result.message, recoveryLadderText) } // (c)
    }

    // MARK: - keep the built-in off

    // macOS re-adds a disabled display on wake, lid open and hotplug, usually in a burst of
    // notifications. Wait for the burst to settle, then act once.
    @objc func displaysChanged(_ note: Notification) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reassertBuiltinOff), object: nil)
        perform(#selector(reassertBuiltinOff), with: nil, afterDelay: 2)
    }

    /// Turn the built-in off if it is on while an external display it was last turned off with is
    /// active (see keepOffWith in core.swift). Undocked, or on an unknown display, nothing happens.
    @objc func reassertBuiltinOff() {
        guard let ids = try? enumerateDisplays(), let builtin = firstBuiltin(ids),
              CGDisplayIsOnline(builtin) != 0 else { return }
        let here = externalIdentities(ids, activeOnly: true)
        guard !here.isDisjoint(with: keepOffWith) else { return }
        // The panel coming back right after each attempt means something is fighting us: stop
        // rather than flicker. Failed attempts count too — they reconfigure the displays as well.
        attempts = attempts.filter { $0.timeIntervalSinceNow > -60 }
        if attempts.count >= 3 {
            forgetKeepOff(ids)
            attempts = []
            showAlert("MacDisplay stopped keeping the built-in display off.",
                      "It came back after 3 attempts to turn it off within a minute. Turn it off again to retry.")
            return
        }
        attempts.append(Date())
        let result = disableDisplay(builtin)
        if !result.ok { NSLog("MacDisplay: %@", result.message) }
    }

    // (c) surface a failure (with the recovery ladder, for a failed toggle) in an alert.
    func showAlert(_ message: String, _ info: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
