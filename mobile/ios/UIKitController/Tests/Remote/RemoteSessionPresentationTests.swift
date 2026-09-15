import RctlClient
import RctlRealtime
import XCTest
@testable import RctlUIKit

final class RemoteSessionPresentationTests: XCTestCase {
    private typealias Presentation = RemoteSessionPresentation

    private func live(_ configure: (inout RemoteSessionSnapshot) -> Void = { _ in }) -> RemoteSessionSnapshot {
        var snapshot = RemoteSessionSnapshot(
            state: .connected, videoAvailable: true, videoHealth: .flowing,
            media: .screen, interactionMode: .view, canControl: true, isLocal: true
        )
        configure(&snapshot)
        return snapshot
    }

    // MARK: Connection label and tone (SwiftUI connectionLabel / connectionColor)

    func testConnectionLabelsForEveryState() {
        let expectations: [(RctlRealtimeConnectionState, Bool, String, RemoteTone)] = [
            (.idle, true, "Ready", .tertiary),
            (.signaling, true, "Connecting locally", .accent),
            (.signaling, false, "Authorizing", .accent),
            (.connecting, true, "Connecting", .accent),
            (.disconnected, true, "Disconnected", .danger),
            (.failed, false, "Connection failed", .danger),
            (.closed, true, "Closed", .tertiary),
        ]
        for (state, isLocal, label, tone) in expectations {
            let presentation = Presentation(RemoteSessionSnapshot(state: state, isLocal: isLocal))
            XCTAssertEqual(presentation.connectionLabel, label, "\(state)")
            XCTAssertEqual(presentation.connectionTone, tone, "\(state)")
            XCTAssertFalse(presentation.isLive, "\(state)")
        }
    }

    func testConnectedLabelsDependOnVideoHealthAndMedia() {
        XCTAssertEqual(Presentation(live()).connectionLabel, "Live screen")
        XCTAssertEqual(Presentation(live()).connectionTone, .success)
        XCTAssertTrue(Presentation(live()).isLive)

        XCTAssertEqual(Presentation(live { $0.media = .camera }).connectionLabel, "Live camera")

        let waiting = Presentation(live { $0.videoAvailable = false; $0.videoHealth = .waiting })
        XCTAssertEqual(waiting.connectionLabel, "Waiting for video")
        XCTAssertEqual(waiting.connectionTone, .accent)
        XCTAssertFalse(waiting.isLive)

        let stalled = Presentation(live { $0.videoAvailable = false; $0.videoHealth = .stalled })
        XCTAssertEqual(stalled.connectionLabel, "Video paused")
        XCTAssertEqual(stalled.connectionTone, .accent)
        XCTAssertFalse(stalled.isLive)
    }

    // MARK: Mode chip and enablement

    func testModeChip() {
        let view = Presentation(live())
        XCTAssertEqual(view.modeLabel, "VIEW ONLY")
        XCTAssertEqual(view.modeTone, .secondary)
        XCTAssertEqual(view.modeAccessibilityValue, "View only")

        let control = Presentation(live { $0.interactionMode = .control })
        XCTAssertEqual(control.modeLabel, "CONTROL")
        XCTAssertEqual(control.modeTone, .accent)
        XCTAssertTrue(control.isControlMode)

        let camera = Presentation(live { $0.media = .camera; $0.interactionMode = .control })
        XCTAssertEqual(camera.modeLabel, "CAMERA")
        XCTAssertEqual(camera.modeTone, .text)
        XCTAssertEqual(camera.modeAccessibilityValue, "Camera")
    }

    func testControlsRequireScreenSourceControlModeAndCanControl() {
        XCTAssertTrue(Presentation(live { $0.interactionMode = .control }).controlsEnabled)
        XCTAssertFalse(Presentation(live()).controlsEnabled, "View mode blocks input")
        XCTAssertFalse(Presentation(live { $0.interactionMode = .control; $0.canControl = false }).controlsEnabled)
        XCTAssertFalse(Presentation(live { $0.interactionMode = .control; $0.media = .camera }).controlsEnabled)

        let blocked = Presentation(live { $0.canControl = false })
        XCTAssertFalse(blocked.canSelectControl, "The Control segment is disabled unless canControl")
        XCTAssertEqual(blocked.viewportHint, "Select Control to enable remote input")
        XCTAssertEqual(Presentation(live { $0.interactionMode = .control }).viewportHint, "Touches control the remote device")
    }

