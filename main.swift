
// MxMaster3s.swift
// A tiny, zero-dependency menu-bar companion for a Logitech
// MX Master mouse on macOS 11 Big Sur. It does three things, nothing else:
//
//   1. Inverts mouse-wheel scrolling ONLY — the trackpad keeps its own
//      (natural) direction, and the system setting stays untouched.
//   2. Side back / forward buttons move one desktop (Space) left / right.
//   3. Shows the mouse battery percentage in the menu bar.
//
// Build:  ./build.sh
// Run:    ./MxMaster3s   (grant Accessibility when prompted)
//
// Techniques borrowed from open-source projects:
//   - Scroll Reverser / LinearMouse : per-device scroll inversion via CGEventTap
//   - AprilNEA/OpenLogi             : host-side remapping instead of Options+
//   - ioreg battery trick            : AppleDeviceManagementHIDEventService /
//                                      AppleHSBluetoothDevice publish "BatteryPercent"

import Cocoa
import IOKit
import IOKit.hidsystem



// MARK: - Configuration (edit to taste)

enum Config {

    /// Match your mouse by product name as it appears in ioreg.
    /// To find the exact name, run:
    ///   ioreg -c AppleDeviceManagementHIDEventService -r -l | grep -i -B2 BatteryPercent
    static let productMatch = "MX Master"
    /// Logitech USB vendor id, used as a fallback if the name doesn't match.
    static let logitechVendorID = 0x046D
    /// Debug logging to Terminal + Console.app. Set to false once all works.
    static let debug = true
    /// How often to re-read the battery, in seconds.
    static let batteryInterval: TimeInterval = 60
    /// macOS button numbers: 0 left, 1 right, 2 middle, 3 back, 4 forward.
    static let backButton = 3
    static let forwardButton = 4

    /// How often to check whether Accessibility permission has been granted.
    static let accessibilityPollInterval: TimeInterval = 2
    /// How often the watchdog re-enables the event tap.
    static let eventTapWatchdogInterval: TimeInterval = 5

}

