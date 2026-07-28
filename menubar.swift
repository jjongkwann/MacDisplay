// macdisplay menu bar app — an NSStatusItem that lists every display and toggles it on click.
//
// LSUIElement (.accessory): no Dock icon, no menu bar app menu — just the status item. The menu
// is rebuilt fresh on every open (menuWillOpen) straight from CGSGetDisplayList, so it always
// reflects the live topology. All display logic lives in core.swift; this file is only the UI.

import AppKit
import CoreGraphics

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!

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
    }

    // Rebuild the menu from the current display list every time it opens.
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let getList: GetDisplayListFn = requireSymbol("CGSGetDisplayList")
        let ids = enumerateDisplays(getList)
        let names = onlineNames()
        let cache = refreshNameCache() // remember online names so offline ones stay labeled
        let activeCount = ids.filter { CGDisplayIsActive($0) != 0 }.count

        for id in ids {
            let online  = CGDisplayIsOnline(id) != 0
            let builtin = CGDisplayIsBuiltin(id) != 0
            let name    = displayName(id, names, cache)
            // ghosts: stale CGSGetDisplayList ids with no hardware — via the id-keyed name cache
            // they'd render as duplicates of the re-enumerated display and error on click.
            if isGhost(id) { continue }
            // (a) hide phantoms: offline, no cached real name, and not the built-in panel.
            if !online && !builtin && name == "Display \(id)" { continue }

            let item = NSMenuItem(title: "\(name)  (#\(id))", action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(id)
            item.state = online ? .on : .off
            // (b) the last remaining active display is shown but disabled — can't black out everything.
            item.isEnabled = !(activeCount == 1 && CGDisplayIsActive(id) != 0)
            menu.addItem(item)
        }

        menu.addItem(.separator()) // (d)
        menu.addItem(NSMenuItem(title: "Quit MacDisplay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggle(_ sender: NSMenuItem) {
        let id = CGDirectDisplayID(sender.tag)
        let result = CGDisplayIsOnline(id) != 0 ? disableDisplay(id) : enableDisplay(id)
        if !result.ok { showFailure(result.message) } // (c)
    }

    // (c) on operation failure, surface the error and the recovery ladder in an alert.
    func showFailure(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = recoveryLadderText
        alert.runModal()
    }
}
