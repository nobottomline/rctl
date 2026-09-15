import RctlClient
import RctlRealtime
import XCTest
@testable import RctlUIKit

final class DevicesViewStateTests: XCTestCase {
    // MARK: - Fixtures

    private let living = LocalDeviceProfile(id: UUID(), name: "Living room", address: DevicesViewStateTests.address("192.168.1.20:8080"))
    private let studio = LocalDeviceProfile(id: UUID(), name: "Studio", address: DevicesViewStateTests.address("192.168.1.42:9000"))

    private static func address(_ value: String) -> LocalDeviceAddress {
        do { return try LocalDeviceAddress(value) } catch { fatalError("invalid fixture address \(value)") }
    }

    private static func service(_ name: String) -> LocalServiceIdentity {
        do { return try LocalServiceIdentity(name: name, type: "_rctl._tcp", domain: "local.") } catch { fatalError("invalid fixture service") }
    }

    private static func profile(relayID: String = "relay-a", origin: String = "https://relay.example.net", scopes: [ControllerScope] = [.screenView, .camera]) -> ControllerProfile {
        ControllerProfile(origin: origin, relayID: relayID,
                          controller: PairedController(id: "ctl_test", name: "Test iPhone", platform: "ios", scopes: scopes))
    }

    private func relay(_ devices: [DevicesSnapshot.RelayDevice] = [], saved: [ControllerProfile]? = nil) -> DevicesSnapshot.Relay {
        let selected = Self.profile()
        return DevicesSnapshot.Relay(selected: selected, saved: saved ?? [selected], devices: devices)
    }

    private func nearbyRow(_ state: DevicesViewState, _ name: String) -> DevicesRowState? {
        state.nearby.rows.first { $0.kind == .nearby(Self.service(name)) }
    }

    // MARK: - Layout and summary

    func testFirstRunWithoutLocalDevicesOrRelay() {
        let state = DevicesViewState(DevicesSnapshot())
        XCTAssertEqual(state.layout, .firstRun)
        XCTAssertEqual(state.summary.text, "No devices yet.")
        XCTAssertFalse(state.summary.showsOnlineIndicator)
        XCTAssertFalse(state.showsRefresh)
        XCTAssertEqual(state.relay, .unpaired)
        XCTAssertNil(state.local.subtitle)
    }

    func testPopulatedWhenLocalDevicesOrRelayExist() {
        var local = DevicesSnapshot()
        local.localDevices = [living]
        XCTAssertEqual(DevicesViewState(local).layout, .populated)
        XCTAssertEqual(DevicesViewState(local).relay, .unpaired)
        XCTAssertFalse(DevicesViewState(local).showsRefresh)

        var paired = DevicesSnapshot()
        paired.relay = relay()
        let state = DevicesViewState(paired)
        XCTAssertEqual(state.layout, .populated)
        XCTAssertTrue(state.showsRefresh)
        XCTAssertTrue(state.local.rows.isEmpty, "The local section still offers Add local device without saved rows")
    }

    func testSummaryCountsRelayOnlineReachableAndAdvertisedLocalDevices() {
        var snapshot = DevicesSnapshot()
        let third = LocalDeviceProfile(id: UUID(), name: "Kitchen", address: Self.address("10.0.0.7:8080"))
        snapshot.localDevices = [living, studio, third]
        snapshot.reachability = [living.id: .reachable(daemonVersion: nil), studio.id: .unreachable]
        snapshot.discoveryEnabled = true
        snapshot.nearby = [.init(id: Self.service("Kitchen"), endpointAddress: third.address)]
        snapshot.relay = relay([
            .init(id: "a", name: "A", online: true),
            .init(id: "b", name: "B", online: false),
        ])
        let summary = DevicesViewState(snapshot).summary
        XCTAssertEqual(summary.text, "3 online · 5 devices")
        XCTAssertEqual(summary.online, 3)
        XCTAssertTrue(summary.showsOnlineIndicator)
    }