/// Debug logging (when showLogs is enabled): Terminal, Console.app, and
/// appended to ~/Library/Logs/MxMaster3s.log so it can be read with:
///     tail -f ~/Library/Logs/MxMaster3s.log
func dbg(_ msg: @autoclosure () -> String) {
    guard UserDefaults.standard.bool(forKey: "showLogs") else { return }
    let line = "[MxMaster3s] " + msg()
   //= print(line)
    NSLog("%@", line)
    let path = NSHomeDirectory() + "/Library/Logs/MxMaster3s.log"
    let stamp = ISO8601DateFormatter().string(from: Date())
    let entry = "\(stamp) \(line)\n"
    let needsHeader = !FileManager.default.fileExists(atPath: path)
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        if needsHeader {
            let header = "All logs available at: \(path)\n"
            if let data = header.data(using: .utf8) { handle.write(data) }
        }
        if let data = entry.data(using: .utf8) { handle.write(data) }
        try? handle.close()
    } else {
        var content = ""
        if needsHeader {
            content += "All logs available at: \(path)\n"
        }
        content += entry
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Event tap callback (must be a free C function, no captures)

private func tapCallback(proxy: CGEventTapProxy,
                         type: CGEventType,
                         event: CGEvent,
                         userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
    let me = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // The system disables taps that are too slow; just re-enable.
        if let t = me.tapRef { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passRetained(event)

    case .scrollWheel:
        // Trackpad scroll events are "continuous"; mouse-wheel events are not.
        // Flip only the discrete ones, so the trackpad is never affected.
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
            // Axis1 = vertical scroll, Axis2 = horizontal scroll
            let verticalFields:   [CGEventField] = [.scrollWheelEventDeltaAxis1,
                                                     .scrollWheelEventPointDeltaAxis1]
            let horizontalFields: [CGEventField] = [.scrollWheelEventDeltaAxis2,
                                                     .scrollWheelEventPointDeltaAxis2]
            if me.invertScroll {
                for f in verticalFields {
                    let v = event.getIntegerValueField(f)
                    if v != 0 { event.setIntegerValueField(f, value: -v) }
                }
            }
            if me.invertScrollHorizontal {
                for f in horizontalFields {
                    let v = event.getIntegerValueField(f)
                    if v != 0 { event.setIntegerValueField(f, value: -v) }
                }
            }
        }

    case .otherMouseDown:
        let b = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        dbg("mouse button down: \(b)")
        if me.buttonsSwitchSpaces, b == Config.backButton || b == Config.forwardButton {
            me.heldButtons.insert(b)
            me.moveSpace(right: b == Config.forwardButton)
            return nil // swallow the raw button press
        }

    case .otherMouseUp:
        let b = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        dbg("mouse button up: \(b)")
        if me.heldButtons.remove(b) != nil { return nil }

    default:
        break
    }
    return Unmanaged.passRetained(event)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var tapRef: CFMachPort?
    private var tapSource: CFRunLoopSource?
    var heldButtons = Set<Int>()
    private var logViewerApp: NSRunningApplication?

    // Settings, persisted across launches with UserDefaults.
    var invertScroll: Bool {
        get { UserDefaults.standard.bool(forKey: "invertScroll") }
        set { UserDefaults.standard.set(newValue, forKey: "invertScroll") }
    }
    var invertScrollHorizontal: Bool {
        get { UserDefaults.standard.bool(forKey: "invertScrollHorizontal") }
        set { UserDefaults.standard.set(newValue, forKey: "invertScrollHorizontal") }
    }
    var buttonsSwitchSpaces: Bool {
        get { UserDefaults.standard.bool(forKey: "buttonsSwitchSpaces") }
        set { UserDefaults.standard.set(newValue, forKey: "buttonsSwitchSpaces") }
    }
    var showLogs: Bool {
        get { UserDefaults.standard.bool(forKey: "showLogs") }
        set { UserDefaults.standard.set(newValue, forKey: "showLogs") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["invertScroll": true,
                                                  "invertScrollHorizontal": false,
                                                  "buttonsSwitchSpaces": true,
                                                  "showLogs": false])
        dbg("started — path: \(Bundle.main.bundlePath)")

        // --- menu bar ---
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Invert mouse scroll",
                     action: #selector(toggleInvert), keyEquivalent: "")
        menu.addItem(withTitle: "Invert horizontal scroll",
                     action: #selector(toggleInvertHorizontal), keyEquivalent: "")
        menu.addItem(withTitle: "Side buttons switch desktops",
                     action: #selector(toggleButtons), keyEquivalent: "")
        menu.addItem(withTitle: "Show logs",
                     action: #selector(toggleShowLogs), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh battery now",
                     action: #selector(refreshBattery), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Help",
                     action: #selector(showHelp), keyEquivalent: "")
        menu.addItem(withTitle: "Quit",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items {
            if item.action != #selector(NSApplication.terminate(_:)) && item.action != nil {
                item.target = self
            }
        }
        statusItem.menu = menu

        refreshBattery(nil)
        Timer.scheduledTimer(withTimeInterval: Config.batteryInterval,
                             repeats: true) { [weak self] _ in self?.refreshBattery(nil) }

        // --- event tap ---
        if AXIsProcessTrusted() {
            dbg("accessibility: trusted")
            makeTap()
        } else {
            // Prompt for Accessibility, then poll until granted.
            dbg("accessibility: NOT granted yet — waiting…")
            statusItem.button?.title = "🖱 ⚠️"
            statusItem.button?.toolTip = "Open System Preferences › Security & Privacy › "
                + "Privacy › Accessibility and allow MxMaster3s. "
                + "It activates automatically once granted."
            // == optional prompt for permissions (not used because customized)
            //== let prompt: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
            //== _ = AXIsProcessTrustedWithOptions(prompt as CFDictionary)
            // == optional prompt for permissions (not used because customized)
            Timer.scheduledTimer(withTimeInterval: Config.accessibilityPollInterval, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    dbg("accessibility: granted — activating event tap")
                    self?.makeTap()
                    self?.refreshBattery(nil)
                }
            }
        }

        // Watchdog: keep the tap alive forever (sleep/wake, timeouts...).
        Timer.scheduledTimer(withTimeInterval: Config.eventTapWatchdogInterval, repeats: true) { [weak self] _ in
            if let t = self?.tapRef { CGEvent.tapEnable(tap: t, enable: true) }
        }

        // --- permission check on launch ---
        if !AXIsProcessTrusted() || !isInputMonitoringAuthorized() {
            showPermissionAlert(
                missingAccessibility: !AXIsProcessTrusted(),
                missingInputMonitoring: !isInputMonitoringAuthorized())
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items[0].state = invertScroll ? .on : .off
        menu.items[1].state = invertScrollHorizontal ? .on : .off
        menu.items[2].state = buttonsSwitchSpaces ? .on : .off
        menu.items[3].state = showLogs ? .on : .off
    }

    @objc private func toggleInvert() { invertScroll.toggle() }
    @objc private func toggleInvertHorizontal() { invertScrollHorizontal.toggle() }
    @objc private func toggleButtons() { buttonsSwitchSpaces.toggle() }
    @objc private func toggleShowLogs() {
        showLogs.toggle()
        let logPath = NSHomeDirectory() + "/Library/Logs/MxMaster3s.log"
        if showLogs {
            if !FileManager.default.fileExists(atPath: logPath) {
                try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
            }
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath),
                                    configuration: config) { [weak self] app, _ in
                self?.logViewerApp = app
            }
        } else if let app = logViewerApp {
            app.terminate()
            logViewerApp = nil
        }
    }

    @objc private func showHelp() {
        showPermissionAlert(missingAccessibility: !AXIsProcessTrusted(),
                            missingInputMonitoring: !isInputMonitoringAuthorized())
    }

    @objc func refreshBattery(_ sender: Any?) {

        if let found = BatteryHelper.getBattery() {
            if found.percent >= 0 && found.percent <= 100 {
                dbg("battery display: \(found.name) at \(found.percent)%")
                statusItem.button?.title = "🖱 \(found.percent)%"
                statusItem.button?.toolTip = "\(found.name) — battery \(found.percent)%"
            } else {
                statusItem.button?.title = "🖱 --"
                statusItem.button?.toolTip = "Battery info not available for Bluetooth LE devices"
            }
        } else {
            statusItem.button?.title = "🖱 --"
            statusItem.button?.toolTip = "No battery info found"
        }
    }

    // MARK: Event tap

    func makeTap() {
        guard tapRef == nil else { return }
        var mask = UInt64(0)
        for t in [CGEventType.scrollWheel, .otherMouseDown, .otherMouseUp,
                  .tapDisabledByTimeout, .tapDisabledByUserInput] {
            mask |= 1 << UInt64(t.rawValue)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                         place: .headInsertEventTap,
                                         options: .defaultTap, // filter: we may modify
                                         eventsOfInterest: CGEventMask(mask),
                                         callback: tapCallback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            dbg("event tap NOT created — Accessibility is missing for this build")
            return
        } // happens if Accessibility is not granted yet
        tapRef = tap
        dbg("event tap active — scroll + side buttons hooked")
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, CFRunLoopMode.commonModes)
    }

    /// Post Mission Control shortcuts to switch desktops 
func moveSpace(right: Bool) {
    let key: CGKeyCode = right ? 124 : 123 // kVK_RightArrow / kVK_LeftArrow
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }

    // Mission Control ignores ctrl+arrow unless it also has the fn/numeric-pad
    // flags that real keyboards attach to arrow keys.
    let flags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]

    let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)

    let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)

    dbg("posted desktop switch keys (right=\(right))")
}



}


