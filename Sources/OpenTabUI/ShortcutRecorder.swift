import AppKit
import Carbon.HIToolbox
import OpenTabCore
import SwiftUI

/// Records a key combination by having the user press it.
///
/// Split into two fields — modifiers and key — because that is what the
/// interaction actually is: the modifiers are what you *hold* for the duration of
/// the switch, and the key is what you *tap* to advance. A single combined field
/// would obscure that a binding with no modifiers cannot drive hold-and-cycle at
/// all.
public struct ShortcutRecorderField: View {

    @Binding var combo: KeyCombo
    /// Record only the modifiers, or only the key.
    let mode: Mode

    public enum Mode {
        case modifiers
        case key
    }

    @State private var isRecording = false

    public init(combo: Binding<KeyCombo>, mode: Mode) {
        self._combo = combo
        self.mode = mode
    }

    private var displayText: String {
        switch mode {
        case .modifiers:
            return combo.modifiers.isEmpty ? "—" : combo.modifiers.displayString
        case .key:
            return KeyCodes.displayName(for: combo.keyCode)
        }
    }

    public var body: some View {
        RecorderView(isRecording: $isRecording) { event in
            apply(event)
        }
        .frame(width: mode == .modifiers ? 96 : 72, height: 26)
        .overlay(
            Text(isRecording ? "…" : displayText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
        )
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isRecording ? 2 : 1
                )
        )
        .help(isRecording
              ? "Press the keys you want to use"
              : "Click, then press the keys you want to use")
    }

    private func apply(_ event: RecordedEvent) {
        switch mode {
        case .modifiers:
            // Modifiers are captured on their own, so an empty set is meaningful:
            // it means the user pressed a bare key, which cannot work here.
            guard !event.modifiers.isEmpty else { return }
            combo.modifiers = event.modifiers
        case .key:
            guard let keyCode = event.keyCode else { return }
            combo.keyCode = keyCode
        }
        isRecording = false
    }
}

/// What the recorder captured.
struct RecordedEvent {
    let keyCode: UInt16?
    let modifiers: ModifierSet
}

/// AppKit view that captures raw key events while focused.
///
/// SwiftUI cannot express this: it needs the unprocessed key code, and it must see
/// combinations like ⌘Q without AppKit routing them to the menu bar first.
private struct RecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onRecord: (RecordedEvent) -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onRecord = onRecord
        view.onRecordingChanged = { isRecording = $0 }
        return view
    }

    func updateNSView(_ view: KeyCaptureView, context: Context) {
        view.onRecord = onRecord
        if isRecording && view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }
}

/// First responder that swallows key events and reports them.
final class KeyCaptureView: NSView {
    var onRecord: ((RecordedEvent) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var isRecording = false {
        didSet { onRecordingChanged?(isRecording) }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }

        // Escape abandons the recording rather than binding Escape, which is
        // almost never what someone wants and would be hard to undo.
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        onRecord?(RecordedEvent(
            keyCode: event.keyCode,
            modifiers: ModifierSet(eventFlags: event.cgEvent?.flags ?? [])
        ))
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    /// Modifier-only presses never produce a keyDown, so the modifier field is
    /// driven from here instead.
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }

        let modifiers = ModifierSet(eventFlags: event.cgEvent?.flags ?? [])
        guard !modifiers.isEmpty else { return }
        onRecord?(RecordedEvent(keyCode: nil, modifiers: modifiers))
    }

    /// Stops AppKit turning ⌘Q into "quit" before this view sees it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
}
