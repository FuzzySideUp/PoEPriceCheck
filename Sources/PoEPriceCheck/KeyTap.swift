import AppKit
import Carbon.HIToolbox
import IOKit.hid

/// Listen-only keyboard tap at the HID level. Sees keys before apps that grab the keyboard
/// (Chrome's fullscreen Keyboard Lock used by GeForce NOW in the browser), which swallow Carbon hotkeys.
/// It never blocks or injects events. Needs Input Monitoring permission.
final class KeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let onKey: (UInt32, CGEventFlags) -> Void

    static var hasPermission: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    @discardableResult static func requestPermission() -> Bool { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }

    init?(onKey: @escaping (UInt32, CGEventFlags) -> Void) {
        self.onKey = onKey
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                DispatchQueue.main.async { me.onKey(code, flags) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else { return nil }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    /// Does a key event match a Carbon-style combo (exact modifiers)?
    static func matches(_ combo: HotKey.Combo, keyCode: UInt32, flags: CGEventFlags) -> Bool {
        guard keyCode == combo.keyCode else { return false }
        var want: CGEventFlags = []
        if combo.modifiers & UInt32(controlKey) != 0 { want.insert(.maskControl) }
        if combo.modifiers & UInt32(optionKey) != 0 { want.insert(.maskAlternate) }
        if combo.modifiers & UInt32(shiftKey) != 0 { want.insert(.maskShift) }
        if combo.modifiers & UInt32(cmdKey) != 0 { want.insert(.maskCommand) }
        let have = flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        return have == want
    }
}