    func testSummarySingularAndNoIndicatorWhenNothingOnline() {
        var snapshot = DevicesSnapshot()
        snapshot.localDevices = [living]
        let summary = DevicesViewState(snapshot).summary
        XCTAssertEqual(summary.text, "0 online · 1 device")
        XCTAssertFalse(summary.showsOnlineIndicator)
    }

    // MARK: - Local network

    func testLocalStatusForEveryReachabilityState() {
        var snapshot = DevicesSnapshot()
        snapshot.localDevices = [living]
        let cases: [(LocalDeviceReachability?, DevicesStatus)] = [
            (nil, DevicesStatus(text: "Saved", tone: .neutral)),
            (.unknown, DevicesStatus(text: "Saved", tone: .neutral)),
            (.checking, DevicesStatus(text: "Checking", tone: .neutral, busy: true)),
            (.reachable(daemonVersion: "0.3.0"), DevicesStatus(text: "Online", tone: .success)),
            (.unreachable, DevicesStatus(text: "Offline", tone: .attention)),
        ]
        for (reachability, expected) in cases {
            snapshot.reachability = reachability.map { [living.id: $0] } ?? [:]
            let row = DevicesViewState(snapshot).local.rows[0]
            XCTAssertEqual(row.status, expected, "\(String(describing: reachability))")
            XCTAssertTrue(row.isEnabled)
            XCTAssertEqual(row.accessibilityHint, "Opens remote control")
        }
    }

    func testLocalDetailShowsVersionOnlyWhenReachableWithVersion() {
        var snapshot = DevicesSnapshot()
        snapshot.localDevices = [living]
        snapshot.reachability = [living.id: .reachable(daemonVersion: "0.3.0-180")]
        XCTAssertEqual(DevicesViewState(snapshot).local.rows[0].detail, "192.168.1.20:8080 · rctld 0.3.0-180")
        snapshot.reachability = [living.id: .reachable(daemonVersion: nil)]
        XCTAssertEqual(DevicesViewState(snapshot).local.rows[0].detail, "192.168.1.20:8080")
        snapshot.reachability = [living.id: .unreachable]
        XCTAssertEqual(DevicesViewState(snapshot).local.rows[0].detail, "192.168.1.20:8080")
        XCTAssertTrue(DevicesViewState(snapshot).local.rows[0].detailIsMonospaced)
    }

    func testAdvertisedHintRequiresDiscoveryAndExactEndpoint() {
        var snapshot = DevicesSnapshot()
        snapshot.localDevices = [living]
        snapshot.reachability = [living.id: .unreachable]
        snapshot.nearby = [.init(id: Self.service("Living"), endpointAddress: living.address)]
        XCTAssertFalse(DevicesViewState.isAdvertisedNearby(living, in: snapshot), "Discovery off: never advertised")
        XCTAssertEqual(DevicesViewState(snapshot).local.rows[0].status.text, "Offline")

        snapshot.discoveryEnabled = true
        let row = DevicesViewState(snapshot).local.rows[0]
        XCTAssertEqual(row.status, DevicesStatus(text: "Discovered", tone: .neutral))
        XCTAssertEqual(row.detail, "192.168.1.20:8080 · advertised")

        snapshot.nearby = [.init(id: Self.service("Living"), endpointAddress: Self.address("192.168.1.20:8081"))]
        XCTAssertEqual(DevicesViewState(snapshot).local.rows[0].status.text, "Offline", "A different port is a different endpoint")
    }

    func testReachableVersionWinsOverAdvertisedDetail() {
        var snapshot = DevicesSnapshot()
        snapshot.localDevices = [living]
        snapshot.reachability = [living.id: .reachable(daemonVersion: "1.0")]
        snapshot.discoveryEnabled = true
        snapshot.nearby = [.init(id: Self.service("Living"), endpointAddress: living.address)]
        let row = DevicesViewState(snapshot).local.rows[0]
        XCTAssertEqual(row.status.text, "Discovered")
        XCTAssertEqual(row.detail, "192.168.1.20:8080 · rctld 1.0")
    }

