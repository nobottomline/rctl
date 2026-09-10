import dnssd
import Foundation
import Network

public enum LocalBrowserState: Equatable, Sendable {
    case stopped, searching, permissionDenied, unavailable
}

public struct DiscoveredLocalDevice: Identifiable, Equatable, Sendable {
    public let id: LocalServiceIdentity
    public let interfaces: [UInt32]
    public var endpoint: ResolvedLocalDevice?
    public var error: LocalDiscoveryError?
}

/// Foreground-only discovery. The owner controls permission opt-in and lifecycle.
@MainActor
public final class LocalDeviceBrowser {
    public private(set) var state: LocalBrowserState = .stopped
    public private(set) var devices: [DiscoveredLocalDevice] = []
    public private(set) var searchSettled = false
    public var onChange: (@MainActor () -> Void)?
    private let resolver = LocalDeviceResolver()
    private var browser: NWBrowser?
    private var generation: UInt64 = 0
    private var sources: [LocalServiceIdentity: NWBrowser.Result] = [:]
    private var tasks: [LocalServiceIdentity: Task<Void, Never>] = [:]
    private var debounce: Task<Void, Never>?
    private var emptyDeadline: Task<Void, Never>?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        generation &+= 1
        let attempt = generation
        state = .searching
        searchSettled = false
        emptyDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self, generation == attempt else { return }
            searchSettled = true
            onChange?()
        }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_rctl._tcp", domain: "local."), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == attempt else { return }
                switch state {
                case .ready: self.state = .searching
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied {
                        self.stop(); self.state = .permissionDenied
                    } else {
                        self.stop(); self.state = .unavailable
                    }
                default: break
                }
                self.onChange?()
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == attempt else { return }
                // Do not copy or sort an attacker-controlled, unbounded result set.
                let bounded = Array(results.prefix(64))
                self.debounce?.cancel()
                self.debounce = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let self, self.generation == attempt else { return }
                    self.update(bounded)
                }
            }
        }
        browser.start(queue: .main)
        onChange?()
    }

    public func stop() {
        generation &+= 1
        browser?.cancel(); browser = nil
        debounce?.cancel(); debounce = nil
        emptyDeadline?.cancel(); emptyDeadline = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        resolver.cancelAll()
        sources.removeAll(); devices.removeAll()
        state = .stopped
        searchSettled = false
        onChange?()
    }

    private func update(_ results: [NWBrowser.Result]) {
        var latest: [LocalServiceIdentity: NWBrowser.Result] = [:]
        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint,
                  let id = try? LocalServiceIdentity(name: name, type: type, domain: domain) else { continue }
            latest[id] = result
        }
        for (id, task) in tasks where latest[id] != sources[id] {
            task.cancel(); tasks[id] = nil
        }
        let previous = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        devices = latest.map { id, result in
            if sources[id] == result, let old = previous[id] { return old }
            let interfaces = Array(result.interfaces.prefix(8)).sorted {
                if ($0.type == .wifi) != ($1.type == .wifi) { return $0.type == .wifi }
                return $0.index < $1.index
            }.map { UInt32($0.index) }
            return DiscoveredLocalDevice(id: id, interfaces: interfaces, endpoint: nil, error: nil)
        }.sorted { $0.id.name < $1.id.name }
        sources = latest
        schedule()
        onChange?()
    }

    private func schedule() {
        for device in devices where device.endpoint == nil && device.error == nil && tasks[device.id] == nil {
            guard tasks.count < 4 else { break }
            let attempt = generation
            let source = sources[device.id]
            tasks[device.id] = Task { [weak self, resolver] in
                let endpoint: ResolvedLocalDevice?
                let failure: LocalDiscoveryError?
                do {
                    endpoint = try await resolver.resolve(device.id, interfaceIndices: device.interfaces)
                    failure = nil
                } catch is CancellationError { return }
                catch let value as LocalDiscoveryError { endpoint = nil; failure = value }
                catch { endpoint = nil; failure = .unavailable }
                guard let self, !Task.isCancelled, generation == attempt, sources[device.id] == source,
                      let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
                tasks[device.id] = nil
                devices[index].endpoint = endpoint
                devices[index].error = failure
                schedule()
                onChange?()
            }
        }
    }
}
