import Foundation

public enum ControlMessage: ValidatedWireMessage, Encodable {
    case touch(phase: Int, finger: Int, x: Double, y: Double)
    case key(page: Int, usage: Int, down: Bool)
    case keyTap(page: Int, usage: Int)

    public static let maximumJSONBytes = WireLimits.controlJSONBytes

    private enum CodingKeys: String, CodingKey {
        case type = "t"
        case phase = "p"
        case finger = "i"
        case x
        case y
        case page = "pg"
        case usage = "u"
        case down = "d"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "t":
            self = .touch(
                phase: try values.decode(Int.self, forKey: .phase),
                finger: try values.decode(Int.self, forKey: .finger),
                x: try values.decode(Double.self, forKey: .x),
                y: try values.decode(Double.self, forKey: .y)
            )
        case "k":
            let down = try values.decode(Int.self, forKey: .down)
            guard (0...2).contains(down) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .down,
                    in: values,
                    debugDescription: "key down must be 0, 1, or 2"
                )
            }
            let page = try values.decode(Int.self, forKey: .page)
            let usage = try values.decode(Int.self, forKey: .usage)
            self = down == 2
                ? .keyTap(page: page, usage: usage)
                : .key(page: page, usage: usage, down: down == 1)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: values,
                debugDescription: "unknown control message type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch try validated() {
        case let .touch(phase, finger, x, y):
            try values.encode("t", forKey: .type)
            try values.encode(phase, forKey: .phase)
            try values.encode(finger, forKey: .finger)
            try values.encode(x, forKey: .x)
            try values.encode(y, forKey: .y)
        case let .key(page, usage, down):
            try values.encode("k", forKey: .type)
            try values.encode(page, forKey: .page)
            try values.encode(usage, forKey: .usage)
            try values.encode(down ? 1 : 0, forKey: .down)
        case let .keyTap(page, usage):
            try values.encode("k", forKey: .type)
            try values.encode(page, forKey: .page)
            try values.encode(usage, forKey: .usage)
            try values.encode(2, forKey: .down)
        }
    }

    public func validated() throws -> Self {
        switch self {
        case let .touch(phase, finger, x, y):
            guard (0...2).contains(phase) else {
                throw WireValidationError.invalidField("touch.phase")
            }
            guard (0...10).contains(finger) else {
                throw WireValidationError.invalidField("touch.finger")
            }
            guard x.isFinite, (0...1).contains(x), y.isFinite, (0...1).contains(y) else {
                throw WireValidationError.invalidField("touch.coordinates")
            }
        case let .key(page, usage, _), let .keyTap(page, usage):
            guard (0...65_535).contains(page) else {
                throw WireValidationError.invalidField("key.page")
            }
            guard (0...65_535).contains(usage) else {
                throw WireValidationError.invalidField("key.usage")
            }
        }
        return self
    }
}
