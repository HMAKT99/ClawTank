// RDP Set-1 scancodes → macOS virtual key codes.
//
// Both are *positional* (they name a physical key, not a character), so the Mac's own input
// source decides what a key types. A user with a French or German layout selected on the Mac
// gets the right characters from a client on the same layout. Characters that have no key
// (IME, on-screen keyboards) arrive as Unicode events instead and bypass this table.

import Carbon.HIToolbox
import CoreGraphics

enum ScancodeMap {
    /// Media keys delivered as NX_SYSDEFINED events, not key codes.
    enum MediaKey: Int32 {
        case volumeUp = 0      // NX_KEYTYPE_SOUND_UP
        case volumeDown = 1    // NX_KEYTYPE_SOUND_DOWN
        case mute = 7          // NX_KEYTYPE_MUTE
        case playPause = 16    // NX_KEYTYPE_PLAY
        case next = 17         // NX_KEYTYPE_NEXT
        case previous = 18     // NX_KEYTYPE_PREVIOUS
    }

    enum Target: Equatable {
        case key(CGKeyCode)
        case media(MediaKey)
    }

    static let plain: [UInt8: Int] = [
        0x01: kVK_Escape,
        0x02: kVK_ANSI_1, 0x03: kVK_ANSI_2, 0x04: kVK_ANSI_3, 0x05: kVK_ANSI_4, 0x06: kVK_ANSI_5,
        0x07: kVK_ANSI_6, 0x08: kVK_ANSI_7, 0x09: kVK_ANSI_8, 0x0A: kVK_ANSI_9, 0x0B: kVK_ANSI_0,
        0x0C: kVK_ANSI_Minus, 0x0D: kVK_ANSI_Equal, 0x0E: kVK_Delete, 0x0F: kVK_Tab,
        0x10: kVK_ANSI_Q, 0x11: kVK_ANSI_W, 0x12: kVK_ANSI_E, 0x13: kVK_ANSI_R, 0x14: kVK_ANSI_T,
        0x15: kVK_ANSI_Y, 0x16: kVK_ANSI_U, 0x17: kVK_ANSI_I, 0x18: kVK_ANSI_O, 0x19: kVK_ANSI_P,
        0x1A: kVK_ANSI_LeftBracket, 0x1B: kVK_ANSI_RightBracket, 0x1C: kVK_Return, 0x1D: kVK_Control,
        0x1E: kVK_ANSI_A, 0x1F: kVK_ANSI_S, 0x20: kVK_ANSI_D, 0x21: kVK_ANSI_F, 0x22: kVK_ANSI_G,
        0x23: kVK_ANSI_H, 0x24: kVK_ANSI_J, 0x25: kVK_ANSI_K, 0x26: kVK_ANSI_L,
        0x27: kVK_ANSI_Semicolon, 0x28: kVK_ANSI_Quote, 0x29: kVK_ANSI_Grave, 0x2A: kVK_Shift,
        0x2B: kVK_ANSI_Backslash, 0x2C: kVK_ANSI_Z, 0x2D: kVK_ANSI_X, 0x2E: kVK_ANSI_C,
        0x2F: kVK_ANSI_V, 0x30: kVK_ANSI_B, 0x31: kVK_ANSI_N, 0x32: kVK_ANSI_M, 0x33: kVK_ANSI_Comma,
        0x34: kVK_ANSI_Period, 0x35: kVK_ANSI_Slash, 0x36: kVK_RightShift,
        0x37: kVK_ANSI_KeypadMultiply, 0x38: kVK_Option, 0x39: kVK_Space, 0x3A: kVK_CapsLock,
        0x3B: kVK_F1, 0x3C: kVK_F2, 0x3D: kVK_F3, 0x3E: kVK_F4, 0x3F: kVK_F5, 0x40: kVK_F6,
        0x41: kVK_F7, 0x42: kVK_F8, 0x43: kVK_F9, 0x44: kVK_F10,
        0x45: kVK_ANSI_KeypadClear,  // Num Lock (Mac keypads have Clear in that position)
        0x47: kVK_ANSI_Keypad7, 0x48: kVK_ANSI_Keypad8, 0x49: kVK_ANSI_Keypad9,
        0x4A: kVK_ANSI_KeypadMinus, 0x4B: kVK_ANSI_Keypad4, 0x4C: kVK_ANSI_Keypad5,
        0x4D: kVK_ANSI_Keypad6, 0x4E: kVK_ANSI_KeypadPlus, 0x4F: kVK_ANSI_Keypad1,
        0x50: kVK_ANSI_Keypad2, 0x51: kVK_ANSI_Keypad3, 0x52: kVK_ANSI_Keypad0,
        0x53: kVK_ANSI_KeypadDecimal,
        0x56: kVK_ISO_Section,       // ISO key left of Z (<> on German/French boards)
        0x57: kVK_F11, 0x58: kVK_F12, 0x59: kVK_ANSI_KeypadEquals,
        0x64: kVK_F13, 0x65: kVK_F14, 0x66: kVK_F15, 0x67: kVK_F16, 0x68: kVK_F17,
        0x69: kVK_F18, 0x6A: kVK_F19, 0x6B: kVK_F20,
        0x70: kVK_JIS_Kana, 0x73: kVK_JIS_Underscore, 0x7B: kVK_JIS_Eisu, 0x7D: kVK_JIS_Yen,
        0x7E: kVK_JIS_KeypadComma
    ]

