import Darwin
import Foundation

public struct LocalDeviceAddress: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int

    public init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 256, !text.contains("%"),
              !text.hasSuffix(":"), !text.hasSuffix(":/"),
              let components = URLComponents(string: text.contains("://") ? text : "http://" + text),
              components.scheme == "http", components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let rawHost = components.host else { throw LocalConnectionError.invalidAddress }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
            ? String(rawHost.dropFirst().dropLast()) : rawHost
        let port = components.port ?? 8080
        guard (1...65535).contains(port) else { throw LocalConnectionError.invalidAddress }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let family: Int32
        let bytes: [UInt8]
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            guard bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                    || (bytes[0] == 192 && bytes[1] == 168) else {
                throw LocalConnectionError.invalidAddress
            }
            family = AF_INET
        } else if inet_pton(AF_INET6, host, &ipv6) == 1 {
            bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            guard bytes[0] & 0xfe == 0xfc else { throw LocalConnectionError.invalidAddress }
            family = AF_INET6
        } else {
            throw LocalConnectionError.invalidAddress
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let converted = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &output, socklen_t(output.count)) }
        guard converted != nil else { throw LocalConnectionError.invalidAddress }
        let canonicalHost = String(cString: output)
        guard family != AF_INET || canonicalHost == host else { throw LocalConnectionError.invalidAddress }
        self.host = canonicalHost
        self.port = port
    }

    public var displayAddress: String { "\(host.contains(":") ? "[\(host)]" : host):\(port)" }

    public var capabilitiesURL: URL { URL(string: "http://\(displayAddress)/v1/capabilities")! }

    public func signalingRequest(camera: Bool = false) -> URLRequest {
        var request = URLRequest(url: URL(string: "ws://\(displayAddress)/ws/signal\(camera ? "?media=camera" : "")")!)
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        return request
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(displayAddress)
    }
}

public enum LocalConnectionError: LocalizedError, Equatable, Sendable {
    case invalidAddress
    case redirect
    case responseTooLarge
    case invalidResponse
    case http(Int)
    case incompatibleProtocol
    case unsupportedMedia

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "Enter a private IPv4 address or a bracketed IPv6 ULA address, with an optional port. Hostnames and link-local IPv6 are not supported yet."
        case .redirect: "The local device redirected the connection. Check its address."
        case .responseTooLarge: "The local device returned an oversized response."
        case .invalidResponse: "This address did not return valid rctl device capabilities."
        case .http(let status): "The local device returned HTTP \(status)."
        case .incompatibleProtocol: "Update the controller or rctl device: their protocol versions are incompatible."
        case .unsupportedMedia: "This rctl device does not support the selected video source."
        }
    }
}
