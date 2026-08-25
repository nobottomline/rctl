import Foundation

public struct HIDKeyStroke: Equatable, Sendable {
    public let usage: Int
    public let requiresShift: Bool

    public init(usage: Int, requiresShift: Bool = false) {
        self.usage = usage
        self.requiresShift = requiresShift
    }
}

public enum HIDKeyboardMappingError: Error, Equatable, Sendable {
    case tooLong(maximumCharacters: Int)
    case unsupportedCharacter(Character)
}

public enum HIDKeyboard {
    public static let page = 0x07
    public static let leftShift = 0xe1
    public static let maximumTextCharacters = 256

    public static func strokes(
        for text: String,
        maximumCharacters: Int = HIDKeyboard.maximumTextCharacters
    ) throws -> [HIDKeyStroke] {
        guard text.count <= maximumCharacters else {
            throw HIDKeyboardMappingError.tooLong(maximumCharacters: maximumCharacters)
        }
        return try text.map { character in
            guard let stroke = stroke(for: character) else {
                throw HIDKeyboardMappingError.unsupportedCharacter(character)
            }
            return stroke
        }
    }

    public static func stroke(for character: Character) -> HIDKeyStroke? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.value <= 0x7f else {
            return nil
        }
        let value = UInt8(scalar.value)
        switch value {
        case 0x61...0x7a:
            return HIDKeyStroke(usage: 0x04 + Int(value - 0x61))
        case 0x41...0x5a:
            return HIDKeyStroke(usage: 0x04 + Int(value - 0x41), requiresShift: true)
        case 0x31...0x39:
            return HIDKeyStroke(usage: 0x1e + Int(value - 0x31))
        case 0x30:
            return HIDKeyStroke(usage: 0x27)
        default:
            return punctuation[value]
        }
    }

    private static let punctuation: [UInt8: HIDKeyStroke] = [
        0x20: HIDKeyStroke(usage: 0x2c),
        0x0a: HIDKeyStroke(usage: 0x28),
        0x0d: HIDKeyStroke(usage: 0x28),
        0x09: HIDKeyStroke(usage: 0x2b),
        0x2d: HIDKeyStroke(usage: 0x2d),
        0x5f: HIDKeyStroke(usage: 0x2d, requiresShift: true),
        0x3d: HIDKeyStroke(usage: 0x2e),
        0x2b: HIDKeyStroke(usage: 0x2e, requiresShift: true),
        0x5b: HIDKeyStroke(usage: 0x2f),
        0x7b: HIDKeyStroke(usage: 0x2f, requiresShift: true),
        0x5d: HIDKeyStroke(usage: 0x30),
        0x7d: HIDKeyStroke(usage: 0x30, requiresShift: true),
        0x5c: HIDKeyStroke(usage: 0x31),
        0x7c: HIDKeyStroke(usage: 0x31, requiresShift: true),
        0x3b: HIDKeyStroke(usage: 0x33),
        0x3a: HIDKeyStroke(usage: 0x33, requiresShift: true),
        0x27: HIDKeyStroke(usage: 0x34),
        0x22: HIDKeyStroke(usage: 0x34, requiresShift: true),
        0x60: HIDKeyStroke(usage: 0x35),
        0x7e: HIDKeyStroke(usage: 0x35, requiresShift: true),
        0x2c: HIDKeyStroke(usage: 0x36),
        0x3c: HIDKeyStroke(usage: 0x36, requiresShift: true),
        0x2e: HIDKeyStroke(usage: 0x37),
        0x3e: HIDKeyStroke(usage: 0x37, requiresShift: true),
        0x2f: HIDKeyStroke(usage: 0x38),
        0x3f: HIDKeyStroke(usage: 0x38, requiresShift: true),
        0x21: HIDKeyStroke(usage: 0x1e, requiresShift: true),
        0x40: HIDKeyStroke(usage: 0x1f, requiresShift: true),
        0x23: HIDKeyStroke(usage: 0x20, requiresShift: true),
        0x24: HIDKeyStroke(usage: 0x21, requiresShift: true),
        0x25: HIDKeyStroke(usage: 0x22, requiresShift: true),
        0x5e: HIDKeyStroke(usage: 0x23, requiresShift: true),
        0x26: HIDKeyStroke(usage: 0x24, requiresShift: true),
        0x2a: HIDKeyStroke(usage: 0x25, requiresShift: true),
        0x28: HIDKeyStroke(usage: 0x26, requiresShift: true),
        0x29: HIDKeyStroke(usage: 0x27, requiresShift: true),
    ]
}