// MARK: - Permission helpers

/// Checks whether the app is authorized for Input Monitoring by attempting
/// to create a short-lived keyboard event tap.  If the tap is created the
/// permission is granted; if it fails the permission is missing.
@inline(__always)
private func isInputMonitoringAuthorized() -> Bool {
    let keyboardMask: CGEventMask =
        (1 << UInt64(CGEventType.keyDown.rawValue)) |
        (1 << UInt64(CGEventType.keyUp.rawValue))
    let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                place: .headInsertEventTap,
                                options: .listenOnly,
                                eventsOfInterest: keyboardMask,
                                callback: { _, _, _, _ in nil },
                                userInfo: nil)
    if let t = tap {
        CFMachPortInvalidate(t)
        return true
    }
    return false
}

/// Opens the Accessibility subsection of the Privacy tab.
private func openAccessibilitySettings() {
    if #available(macOS 13, *) {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systemsettings:com.apple.systemsettings.PrivacyAndSecurity")!
        )
    } else {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }
}

/// Opens the Input Monitoring subsection of the Privacy tab.
private func openInputMonitoringSettings() {
    if #available(macOS 13, *) {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systemsettings:com.apple.systemsettings.PrivacyAndSecurity")!
        )
    } else {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        )
    }
}

/// Opens System Preferences / Settings to the Privacy & Security page.
private func openPrivacySecuritySettings() {
    if #available(macOS 13, *) {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systemsettings:com.apple.systemsettings.PrivacyAndSecurity")!
        )
    } else {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Section=Privacy")!
        )
    }
}

/// Shows an alert that either lists missing permissions (with two buttons —
/// one per permission) or confirms all permissions are granted.
private func showPermissionAlert(missingAccessibility: Bool,
                                  missingInputMonitoring: Bool) {
    let allGranted = !missingAccessibility && !missingInputMonitoring
    var msg = ""
    if !missingAccessibility {
        msg += "• Accessibility — ✅ granted\n"
    } else {
        msg += "• Accessibility — required for intercepting and inverting scroll events.\n"
          + "  System Settings › Privacy & Security › Accessibility › add MxMaster3s\n"
    }
    if !missingInputMonitoring {
        msg += "• Input Monitoring — ✅ granted\n"
    } else {
        msg += "• Input Monitoring — required for low-level mouse event capture.\n"
          + "  System Settings › Privacy & Security › Input Monitoring › add MxMaster3s\n"
    }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.window.level = .modalPanel

    if allGranted {
        alert.messageText = "All permissions granted"
        alert.informativeText = "MxMaster3s has all required permissions. ✓"
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openPrivacySecuritySettings()
        }
    } else {
        alert.messageText = "Permissions required"
        alert.informativeText = msg
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Open Input Monitoring Settings")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openAccessibilitySettings()
        case .alertSecondButtonReturn:
            openInputMonitoringSettings()
        default:
            break
        }
    }
}

// MARK: - main
@main
struct MxMaster3s {
    static func main() {
        let app = NSApplication.shared
        let appDelegate = AppDelegate()

        app.delegate = appDelegate
        app.setActivationPolicy(.accessory) // no Dock icon, just the menu bar
        app.run()
    }
}
