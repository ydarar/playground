import AppKit
import ApplicationServices
import GoldieCore

/// Opens a new Cursor chat with a prompt: bring Cursor forward, open a new chat with its shortcuts,
/// paste, and (optionally) press Enter. Needs Accessibility permission to send keystrokes; without
/// it, it degrades to "prompt on clipboard + Cursor in front".
/// Safety: before every keystroke it checks that Cursor is still the frontmost app, and stops if not.
@MainActor
enum CursorAutopilot {
    static var cursorAppURL: URL? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == "Cursor" }?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92")
    }

    /// Brings Cursor forward. With a workspace, opens that folder in Cursor, which focuses the window
    /// for that repo (so the new chat lands in the right project when several are open).
    /// (A background app can't pull another app forward with activate() on macOS 14+; opening works.)
    static func bringCursorForward(workspace: String? = nil) {
        guard let app = cursorAppURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let workspace, FileManager.default.fileExists(atPath: workspace) {
            NSWorkspace.shared.open([URL(fileURLWithPath: workspace, isDirectory: true)], withApplicationAt: app,
                                    configuration: configuration, completionHandler: nil)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: nil)
        }
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows the macOS prompt that sends the user to Privacy & Security → Accessibility.
    static func requestAccessibility() {
        // Literal value of kAXTrustedCheckOptionPrompt (its Swift import has varied across SDKs).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private static var cursorIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.localizedName == "Cursor"
    }

    /// Returns a short status for a toast.
    static func startNewChat(prompt: String, workspace: String?, config: AutopilotConfig) async -> String {
        if config.mode == "deeplink", let url = deeplink(prompt) {
            bringCursorForward(workspace: workspace)
            await pause(0.8)
            NSWorkspace.shared.open(url)
            return "Opened a new Cursor chat with the handoff. Press Enter to send."
        }

        let pasteboard = NSPasteboard.general
        let previous = saveClipboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        bringCursorForward(workspace: workspace)

        guard config.mode == "keystrokes" else {
            return "Handoff copied. In Cursor, open a new chat and paste (⌘V)."
        }
        guard hasAccessibility else {
            requestAccessibility()
            return "Handoff copied. To let Goldie open the chat for you, allow Accessibility for Goldie (or the Terminal running it) in System Settings → Privacy & Security."
        }

        // Wait for Cursor to come forward.
        for _ in 0..<20 where !cursorIsFrontmost { await pause(0.1) }
        let lostFocus = "Cursor lost focus, so Goldie stopped. The handoff is on your clipboard: paste it into a new chat."
        for combo in config.newChatKeys {
            guard cursorIsFrontmost else { return lostFocus }
            press(combo)
            await pause(0.4)
        }
        guard cursorIsFrontmost else { return lostFocus }
        press("cmd+v")
        await pause(0.35)
        var sent = false
        if config.autoSend {
            guard cursorIsFrontmost else { return lostFocus }
            press("return")
            sent = true
        }
        if config.restoreClipboard, !previous.isEmpty {
            await pause(1.5)
            // Only if you haven't copied something new in the meantime.
            if pasteboard.string(forType: .string) == prompt { restoreClipboard(previous, to: pasteboard) }
        }
        return sent ? "Fresh chat started in Cursor 🐠" : "Fresh chat is ready in Cursor. Press Enter to send."
    }

    /// Cursor's prompt deeplink: opens a new chat prefilled with the text.
    static func deeplink(_ prompt: String) -> URL? {
        var components = URLComponents()
        components.scheme = "cursor"
        components.host = "anysphere.cursor-deeplink"
        components.path = "/prompt"
        components.queryItems = [URLQueryItem(name: "text", value: prompt)]
        return components.url
    }

    /// Every item and every type (text, images, files), so nothing on your clipboard is lost.
    private static func saveClipboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var byType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { byType[type] = data }
            }
            return byType
        }
    }

    private static func restoreClipboard(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { byType -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in byType { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// "cmd+shift+l" → key down/up with modifiers.
    static func press(_ combo: String) {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last, let code = keyCodes[keyName] else { return }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: break
            }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// US-ANSI virtual key codes.
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E, "return": 0x24, "enter": 0x24, "escape": 0x35, "tab": 0x30,
    ]
}
