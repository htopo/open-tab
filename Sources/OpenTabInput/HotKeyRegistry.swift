import AppKit
import Carbon.HIToolbox
import Foundation
import OpenTabCore

/// Shortcuts registered with the system, rather than read from the event stream.
///
/// This exists for one situation: an application has taken the keyboard
/// exclusively — a password field, including a terminal asking for an `ssh`
/// password — and the event tap is shut out. That is deliberate on macOS's part
/// and not something to defeat. But a registered hot key is a different
/// arrangement entirely: nothing is being read as it passes, the system is
/// being asked to deliver one specific combination and it decides whether to.
///
/// The two paths cannot both fire. The tap sits at the head of the session
/// chain and swallows the shortcut, so a hot key only ever sees what the tap
/// did not. Registration is nevertheless confined to the window where the tap
/// is blind, because a shortcut deliberately passed through — to a virtual
/// machine, say — must reach that application and not be caught here on its way.
@MainActor
public final class HotKeyRegistry {

    /// Called with the index of the shortcut that fired.
    public var onFire: ((Int) -> Void)?

    /// Carbon addresses hot keys by a four-character signature. This one is
    /// arbitrary; it only has to be ours.
    private static let signature: OSType = 0x4F54_4142  // 'OTAB'

    /// The Carbon callback is a C function pointer with no room for context, so
    /// it needs a way back. Weak: the registry belongs to the controller.
    private static weak var current: HotKeyRegistry?

    private var registered: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    public init() {}

    public var isRegistered: Bool { !registered.isEmpty }

    /// Registers each shortcut that can drive a hold-and-cycle interaction.
    ///
    /// - Returns: how many were accepted. A combination the system has already
    ///   given to someone else is refused, which is worth knowing about but not
    ///   worth failing over — the others still work.
    @discardableResult
    public func register(_ combos: [KeyCombo]) -> Int {
        unregister()
        Self.current = self
        installHandler()

        for (index, combo) in combos.enumerated() where combo.isUsableAsHoldShortcut {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let status = RegisterEventHotKey(
                UInt32(combo.keyCode),
                Self.carbonModifiers(combo.modifiers),
                id,
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                registered.append(ref)
            } else {
                Log.hotkeys.notice(
                    "System refused \(combo.displayString, privacy: .public) as a hot key: status \(status)"
                )
            }
        }
        return registered.count
    }

    public func unregister() {
        for ref in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
    }

    // MARK: - Carbon plumbing

    private func installHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &id)
            guard status == noErr, id.signature == HotKeyRegistry.signature else { return noErr }

            // Carbon dispatches on the main thread; this is the same run loop
            // the rest of the switcher lives on.
            MainActor.assumeIsolated {
                HotKeyRegistry.current?.onFire?(Int(id.id))
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    /// Carbon predates `CGEventFlags` and uses its own bits.
    ///
    /// Internal rather than private so the mapping can be tested. A wrong bit
    /// here registers a different shortcut than the user configured, and the
    /// only symptom is a fallback that never fires.
    nonisolated static func carbonModifiers(_ modifiers: ModifierSet) -> UInt32 {
        var carbon: Int = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.option)  { carbon |= optionKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.shift)   { carbon |= shiftKey }
        return UInt32(carbon)
    }
}