    func testLocalSubtitleAndRowIdentity() {
        var snapshot = DevicesSnapshot()
        snapshot.localDevices = [living, studio]
        let local = DevicesViewState(snapshot).local
        XCTAssertEqual(local.subtitle, "2 saved")
        XCTAssertEqual(local.rows.map(\.id), ["local:\(living.id.uuidString)", "local:\(studio.id.uuidString)"])
        XCTAssertEqual(local.rows.map(\.title), ["Living room", "Studio"])
    }

    // MARK: - Nearby header

    func testNearbyDisabledHasNoSubtitleRowsOrAccessories() {
        var snapshot = DevicesSnapshot()
        snapshot.discoveryState = .searching
        snapshot.nearby = [.init(id: Self.service("A"))]
        let nearby = DevicesViewState(snapshot).nearby
        XCTAssertFalse(nearby.isEnabled)
        XCTAssertNil(nearby.subtitle)
        XCTAssertTrue(nearby.rows.isEmpty)
        XCTAssertNil(nearby.notice)
        XCTAssertFalse(nearby.showsSpinner)
    }

    func testNearbySubtitleStates() {
        var snapshot = DevicesSnapshot()
        snapshot.discoveryEnabled = true

        snapshot.discoveryState = .permissionDenied
        XCTAssertEqual(DevicesViewState.nearbySubtitle(snapshot), "Permission needed")
        snapshot.discoveryState = .unavailable
        XCTAssertEqual(DevicesViewState.nearbySubtitle(snapshot), "Unavailable")

        for state in [LocalBrowserState.searching, .stopped] {
            snapshot.discoveryState = state
            snapshot.nearby = []
            snapshot.discoverySearchSettled = false
            XCTAssertEqual(DevicesViewState.nearbySubtitle(snapshot), "Searching")
            snapshot.discoverySearchSettled = true
            XCTAssertEqual(DevicesViewState.nearbySubtitle(snapshot), "None found")
            snapshot.nearby = [.init(id: Self.service("Gone"), isPresent: false)]
            XCTAssertEqual(DevicesViewState.nearbySubtitle(snapshot), "Recently seen")
            snapshot.nearby.append(.init(id: Self.service("Here")))
            XCTAssertEqual(DevicesViewState.nearbySubtitle(snapshot), "1 found")
            snapshot.nearby.append(.init(id: Self.service("There")))
            XCTAssertEqual(DevicesViewState.nearbySubtitle(snapshot), "2 found")
        }
    }

    func testNearbyAccessoryAvailability() {
        var snapshot = DevicesSnapshot()
        snapshot.discoveryEnabled = true
        snapshot.discoveryState = .searching
        var nearby = DevicesViewState(snapshot).nearby
        XCTAssertTrue(nearby.showsSpinner)
        XCTAssertTrue(nearby.canSearchAgain)

        snapshot.discoverySearchSettled = true
        XCTAssertFalse(DevicesViewState(snapshot).nearby.showsSpinner, "The spinner stops once the search window settles")
        XCTAssertTrue(DevicesViewState(snapshot).nearby.canSearchAgain)
        snapshot.discoverySearchSettled = false

        snapshot.selectingNearby = true
        nearby = DevicesViewState(snapshot).nearby
        XCTAssertFalse(nearby.showsSpinner, "No spinner while a selection is being prepared")
        XCTAssertFalse(nearby.canSearchAgain)

        snapshot.selectingNearby = false
        snapshot.discoveryState = .permissionDenied
        nearby = DevicesViewState(snapshot).nearby
        XCTAssertFalse(nearby.showsSpinner)
        XCTAssertFalse(nearby.canSearchAgain)

        snapshot.discoveryState = .unavailable
        XCTAssertTrue(DevicesViewState(snapshot).nearby.canSearchAgain)
    }

