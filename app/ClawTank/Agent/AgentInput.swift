// Agent input actions and their JSON form. Coordinates are display-local points (origin at the
// display's top-left), the same space as a default `/v1/screenshot` of that display.

import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum MouseButton: String, Sendable { case left, right, middle }

enum AgentAction: Equatable, Sendable {
    case move(display: UInt32?, x: Double, y: Double)
    case click(display: UInt32?, x: Double, y: Double, button: MouseButton, count: Int)
    case drag(display: UInt32?, fromX: Double, fromY: Double, toX: Double, toY: Double)
    /// `dy` > 0 scrolls the content down (like scrolling down a page), in lines.
    case scroll(display: UInt32?, x: Double?, y: Double?, dx: Int, dy: Int)
    case key(KeyCombo)
    case type(String)

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case invalid(String)
        var description: String { if case .invalid(let message) = self { message } else { "" } }
    }

    static let maxTextLength = 10_000

    /// Parses `{"actions": [ … ]}` or a single action object.
    static func parseList(_ data: Data) throws -> [AgentAction] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalid("body must be a JSON object")
        }
        let items = root["actions"].map { $0 as? [[String: Any]] } ?? [root]
        guard let items, !items.isEmpty, items.count <= 50 else {
            throw ParseError.invalid("\"actions\" must be a list of 1–50 objects")
        }
        return try items.map(parse)
    }

    static func parse(_ object: [String: Any]) throws -> AgentAction {
        func number(_ key: String) throws -> Double {
            guard let value = (object[key] as? NSNumber)?.doubleValue, value.isFinite, abs(value) < 100_000 else {
                throw ParseError.invalid("\"\(key)\" must be a number")
            }
            return value
        }
        let display = (object["display"] as? NSNumber)?.uint32Value
        switch object["type"] as? String {
        case "move":
            return .move(display: display, x: try number("x"), y: try number("y"))
        case "click":
            return try parseClick(object, display: display, x: try number("x"), y: try number("y"))
        case "drag":
            return .drag(display: display, fromX: try number("from_x"), fromY: try number("from_y"),
                         toX: try number("to_x"), toY: try number("to_y"))
        case "scroll":
            let dx = (object["dx"] as? NSNumber)?.intValue ?? 0
            let dy = (object["dy"] as? NSNumber)?.intValue ?? 0
            guard abs(dx) <= 100, abs(dy) <= 100 else { throw ParseError.invalid("scroll at most 100 lines") }
            let x = object["x"] == nil ? nil : try number("x")
            let y = object["y"] == nil ? nil : try number("y")
            return .scroll(display: display, x: x, y: y, dx: dx, dy: dy)
        case "key":
            guard let text = object["key"] as? String, let combo = KeyCombo(text) else {
                throw ParseError.invalid("\"key\" must be a key like \"return\" or \"cmd+shift+t\"")
            }
            return .key(combo)
        case "type":
            guard let text = object["text"] as? String, text.count <= maxTextLength else {
                throw ParseError.invalid("\"text\" must be a string of at most \(maxTextLength) characters")
            }
            return .type(text)
        case let other:
            throw ParseError.invalid("unknown action type \(other ?? "(missing)")")
        }
    }

    private static func parseClick(_ object: [String: Any], display: UInt32?, x: Double, y: Double) throws
        -> AgentAction {
        let name = object["button"] as? String ?? "left"
        guard let button = MouseButton(rawValue: name) else { throw ParseError.invalid("unknown button \(name)") }
        let count = (object["count"] as? NSNumber)?.intValue ?? 1
        guard (1...3).contains(count) else { throw ParseError.invalid("\"count\" must be 1–3") }
        return .click(display: display, x: x, y: y, button: button, count: count)
    }

    /// One line for the audit log (typed text is summarized, not recorded).
    var auditDescription: String {
        let onDisplay = { (display: UInt32?) in display.map { " on display \($0)" } ?? "" }
        return switch self {
        case .move(let display, let x, let y): "move to \(Int(x)),\(Int(y))" + onDisplay(display)
        case .click(let display, let x, let y, let button, let count):
            "\(count > 1 ? "\(count)× " : "")\(button.rawValue) click at \(Int(x)),\(Int(y))" + onDisplay(display)
        case .drag(let display, let fromX, let fromY, let toX, let toY):
            "drag \(Int(fromX)),\(Int(fromY)) → \(Int(toX)),\(Int(toY))" + onDisplay(display)
        case .scroll(let display, _, _, let dx, let dy): "scroll dx \(dx) dy \(dy)" + onDisplay(display)
        case .key(let combo): "key \(combo.text)"
        case .type(let text): "type \(text.count) characters"
        }
    }
}

/// A key with modifiers, e.g. "cmd+space", "shift+tab", "f5", "a".
struct KeyCombo: Equatable, Sendable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let text: String

    init?(_ text: String) {
        var body = text.lowercased().trimmingCharacters(in: .whitespaces)
        // "cmd++" means Command and the plus/equals key.
        let plusKey = body.hasSuffix("++")
        if plusKey { body = String(body.dropLast(2)) }
        var parts = body.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = plusKey ? "=" : parts.popLast(), let code = Self.keys[keyName] else { return nil }
        var flags: CGEventFlags = []
        for modifier in parts {
            guard let flag = Self.modifiers[modifier] else { return nil }
            flags.insert(flag)
        }
        keyCode = code
        self.flags = flags
        self.text = text.lowercased()
    }

    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "⌘": .maskCommand, "super": .maskCommand,
        "shift": .maskShift, "⇧": .maskShift,
        "ctrl": .maskControl, "control": .maskControl, "⌃": .maskControl,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate, "⌥": .maskAlternate,
        "fn": .maskSecondaryFn
    ]

    static let keys: [String: CGKeyCode] = {
        var map: [String: Int] = [
            "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
            "escape": kVK_Escape, "esc": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete,
            "forwarddelete": kVK_ForwardDelete, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave
        ]
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
                       kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
                       kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
                       kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
        for (offset, code) in letters.enumerated() { map[String(UnicodeScalar(UInt8(97 + offset)))] = code }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
                      kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (digit, code) in digits.enumerated() { map["\(digit)"] = code }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() { map["f\(index + 1)"] = code }
        return map.mapValues { CGKeyCode($0) }
    }()
}
