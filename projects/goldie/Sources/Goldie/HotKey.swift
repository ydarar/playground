import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut (Carbon hot key: works while other apps are focused, needs no
/// Accessibility permission). Goldie uses ⌃⌥⌘G to show/hide, so she's never stranded.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in hotKey.action() }
            return noErr
        }, 1, &spec, context, &handler)
        let id = EventHotKeyID(signature: OSType(0x474C_4459), id: 1)  // 'GLDY'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("Goldie: couldn't register the show/hide shortcut (another app may own it): \(status)") }
    }

    /// ⌃⌥⌘G
    static func controlOptionCommandG(_ action: @escaping @MainActor () -> Void) -> HotKey {
        HotKey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(controlKey | optionKey | cmdKey), action: action)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