    func testNearbyNoticeStates() {
        var snapshot = DevicesSnapshot()
        snapshot.discoveryEnabled = true
        snapshot.discoveryState = .permissionDenied
        XCTAssertEqual(DevicesViewState(snapshot).nearby.notice, .permissionDenied)
        snapshot.discoveryState = .unavailable
        XCTAssertEqual(DevicesViewState(snapshot).nearby.notice, .unavailable)
        snapshot.discoveryState = .searching
        XCTAssertEqual(DevicesViewState(snapshot).nearby.notice, .searching)
        snapshot.discoverySearchSettled = true
        XCTAssertEqual(DevicesViewState(snapshot).nearby.notice, .empty)
        snapshot.nearby = [.init(id: Self.service("A"))]
        XCTAssertNil(DevicesViewState(snapshot).nearby.notice, "Rows replace the empty and searching states")
        snapshot.discoveryState = .unavailable
        XCTAssertEqual(DevicesViewState(snapshot).nearby.notice, .unavailable, "Notices stay after existing rows")
    }

    // MARK: - Nearby rows

    func testNearbyStatusAndDetailMapping() {
        var snapshot = DevicesSnapshot()
        snapshot.discoveryEnabled = true
        snapshot.discoveryState = .searching
        snapshot.localDevices = [studio]
        snapshot.nearby = [
            .init(id: Self.service("Gone"), endpointAddress: Self.address("192.168.1.9:8080"), isPresent: false),
            .init(id: Self.service("Old"), error: .unsupportedVersion),
            .init(id: Self.service("Guest"), error: .unsupportedNetwork),
            .init(id: Self.service("Broken"), error: .malformedRecord),
            .init(id: Self.service("Slow"), error: .timedOut),
            .init(id: Self.service("Busy"), error: .busy),
            .init(id: Self.service("Lost"), error: .unavailable),
            .init(id: Self.service("Pending")),
            .init(id: Self.service("Studio"), endpointAddress: studio.address),
            .init(id: Self.service("Studio 2"), endpointAddress: studio.address),
            .init(id: Self.service("Fresh"), endpointAddress: Self.address("192.168.1.77:8080")),
        ]
        let state = DevicesViewState(snapshot)
        let expected: [(String, DevicesStatus, String)] = [
            ("Gone", DevicesStatus(text: "Unavailable", tone: .attention), "No longer advertised on this network"),
            ("Old", DevicesStatus(text: "Incompatible", tone: .danger), "Protocol mismatch"),
            ("Guest", DevicesStatus(text: "Unsupported", tone: .attention), "No private IPv4"),
            ("Broken", DevicesStatus(text: "Unavailable", tone: .attention), "Invalid record"),
            ("Slow", DevicesStatus(text: "Unavailable", tone: .attention), "No answer"),
            ("Busy", DevicesStatus(text: "Unavailable", tone: .attention), "Not resolved"),
            ("Lost", DevicesStatus(text: "Unavailable", tone: .attention), "Not resolved"),
            ("Pending", DevicesStatus(text: "Resolving", tone: .neutral, busy: true), "Resolving address…"),
            ("Studio", DevicesStatus(text: "Saved", tone: .neutral), "192.168.1.42:9000"),
            ("Studio 2", DevicesStatus(text: "Saved", tone: .neutral), "192.168.1.42:9000 · saved as Studio"),
            ("Fresh", DevicesStatus(text: "Discovered", tone: .neutral), "192.168.1.77:8080"),
        ]
        XCTAssertEqual(state.nearby.rows.count, expected.count)
        for (name, status, detail) in expected {
            let row = nearbyRow(state, name)
            XCTAssertEqual(row?.status, status, name)
            XCTAssertEqual(row?.detail, detail, name)
        }
        XCTAssertEqual(nearbyRow(state, "Fresh")?.detailIsMonospaced, true)
        XCTAssertEqual(nearbyRow(state, "Pending")?.detailIsMonospaced, false)
        XCTAssertEqual(nearbyRow(state, "Gone")?.detailIsMonospaced, false)
    }

