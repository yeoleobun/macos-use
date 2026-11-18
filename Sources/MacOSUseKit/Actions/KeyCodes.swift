import Carbon
import CoreGraphics
import Foundation

public struct KeyMapping: Sendable, Equatable {
    public let keyCode: CGKeyCode
    public let implicitShift: Bool

    public init(_ keyCode: Int, implicitShift: Bool = false) {
        self.keyCode = CGKeyCode(keyCode)
        self.implicitShift = implicitShift
    }
}

/// Maps human-readable macOS key names and modifier flags to `CGKeyCode` and `CGEventFlags`.
public enum KeyCodes {
    private static let keyMap: [String: KeyMapping] = [
        // Letters
        "a": KeyMapping(kVK_ANSI_A), "b": KeyMapping(kVK_ANSI_B), "c": KeyMapping(kVK_ANSI_C),
        "d": KeyMapping(kVK_ANSI_D), "e": KeyMapping(kVK_ANSI_E), "f": KeyMapping(kVK_ANSI_F),
        "g": KeyMapping(kVK_ANSI_G), "h": KeyMapping(kVK_ANSI_H), "i": KeyMapping(kVK_ANSI_I),
        "j": KeyMapping(kVK_ANSI_J), "k": KeyMapping(kVK_ANSI_K), "l": KeyMapping(kVK_ANSI_L),
        "m": KeyMapping(kVK_ANSI_M), "n": KeyMapping(kVK_ANSI_N), "o": KeyMapping(kVK_ANSI_O),
        "p": KeyMapping(kVK_ANSI_P), "q": KeyMapping(kVK_ANSI_Q), "r": KeyMapping(kVK_ANSI_R),
        "s": KeyMapping(kVK_ANSI_S), "t": KeyMapping(kVK_ANSI_T), "u": KeyMapping(kVK_ANSI_U),
        "v": KeyMapping(kVK_ANSI_V), "w": KeyMapping(kVK_ANSI_W), "x": KeyMapping(kVK_ANSI_X),
        "y": KeyMapping(kVK_ANSI_Y), "z": KeyMapping(kVK_ANSI_Z),

        // Digits & shifted symbols
        "0": KeyMapping(kVK_ANSI_0), "1": KeyMapping(kVK_ANSI_1), "2": KeyMapping(kVK_ANSI_2),
        "3": KeyMapping(kVK_ANSI_3), "4": KeyMapping(kVK_ANSI_4), "5": KeyMapping(kVK_ANSI_5),
        "6": KeyMapping(kVK_ANSI_6), "7": KeyMapping(kVK_ANSI_7), "8": KeyMapping(kVK_ANSI_8),
        "9": KeyMapping(kVK_ANSI_9),
        ")": KeyMapping(kVK_ANSI_0, implicitShift: true),
        "!": KeyMapping(kVK_ANSI_1, implicitShift: true),
        "@": KeyMapping(kVK_ANSI_2, implicitShift: true),
        "#": KeyMapping(kVK_ANSI_3, implicitShift: true),
        "$": KeyMapping(kVK_ANSI_4, implicitShift: true),
        "%": KeyMapping(kVK_ANSI_5, implicitShift: true),
        "^": KeyMapping(kVK_ANSI_6, implicitShift: true),
        "&": KeyMapping(kVK_ANSI_7, implicitShift: true),
        "*": KeyMapping(kVK_ANSI_8, implicitShift: true),
        "(": KeyMapping(kVK_ANSI_9, implicitShift: true),

        // Punctuation
        "-": KeyMapping(kVK_ANSI_Minus), "minus": KeyMapping(kVK_ANSI_Minus),
        "_": KeyMapping(kVK_ANSI_Minus, implicitShift: true),
        "=": KeyMapping(kVK_ANSI_Equal), "equal": KeyMapping(kVK_ANSI_Equal), "equals": KeyMapping(kVK_ANSI_Equal),
        "+": KeyMapping(kVK_ANSI_Equal, implicitShift: true), "plus": KeyMapping(kVK_ANSI_Equal, implicitShift: true),
        "[": KeyMapping(kVK_ANSI_LeftBracket), "{": KeyMapping(kVK_ANSI_LeftBracket, implicitShift: true),
        "]": KeyMapping(kVK_ANSI_RightBracket), "}": KeyMapping(kVK_ANSI_RightBracket, implicitShift: true),
        "\\": KeyMapping(kVK_ANSI_Backslash), "|": KeyMapping(kVK_ANSI_Backslash, implicitShift: true),
        ";": KeyMapping(kVK_ANSI_Semicolon), ":": KeyMapping(kVK_ANSI_Semicolon, implicitShift: true),
        "'": KeyMapping(kVK_ANSI_Quote), "\"": KeyMapping(kVK_ANSI_Quote, implicitShift: true),
        ",": KeyMapping(kVK_ANSI_Comma), "<": KeyMapping(kVK_ANSI_Comma, implicitShift: true),
        ".": KeyMapping(kVK_ANSI_Period), ">": KeyMapping(kVK_ANSI_Period, implicitShift: true),
        "/": KeyMapping(kVK_ANSI_Slash), "?": KeyMapping(kVK_ANSI_Slash, implicitShift: true),
        "`": KeyMapping(kVK_ANSI_Grave), "~": KeyMapping(kVK_ANSI_Grave, implicitShift: true),

        // Control & editing keys
        "return": KeyMapping(kVK_Return), "enter": KeyMapping(kVK_Return),
        "tab": KeyMapping(kVK_Tab),
        "space": KeyMapping(kVK_Space), " ": KeyMapping(kVK_Space),
        "delete": KeyMapping(kVK_Delete), "backspace": KeyMapping(kVK_Delete),
        "forwarddelete": KeyMapping(kVK_ForwardDelete), "forward_delete": KeyMapping(kVK_ForwardDelete),
        "escape": KeyMapping(kVK_Escape), "esc": KeyMapping(kVK_Escape),
        "capslock": KeyMapping(kVK_CapsLock), "caps_lock": KeyMapping(kVK_CapsLock),
        "help": KeyMapping(kVK_Help),

        // Navigation keys
        "up": KeyMapping(kVK_UpArrow), "arrowup": KeyMapping(kVK_UpArrow), "arrow_up": KeyMapping(kVK_UpArrow),
        "down": KeyMapping(kVK_DownArrow), "arrowdown": KeyMapping(kVK_DownArrow), "arrow_down": KeyMapping(kVK_DownArrow),
        "left": KeyMapping(kVK_LeftArrow), "arrowleft": KeyMapping(kVK_LeftArrow), "arrow_left": KeyMapping(kVK_LeftArrow),
        "right": KeyMapping(kVK_RightArrow), "arrowright": KeyMapping(kVK_RightArrow), "arrow_right": KeyMapping(kVK_RightArrow),
        "home": KeyMapping(kVK_Home),
        "end": KeyMapping(kVK_End),
        "pageup": KeyMapping(kVK_PageUp), "page_up": KeyMapping(kVK_PageUp),
        "pagedown": KeyMapping(kVK_PageDown), "page_down": KeyMapping(kVK_PageDown),

        // Function keys
        "f1": KeyMapping(kVK_F1), "f2": KeyMapping(kVK_F2), "f3": KeyMapping(kVK_F3), "f4": KeyMapping(kVK_F4),
        "f5": KeyMapping(kVK_F5), "f6": KeyMapping(kVK_F6), "f7": KeyMapping(kVK_F7), "f8": KeyMapping(kVK_F8),
        "f9": KeyMapping(kVK_F9), "f10": KeyMapping(kVK_F10), "f11": KeyMapping(kVK_F11), "f12": KeyMapping(kVK_F12),
        "f13": KeyMapping(kVK_F13), "f14": KeyMapping(kVK_F14), "f15": KeyMapping(kVK_F15), "f16": KeyMapping(kVK_F16),
        "f17": KeyMapping(kVK_F17), "f18": KeyMapping(kVK_F18), "f19": KeyMapping(kVK_F19), "f20": KeyMapping(kVK_F20)
    ]

    public static func lookup(_ key: String) throws -> KeyMapping {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == " " || key == " " {
            return KeyMapping(kVK_Space)
        }
        let lower = trimmed.lowercased()
        if let mapped = keyMap[lower] {
            return mapped
        }
        if trimmed.count == 1, let mapped = keyMap[trimmed.lowercased()] {
            return mapped
        }
        throw MacOSUseError.invalidArgument("Unsupported key name '\(key)'.")
    }

    public static func modifierFlags(_ modifiers: [String]) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for raw in modifiers {
            let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if norm.isEmpty { continue }
            switch norm {
            case "command", "cmd", "super", "meta":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "option", "opt", "alt":
                flags.insert(.maskAlternate)
            case "control", "ctrl":
                flags.insert(.maskControl)
            case "fn", "function":
                flags.insert(.maskSecondaryFn)
            default:
                throw MacOSUseError.invalidArgument(
                    "Unsupported modifier '\(raw)'. Expected command/cmd, shift, option/alt, control/ctrl, or fn."
                )
            }
        }
        return flags
    }
}
