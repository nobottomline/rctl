# RctlRealtime

Native WebRTC boundary for RCTL Controller.
No SwiftUI view owns a peer connection. `RctlRealtimeSession` owns signaling,
offer/answer negotiation, bounded pre-offer ICE candidates, connection
generations, remote tracks, DataChannels, timeouts, and deterministic cleanup.
`RctlRemoteVideoView` keeps transport and hardware decode in WebRTC, then
presents its decoded `CVPixelBuffer` through a bounded Core Image/Metal surface.
The rctl-owned UIKit boundary owns only presentation and renderer lifecycle.

The exact `LiveKitWebRTC` dependency contains a symbol-prefixed build of
upstream WebRTC, not the LiveKit client SDK. SwiftPM verifies the binary
artifact checksum; package version, revision, artifact digest, and source-build
commit are recorded in `WebRTCDependency.swift`.

`RctlPeerConnectionFactory` is the only application boundary allowed to own
vendor WebRTC objects. UI and feature modules consume rctl models and session
APIs instead of importing `LiveKitWebRTC` directly. Release qualification must
verify H.264 decode, video rendering, DataChannels, lifecycle cleanup, relay
TURN paths, and sustained thermals on physical devices.

The session accepts a pre-authorized `URLRequest`; controller credentials and
request signing remain owned by `RctlClient`. Plaintext WebSocket signaling is
accepted only for explicit loopback development. Unknown DataChannels are
closed, control sends are bounded by backpressure, and incoming media payloads
are not copied onto the UI queue. Audio, file consumers, reconnect policy, and
statistics are later feature-specific layers rather than hidden behavior in
the base session.

The binary is distributed under WebRTC's three-clause BSD license. Its license
is included in the downloaded XCFramework and must be reproduced in the app's
third-party notices before release.
