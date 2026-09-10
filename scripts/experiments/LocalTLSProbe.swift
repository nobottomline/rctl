// Transport experiment only. Not linked into the controller or device package.
import Foundation
import Security

final class PinnedProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
    let certificate: Data
    init(certificate: Data) { self.certificate = certificate }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, certificate as CFData),
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              (SecCertificateCopyData(leaf) as Data) == certificate,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "127.0.0.1" as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            print("Synthetic certificate trust failed: \(String(describing: trustError))")
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@main struct Probe {
    static func main() async {
        do { try await run() }
        catch { print("TLS probe failed: \(error)"); exit(1) }
    }

    static func run() async throws {
        guard CommandLine.arguments.count == 4,
              let port = Int(CommandLine.arguments[1]), (1...65535).contains(port) else { fatalError("port certificate.der other.der required") }
        let certificate = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let other = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let url = URL(string: "https://127.0.0.1:\(port)/")!
        for (pin, accepted) in [(certificate, true), (other, false), (Data(), false)] {
            let delegate = PinnedProbe(certificate: pin)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            do {
                let (body, response) = try await session.data(from: url)
                guard accepted, (response as? HTTPURLResponse)?.statusCode == 200, body.count < 16384 else {
                    throw NSError(domain: "TLSProbe", code: 1)
                }
                print("TLS 1.3 HTTPS with explicit certificate pin: PASS")
            } catch {
                if accepted { throw error }
                // Only an authentication failure proves rejection; not a timeout or refused socket.
                guard let failure = error as? URLError,
                      [.cancelled, .userCancelledAuthentication, .serverCertificateUntrusted].contains(failure.code) else { throw error }
                print("Missing or wrong pin rejected: PASS")
            }
        }
    }
}
