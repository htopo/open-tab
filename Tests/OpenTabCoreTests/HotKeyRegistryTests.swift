import Carbon.HIToolbox
import Testing
@testable import OpenTabCore
@testable import OpenTabInput

/// The translation into Carbon's modifier bits.
///
/// This is the fallback path's blind spot: registration succeeds whatever bits
/// are handed over, so a wrong one produces a hot key for a combination nobody
/// will ever press. Nothing reports that — it looks exactly like a fallback
/// that does not work.
@Suite("System hot key registration")
struct HotKeyRegistryTests {

    @Test("Each modifier maps to its Carbon bit")
    func singleModifiersMap() {
        #expect(HotKeyRegistry.carbonModifiers(.command) == UInt32(cmdKey))
        #expect(HotKeyRegistry.carbonModifiers(.option) == UInt32(optionKey))
        #expect(HotKeyRegistry.carbonModifiers(.control) == UInt32(controlKey))
        #expect(HotKeyRegistry.carbonModifiers(.shift) == UInt32(shiftKey))
    }

    @Test("Combinations map to the union of their bits")
    func combinationsMap() {
        #expect(HotKeyRegistry.carbonModifiers([.command, .shift])
                == UInt32(cmdKey | shiftKey))
        #expect(HotKeyRegistry.carbonModifiers([.control, .option, .command])
                == UInt32(controlKey | optionKey | cmdKey))
    }

    @Test("No modifiers maps to no bits")
    func emptyMapsToZero() {
        #expect(HotKeyRegistry.carbonModifiers([]) == 0)
    }

    /// The bits are genuinely distinct, so a copy-paste slip between the four
    /// branches would show up here rather than as a shortcut that quietly does
    /// the wrong thing.
    @Test("The four modifiers are distinguishable")
    func modifiersDoNotCollide() {
        let all: [ModifierSet] = [.command, .option, .control, .shift]
        let mapped = Set(all.map { HotKeyRegistry.carbonModifiers($0) })
        #expect(mapped.count == all.count)
    }

    /// The switcher stays open for as long as its modifiers are held, so a
    /// binding with none of them cannot express the interaction at all — and a
    /// bare key registered system-wide would swallow that key everywhere.
    @Test("A shortcut with no modifiers is not registered")
    func bareKeysAreSkipped() {
        let bare = KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: [])
        #expect(!bare.isUsableAsHoldShortcut)
    }
}
