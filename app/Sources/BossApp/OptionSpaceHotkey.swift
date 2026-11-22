import Carbon
import AppKit
import BossCore

/// ⌥Space as a talk key, registered with RegisterEventHotKey: a standard global shortcut that needs
/// no Input Monitoring or Accessibility permission (for Macs where those need an admin).
/// Hold it and release to send, or tap it to start and tap again to send. While recording, Esc is
/// registered too so it cancels; it is released again afterwards.
@MainActor
final class OptionSpaceHotkey {
    static var shared: OptionSpaceHotkey?
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onEscape: (() -> Void)?
    private var talkRef: EventHotKeyRef?
    private var escRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var registered = false

    func install() {
        OptionSpaceHotkey.shared = self
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let kind = GetEventKind(event)
            MainActor.assumeIsolated {
                guard let me = OptionSpaceHotkey.shared else { return }
                if id.id == 1 { kind == UInt32(kEventHotKeyPressed) ? me.onDown?() : me.onUp?() }
                if id.id == 2 && kind == UInt32(kEventHotKeyPressed) { me.onEscape?() }
            }
            return noErr
        }, types.count, &types, nil, &handler)
        let st = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: OSType(0x424F5353), id: 1),
                                     GetApplicationEventTarget(), 0, &talkRef)
        registered = st == noErr
        if !registered { NSLog("Boss: Option+Space is taken by another app (\(st))") }
    }

    /// Esc cancels only while Boss is recording, so it is not taken from other apps otherwise.
    func setEscapeActive(_ on: Bool) {
        if on, escRef == nil {
            RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: OSType(0x424F5353), id: 2), GetApplicationEventTarget(), 0, &escRef)
        } else if !on, let r = escRef {
            UnregisterEventHotKey(r); escRef = nil
        }
    }
}