    func testNearbyRowEnabledRequiresResolvableAndNoSelection() {
        var snapshot = DevicesSnapshot()
        snapshot.discoveryEnabled = true
        snapshot.nearby = [
            .init(id: Self.service("Ok")),
            .init(id: Self.service("Timed"), error: .timedOut),
            .init(id: Self.service("Old"), error: .unsupportedVersion),
            .init(id: Self.service("Guest"), error: .unsupportedNetwork),
            .init(id: Self.service("Broken"), error: .malformedRecord),
        ]
        var state = DevicesViewState(snapshot)
        XCTAssertEqual(nearbyRow(state, "Ok")?.isEnabled, true)
        XCTAssertEqual(nearbyRow(state, "Timed")?.isEnabled, true)
        XCTAssertEqual(nearbyRow(state, "Old")?.isEnabled, false)
        XCTAssertEqual(nearbyRow(state, "Guest")?.isEnabled, false)
        XCTAssertEqual(nearbyRow(state, "Broken")?.isEnabled, false)
        XCTAssertEqual(nearbyRow(state, "Old")?.accessibilityHint, "Shows why this device is unavailable")

        snapshot.selectingNearby = true
        state = DevicesViewState(snapshot)
        XCTAssertTrue(state.nearby.rows.allSatisfy { !$0.isEnabled })
    }

    func testCheckingOnlyForChosenRowWhileSelecting() {
        var snapshot = DevicesSnapshot()
        snapshot.discoveryEnabled = true
        snapshot.nearby = [
            .init(id: Self.service("Chosen"), endpointAddress: Self.address("192.168.1.5:8080")),
            .init(id: Self.service("Other"), endpointAddress: Self.address("192.168.1.6:8080")),
        ]
        snapshot.checkingNearby = Self.service("Chosen")
        XCTAssertEqual(nearbyRow(DevicesViewState(snapshot), "Chosen")?.status.text, "Discovered", "Checking needs an active selection")

        snapshot.selectingNearby = true
        let state = DevicesViewState(snapshot)
        XCTAssertEqual(nearbyRow(state, "Chosen")?.status, DevicesStatus(text: "Checking", tone: .neutral, busy: true))
        XCTAssertEqual(nearbyRow(state, "Other")?.status.text, "Discovered")
    }

    func testAddressReplacementOffer() {
        var snapshot = DevicesSnapshot()
        snapshot.discoveryEnabled = true
        snapshot.nearby = [
            .init(id: Self.service("Resolved"), endpointAddress: Self.address("192.168.1.5:8080")),
            .init(id: Self.service("Pending")),
            .init(id: Self.service("Gone"), endpointAddress: Self.address("192.168.1.6:8080"), isPresent: false),
        ]
        XCTAssertEqual(nearbyRow(DevicesViewState(snapshot), "Resolved")?.offersAddressReplacement, false, "Needs saved devices")
        snapshot.localDevices = [living]
        let state = DevicesViewState(snapshot)
        XCTAssertEqual(nearbyRow(state, "Resolved")?.offersAddressReplacement, true)
        XCTAssertEqual(nearbyRow(state, "Pending")?.offersAddressReplacement, false)
        XCTAssertEqual(nearbyRow(state, "Gone")?.offersAddressReplacement, false)
    }

