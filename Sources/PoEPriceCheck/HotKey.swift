import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class HotKey {
    struct Combo: Equatable, Codable {
        var keyCode: UInt32
        var modifiers: UInt32   // Carbon modifier flags (controlKey, optionKey, shiftKey, cmdKey)
        var title: String
    }

    static let presets: [Combo] = [
        Combo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey), title: "⌃D"),
        Combo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | shiftKey), title: "⌃⇧D"),
        Combo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey), title: "⌥D"),
        Combo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey), title: "⌃⌥C"),
        Combo(keyCode: UInt32(kVK_F6), modifiers: 0, title: "F6"),
        Combo(keyCode: UInt32(kVK_F8), modifiers: 0, title: "F8"),
    ]
    static let escape = Combo(keyCode: UInt32(kVK_Escape), modifiers: 0, title: "Esc")

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(_ combo: Combo, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hkID = EventHotKeyID(signature: OSType(0x50_6F_45_50) /* 'PoEP' */, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hkID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if let h = HotKey.handlers[hk.id] { DispatchQueue.main.async(execute: h) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