    /// Every combination of inputs keeps the safety and overlay invariants.
    func testInvariantsAcrossAllCombinations() {
        let states: [RctlRealtimeConnectionState] = [.idle, .signaling, .connecting, .connected, .disconnected, .failed, .closed]
        let healths: [RctlVideoHealth] = [.waiting, .flowing, .stalled]
        var checked = 0
        for state in states {
            for health in healths {
                for videoAvailable in [false, true] {
                    for media in [ControllerMediaRole.screen, .camera] {
                        for mode in [RemoteInteractionMode.view, .control] {
                            for canControl in [false, true] {
                                for reconnecting in [false, true] {
                                    for error in [nil, "Boom"] as [String?] {
                                        for isLocal in [false, true] {
                                            let snapshot = RemoteSessionSnapshot(
                                                state: state, videoAvailable: videoAvailable, videoHealth: health,
                                                media: media, interactionMode: mode, canControl: canControl,
                                                reconnecting: reconnecting, reconnectAttempt: reconnecting ? 1 : 0,
                                                errorMessage: error, isLocal: isLocal
                                            )
                                            assertInvariants(Presentation(snapshot), snapshot)
                                            checked += 1
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 7 * 3 * 2 * 2 * 2 * 2 * 2 * 2 * 2)
    }

    private func assertInvariants(_ presentation: Presentation, _ snapshot: RemoteSessionSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        let context = "\(snapshot)"
        XCTAssertEqual(presentation.controlsEnabled, snapshot.media == .screen && snapshot.canControl && snapshot.interactionMode == .control, context, file: file, line: line)
        XCTAssertEqual(presentation.canSelectControl, snapshot.canControl, context, file: file, line: line)
        XCTAssertFalse(presentation.connectionLabel.isEmpty, context, file: file, line: line)
        if presentation.isLive {
            XCTAssertEqual(presentation.connectionTone, .success, context, file: file, line: line)
        }
        let interrupted = [.closed, .failed, .disconnected].contains(snapshot.state) || snapshot.videoHealth == .stalled
        switch presentation.overlay {
        case .hidden:
            XCTAssertFalse(interrupted, context, file: file, line: line)
            XCTAssertTrue(snapshot.videoAvailable, context, file: file, line: line)
        case let .progress(label):
            XCTAssertFalse(interrupted, context, file: file, line: line)
            XCTAssertFalse(snapshot.videoAvailable, context, file: file, line: line)
            XCTAssertEqual(label, presentation.connectionLabel, context, file: file, line: line)
        case let .interruption(card):
            XCTAssertTrue(interrupted, context, file: file, line: line)
            XCTAssertFalse(card.message.isEmpty, context, file: file, line: line)
            XCTAssertEqual(card.recovery == .reconnectButton, !snapshot.reconnecting, context, file: file, line: line)
        }
    }

    // MARK: Overlay

    func testOverlayProgressWhileWaitingForVideo() {
        XCTAssertEqual(Presentation(RemoteSessionSnapshot(state: .signaling, isLocal: false)).overlay, .progress(label: "Authorizing"))
        XCTAssertEqual(Presentation(RemoteSessionSnapshot(state: .idle, isLocal: true)).overlay, .progress(label: "Ready"))
        XCTAssertEqual(Presentation(live { $0.videoAvailable = false }).overlay, .progress(label: "Waiting for video"))
        XCTAssertEqual(Presentation(live()).overlay, .hidden)
    }

    func testOverlayInterruptionCards() {
        let failed = Presentation(RemoteSessionSnapshot(state: .failed, isLocal: true))
        XCTAssertEqual(failed.overlay, .interruption(.init(
            kind: .connectionInterrupted, title: "Connection interrupted",
            message: "The device connection was interrupted.", recovery: .reconnectButton
        )))

        let failedWithError = Presentation(RemoteSessionSnapshot(state: .disconnected, errorMessage: "Input stopped.", isLocal: true))
        guard case let .interruption(card) = failedWithError.overlay else { return XCTFail("Expected a card") }
        XCTAssertEqual(card.message, "Input stopped.")

        let ended = Presentation(RemoteSessionSnapshot(state: .closed, isLocal: true))
        XCTAssertEqual(ended.overlay, .interruption(.init(
            kind: .sessionEnded, title: "Session ended",
            message: "Reconnect to start a new session.", recovery: .reconnectButton
        )))

        // A closed session keeps the model's reason (e.g. changed controller access) visible.
        let revoked = Presentation(RemoteSessionSnapshot(state: .closed, errorMessage: "Controller access changed. Reconnect to use current permissions.", isLocal: false))
        guard case let .interruption(revokedCard) = revoked.overlay else { return XCTFail("Expected a card") }
        XCTAssertEqual(revokedCard.kind, .sessionEnded)
        XCTAssertEqual(revokedCard.message, "Controller access changed. Reconnect to use current permissions.")

        let stalled = Presentation(live { $0.videoAvailable = false; $0.videoHealth = .stalled; $0.errorMessage = "ignored" })
        XCTAssertEqual(stalled.overlay, .interruption(.init(
            kind: .videoPaused, title: "Video paused",
            message: "No fresh frames. Control is disabled.", recovery: .reconnectButton
        )))
    }

    func testReconnectingProgressReplacesButton() {
        let snapshot = RemoteSessionSnapshot(state: .failed, reconnecting: true, reconnectAttempt: 2, isLocal: true)
        guard case let .interruption(card) = Presentation(snapshot).overlay else { return XCTFail("Expected a card") }
        XCTAssertEqual(card.recovery, .reconnecting(label: "Reconnecting 2/3"))
    }

    // MARK: Access path

    func testAccessPathPresentation() throws {
        let lan = RemoteAccessPathPresentation(.lan(try LocalDeviceAddress("192.168.1.30:8080")))
        XCTAssertTrue(lan.isLocal)
        XCTAssertEqual(lan.badgeText, "LAN")
        XCTAssertEqual(lan.accessibilityLabel, "Connection path: local network")
        XCTAssertEqual(lan.pathDescription, "Local network")
        XCTAssertEqual(lan.endpoint, "192.168.1.30:8080")
        XCTAssertEqual(lan.trust, "Trusted network · not paired")
        XCTAssertEqual(lan.trustTone, .accent)

        let relay = RemoteAccessPathPresentation(.relay(origin: "https://relay.example.net:8443"))
        XCTAssertFalse(relay.isLocal)
        XCTAssertEqual(relay.badgeText, "Relay")
        XCTAssertEqual(relay.accessibilityLabel, "Connection path: relay")
        XCTAssertEqual(relay.endpoint, "relay.example.net")
        XCTAssertEqual(relay.trust, "Authenticated controller")
        XCTAssertEqual(relay.trustTone, .success)

        XCTAssertEqual(RemoteAccessPathPresentation(.relay(origin: nil)).endpoint, "Unavailable")
        XCTAssertEqual(RemoteAccessPathPresentation(.relay(origin: "not a url")).endpoint, "not a url")
    }

    // MARK: Diagnostics

    func testDiagnosticsFormatting() {
        var diagnostics = RctlRealtimeDiagnostics()
        diagnostics.framesPerSecond = 59.84
        diagnostics.bitsPerSecond = 4_812_345
        diagnostics.packetLossPercent = 0.25
        diagnostics.roundTripMilliseconds = 18.4
        diagnostics.route = .turn
        let formatted = RemoteDiagnosticsPresentation(diagnostics, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(formatted.metrics.map(\.title), ["Decoded FPS", "Video bitrate", "Packet loss", "RTT", "Media route"])
        XCTAssertEqual(formatted.framesPerSecond.value, "59.8")
        XCTAssertEqual(formatted.bitrate.value, "4,812 kbps")
        XCTAssertEqual(formatted.packetLoss.value, "0.2%")
        XCTAssertEqual(formatted.roundTrip.value, "18 ms")
        XCTAssertEqual(formatted.route.value, "TURN")
    }

    func testUnknownDiagnosticsStayUnavailable() {
        let formatted = RemoteDiagnosticsPresentation(RctlRealtimeDiagnostics(), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(formatted.framesPerSecond.value, "Unavailable")
        XCTAssertEqual(formatted.bitrate.value, "Unavailable")
        XCTAssertEqual(formatted.packetLoss.value, "Unavailable")
        XCTAssertEqual(formatted.roundTrip.value, "Unavailable")
        XCTAssertEqual(formatted.route.value, "Unknown")

        var zero = RctlRealtimeDiagnostics()
        zero.packetLossPercent = 0
        XCTAssertEqual(RemoteDiagnosticsPresentation(zero, locale: Locale(identifier: "en_US")).packetLoss.value, "0.0%")
    }
}