    func testNearbySnapshotCanResolveMirrorsDiscoveryRules() {
        XCTAssertTrue(DevicesSnapshot.NearbyDevice(id: Self.service("A")).canResolve)
        XCTAssertTrue(DevicesSnapshot.NearbyDevice(id: Self.service("A"), error: .unavailable).canResolve)
        XCTAssertTrue(DevicesSnapshot.NearbyDevice(id: Self.service("A"), error: .timedOut).canResolve)
        XCTAssertTrue(DevicesSnapshot.NearbyDevice(id: Self.service("A"), error: .busy).canResolve)
        XCTAssertFalse(DevicesSnapshot.NearbyDevice(id: Self.service("A"), error: .malformedRecord).canResolve)
        XCTAssertFalse(DevicesSnapshot.NearbyDevice(id: Self.service("A"), error: .unsupportedVersion).canResolve)
        XCTAssertFalse(DevicesSnapshot.NearbyDevice(id: Self.service("A"), error: .unsupportedNetwork).canResolve)
    }

    // MARK: - Relay

    func testRelayStatusDetailAndAvailability() {
        let devices: [DevicesSnapshot.RelayDevice] = [
            .init(id: "online", name: "Office", online: true, daemonVersion: "0.3.0", protocolMajor: 1, protocolMinor: 4),
            .init(id: "offline", name: "Travel", online: false, daemonVersion: "0.3.0"),
            .init(id: "update", name: "Shop", online: true, protocolMajor: 1, protocolMinor: 2, supportsNativeControllerSessions: false),
            .init(id: "broken", name: "Legacy", online: true, compatible: false, compatibilityError: "Protocol 0.9 is not supported"),
            .init(id: "broken-silent", name: "Mute", online: false, compatible: false),
            .init(id: "bare", name: "Bare", online: true),
        ]
        var snapshot = DevicesSnapshot()
        snapshot.relay = relay(devices)
        guard case let .paired(paired) = DevicesViewState(snapshot).relay else { return XCTFail("Expected a paired relay") }
        XCTAssertNil(paired.placeholder)
        let expected: [(DevicesStatus, String, Bool)] = [
            (DevicesStatus(text: "Online", tone: .success), "rctld 0.3.0 · protocol 1.4", true),
            (DevicesStatus(text: "Offline", tone: .neutral), "rctld 0.3.0", false),
            (DevicesStatus(text: "Needs update", tone: .attention), "protocol 1.2", false),
            (DevicesStatus(text: "Incompatible", tone: .danger), "Protocol 0.9 is not supported", false),
            (DevicesStatus(text: "Incompatible", tone: .danger), "Relay device", false),
            (DevicesStatus(text: "Online", tone: .success), "Relay device", true),
        ]
        XCTAssertEqual(paired.rows.count, expected.count)
        for (row, (status, detail, enabled)) in zip(paired.rows, expected) {
            XCTAssertEqual(row.status, status, row.title)
            XCTAssertEqual(row.detail, detail, row.title)
            XCTAssertEqual(row.isEnabled, enabled, row.title)
            XCTAssertEqual(row.accessibilityHint, enabled ? "Opens remote control" : "Shows why this device is unavailable")
            XCTAssertFalse(row.detailIsMonospaced)
        }
        XCTAssertEqual(paired.rows.map(\.id), devices.map { "relay:\($0.id)" })
    }

    func testRelayUnavailableMessages() {
        XCTAssertEqual(DevicesViewState.unavailableMessage(for: .init(id: "a", name: "A", online: true, compatible: false, compatibilityError: "Too old")), "Too old")
        XCTAssertEqual(DevicesViewState.unavailableMessage(for: .init(id: "a", name: "A", online: true, compatible: false)),
                       "The device uses an incompatible protocol version.")
        XCTAssertEqual(DevicesViewState.unavailableMessage(for: .init(id: "a", name: "Travel", online: false)),
                       "Travel is offline. Wait for it to reconnect to the relay, then refresh.")
        XCTAssertEqual(DevicesViewState.unavailableMessage(for: .init(id: "a", name: "Shop", online: true, daemonVersion: "0.2.9", supportsNativeControllerSessions: false)),
                       "Update rctld 0.2.9 on Shop before using the native controller. Browser control remains available.")
        XCTAssertEqual(DevicesViewState.unavailableMessage(for: .init(id: "a", name: "Shop", online: true, supportsNativeControllerSessions: false)),
                       "Update rctld on Shop before using the native controller. Browser control remains available.")
    }