    static let extended: [UInt8: Int] = [
        0x1C: kVK_ANSI_KeypadEnter, 0x1D: kVK_RightControl, 0x35: kVK_ANSI_KeypadDivide,
        0x37: kVK_F13,               // Print Screen → F13 (the Mac's conventional stand-in)
        0x38: kVK_RightOption, 0x47: kVK_Home, 0x48: kVK_UpArrow, 0x49: kVK_PageUp,
        0x4B: kVK_LeftArrow, 0x4D: kVK_RightArrow, 0x4F: kVK_End, 0x50: kVK_DownArrow,
        0x51: kVK_PageDown, 0x52: kVK_Help,  // Insert → Help (same position on Mac keyboards)
        0x53: kVK_ForwardDelete, 0x5B: kVK_Command, 0x5C: kVK_RightCommand,
        0x5D: kVK_ContextualMenu
    ]

    static let media: [UInt8: MediaKey] = [
        0x20: .mute, 0x2E: .volumeDown, 0x30: .volumeUp, 0x22: .playPause, 0x19: .next, 0x10: .previous
    ]

    /// Maps a scancode. With `swapControlCommand`, Ctrl ↔ ⌘ (Windows key) so Ctrl+C copies.
    static func target(scancode: UInt8, extended isExtended: Bool, swapControlCommand: Bool) -> Target? {
        if isExtended, let mediaKey = media[scancode] {
            return .media(mediaKey)
        }
        guard var code = (isExtended ? extended : plain)[scancode] else { return nil }
        if swapControlCommand {
            switch code {
            case kVK_Control: code = kVK_Command
            case kVK_RightControl: code = kVK_RightCommand
            case kVK_Command: code = kVK_Control
            case kVK_RightCommand: code = kVK_RightControl
            default: break
            }
        }
        return .key(CGKeyCode(code))
    }

    /// The modifier flag a key contributes while held (nil for ordinary keys and Caps Lock).
    static func modifierFlag(for key: CGKeyCode) -> CGEventFlags? {
        switch Int(key) {
        case kVK_Shift, kVK_RightShift: .maskShift
        case kVK_Control, kVK_RightControl: .maskControl
        case kVK_Option, kVK_RightOption: .maskAlternate
        case kVK_Command, kVK_RightCommand: .maskCommand
        case kVK_Function: .maskSecondaryFn
        default: nil
        }
    }
}
