import Carbon
import Foundation

/// Translates Carbon virtual keycodes into the user's active keyboard layout glyphs
/// (supporting international layouts like AZERTY, QWERTZ, Dvorak, Colemak).
public struct KeyTranslator {
    public static func displayString(for keyCode: UInt16) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return fallbackKeyName(for: keyCode)
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
        let keyLayoutPtr = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
        
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength: Int = 0
        
        let status = UCKeyTranslate(
            keyLayoutPtr,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &actualLength,
            &chars
        )
        guard status == noErr, actualLength > 0 else { return fallbackKeyName(for: keyCode) }
        return String(utf16CodeUnits: chars, count: actualLength).uppercased()
    }
    
    private static func fallbackKeyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x24: return "↩"
        case 0x30: return "⇥"
        case 0x31: return "Space"
        default: return "Key(\(keyCode))"
        }
    }
}