    func testRelayPlaceholderFollowsBusyState() {
        var snapshot = DevicesSnapshot()
        snapshot.relay = relay()
        snapshot.isBusy = true
        guard case let .paired(loading) = DevicesViewState(snapshot).relay else { return XCTFail("Expected a paired relay") }
        XCTAssertEqual(loading.placeholder, .loading)
        XCTAssertTrue(loading.isBusy)
        XCTAssertTrue(DevicesViewState(snapshot).isBusy)

        snapshot.isBusy = false
        guard case let .paired(empty) = DevicesViewState(snapshot).relay else { return XCTFail("Expected a paired relay") }
        XCTAssertEqual(empty.placeholder, .empty)

        snapshot.isBusy = true
        snapshot.relay?.devices = [.init(id: "a", name: "A", online: true)]
        guard case let .paired(refreshing) = DevicesViewState(snapshot).relay else { return XCTFail("Expected a paired relay") }
        XCTAssertNil(refreshing.placeholder, "Existing rows stay while a refresh runs")
    }

    func testRelayHeaderChoicesAndFooter() {
        let selected = Self.profile(relayID: "relay-a", origin: "https://relay.example.net")
        let other = Self.profile(relayID: "relay-b", origin: "not a url")
        var snapshot = DevicesSnapshot()
        snapshot.relay = DevicesSnapshot.Relay(selected: selected, saved: [selected, other], devices: [])
        guard case let .paired(paired) = DevicesViewState(snapshot).relay else { return XCTFail("Expected a paired relay") }
        XCTAssertEqual(paired.subtitle, "relay.example.net")
        XCTAssertEqual(paired.choices, [
            .init(relayID: "relay-a", title: "relay.example.net", isSelected: true),
            .init(relayID: "relay-b", title: "not a url", isSelected: false),
        ])
        XCTAssertEqual(paired.footer, "Paired as Test iPhone · 2 permissions")

        snapshot.relay?.selected = Self.profile(scopes: [.screenView])
        guard case let .paired(single) = DevicesViewState(snapshot).relay else { return XCTFail("Expected a paired relay") }
        XCTAssertEqual(single.footer, "Paired as Test iPhone · 1 permission")
    }

    // MARK: - Demo fixtures

    #if DEBUG
    func testDemoFixturesCoverTheirStates() {
        let populated = DevicesViewState(DevicesDemoFixture.populated.snapshot)
        XCTAssertEqual(populated.layout, .populated)
        XCTAssertEqual(Set(populated.local.rows.map(\.status.text)), ["Online", "Checking", "Discovered", "Offline"])
        XCTAssertEqual(Set(populated.nearby.rows.map(\.status.text)), ["Saved", "Discovered", "Resolving", "Incompatible", "Unavailable"])
        guard case let .paired(relay) = populated.relay else { return XCTFail("Expected a paired relay") }
        XCTAssertEqual(Set(relay.rows.map(\.status.text)), ["Online", "Offline", "Needs update", "Incompatible"])

        XCTAssertEqual(DevicesViewState(DevicesDemoFixture.firstRun.snapshot).layout, .firstRun)
        XCTAssertEqual(DevicesViewState(DevicesDemoFixture.nearbyDenied.snapshot).nearby.notice, .permissionDenied)
        XCTAssertEqual(DevicesViewState(DevicesDemoFixture.nearbySearching.snapshot).nearby.notice, .searching)
        XCTAssertEqual(DevicesViewState(DevicesDemoFixture.nearbyEmpty.snapshot).nearby.notice, .empty)
        guard case let .paired(loading) = DevicesViewState(DevicesDemoFixture.relayLoading.snapshot).relay else { return XCTFail("Expected a paired relay") }
        XCTAssertEqual(loading.placeholder, .loading)
    }
    #endif
}
