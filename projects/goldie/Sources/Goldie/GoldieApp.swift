import AppKit
import GoldieCore
import SwiftUI

@main
struct GoldieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(engine: appDelegate.engine, togglePanel: { appDelegate.togglePanel() })
        } label: {
            MenuLabel(engine: appDelegate.engine)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = GoldieEngine()
    private var panel: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // no Dock icon; Goldie lives on the desktop + menu bar
        panel = PanelController(engine: engine)
        engine.start()
    }

    func togglePanel() { panel?.toggle() }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }
}

/// Menu bar shows today's Cursor spend, e.g. "🐠 $3.20".
struct MenuLabel: View {
    @ObservedObject var engine: GoldieEngine
    var body: some View { Text(engine.menuTitle) }
}

struct MenuContent: View {
    @ObservedObject var engine: GoldieEngine
    let togglePanel: () -> Void

    var body: some View {
        Group {
            Text("Goldie: \(engine.verdict.mood.label)")
            Text("Today \(Fmt.usd(engine.snapshot.todayUSD)) · this month \(Fmt.usd(engine.snapshot.monthUSD))")
            Text("\(engine.snapshot.threads.count) active chat(s) · brain: \(engine.brainStatus)")
            Text("Cursor costs: \(engine.usageStatus)")
        }
        Divider()
        Button("Show / hide Goldie") { togglePanel() }
        Picker("Size", selection: $engine.bowlSize) {
            Text("Small").tag(130.0)
            Text("Medium").tag(170.0)
            Text("Large").tag(210.0)
        }
        Button("Install Cursor hooks") { engine.installHooks() }
        Button("Open config") { engine.openConfig() }
        Divider()
        Button("Quit Goldie") { NSApp.terminate(nil) }
    }
}

/// Borderless, transparent, always-on-top panel that never steals focus.
final class GoldiePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController {
    static let size = NSSize(width: 380, height: 820)
    let panel: GoldiePanel
    private let mover: WindowMover
    private let engine: GoldieEngine

    init(engine: GoldieEngine) {
        panel = GoldiePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        mover = WindowMover(panel: panel)
        self.engine = engine
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: GoldieRootView(engine: engine, mover: mover))

        let defaults = UserDefaults.standard
        if defaults.object(forKey: "goldie.panelX") != nil {  // where you last left her
            panel.setFrameOrigin(NSPoint(x: defaults.double(forKey: "goldie.panelX"), y: defaults.double(forKey: "goldie.panelY")))
        } else if let screen = NSScreen.main?.visibleFrame {  // first launch: bottom-right corner
            panel.setFrameOrigin(NSPoint(x: screen.maxX - Self.size.width - 12, y: screen.minY + 12))
        }
        Self.clampAndSave(panel)
        panel.orderFrontRegardless()
    }

    /// Keep the whole panel on screen (so the details card never opens off-screen) and remember the spot.
    static func clampAndSave(_ panel: NSPanel) {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var origin = panel.frame.origin
        origin.x = min(max(origin.x, visible.minX), visible.maxX - panel.frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)
        UserDefaults.standard.set(origin.x, forKey: "goldie.panelX")
        UserDefaults.standard.set(origin.y, forKey: "goldie.panelY")
    }

    func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        engine.panelVisible = panel.isVisible
    }
}

/// Drags the panel by the bowl. Uses screen coordinates so the view moving under the cursor
/// doesn't feed back into the drag.
@MainActor
final class WindowMover {
    private weak var panel: NSPanel?
    private var start: (mouse: NSPoint, origin: NSPoint)?

    init(panel: NSPanel) { self.panel = panel }

    func drag() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if start == nil { start = (mouse: mouse, origin: panel.frame.origin) }
        guard let s = start else { return }
        panel.setFrameOrigin(NSPoint(x: s.origin.x + mouse.x - s.mouse.x, y: s.origin.y + mouse.y - s.mouse.y))
    }

    func end() {
        start = nil
        if let panel { PanelController.clampAndSave(panel) }
    }
}
