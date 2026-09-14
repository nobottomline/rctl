import Foundation
import os

/// Unified logging that also works before `Logger` (iOS 14 / macOS 11).
/// Literal text and values interpolated with `privacy: .public` are public;
/// every other value is private. Both backends need a static format, so any
/// text that follows the first private value is logged privately as well.
struct RealtimeLog: Sendable {
    enum Privacy: Sendable {
        case `public`, `private`
    }

    private let log: OSLog

    init(category: String) {
        log = OSLog(subsystem: "com.greatlove.rctl.controller", category: category)
    }

    func debug(_ message: Message) { write(message, type: .debug) }
    func info(_ message: Message) { write(message, type: .info) }
    func error(_ message: Message) { write(message, type: .error) }

    private func write(_ message: Message, type: OSLogType) {
        if #available(iOS 14, macOS 11, *) {
            let logger = Logger(log)
            if let hidden = message.privateText {
                logger.log(level: type, "\(message.publicText, privacy: .public)\(hidden, privacy: .private)")
            } else {
                logger.log(level: type, "\(message.publicText, privacy: .public)")
            }
        } else if let hidden = message.privateText {
            os_log("%{public}@%{private}@", log: log, type: type, message.publicText as NSString, hidden as NSString)
        } else {
            os_log("%{public}@", log: log, type: type, message.publicText as NSString)
        }
    }

    struct Message: ExpressibleByStringInterpolation {
        let publicText: String
        /// Everything from the first private value onward; `nil` when fully public.
        let privateText: String?

        init(stringLiteral value: String) {
            publicText = value
            privateText = nil
        }

        init(stringInterpolation: Interpolation) {
            publicText = stringInterpolation.publicText
            privateText = stringInterpolation.privateText
        }

        struct Interpolation: StringInterpolationProtocol {
            fileprivate var publicText = ""
            fileprivate var privateText: String?

            init(literalCapacity: Int, interpolationCount: Int) {
                publicText.reserveCapacity(literalCapacity)
            }

            mutating func appendLiteral(_ literal: String) {
                append(literal, privacy: .public)
            }

            mutating func appendInterpolation<Value>(_ value: Value, privacy: Privacy = .private) {
                append(String(describing: value), privacy: privacy)
            }

            private mutating func append(_ text: String, privacy: Privacy) {
                if privacy == .public, privateText == nil {
                    publicText += text
                } else {
                    privateText = (privateText ?? "") + text
                }
            }
        }
    }
}
