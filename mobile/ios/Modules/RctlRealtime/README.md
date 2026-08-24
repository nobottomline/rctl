# RctlRealtime

Native WebRTC boundary for the iOS controller and the non-shipping MediaProbe.
No SwiftUI view owns a peer connection; this module will own connection
generations, signaling, render tracks, DataChannels, cancellation, and stats.

The current exact `LiveKitWebRTC` dependency is a media-spike input, not a final
distribution decision. It contains a symbol-prefixed build of upstream WebRTC,
not the LiveKit client SDK. SwiftPM verifies the binary artifact checksum;
package version, revision, artifact digest, and source-build commit are recorded
in `WebRTCDependency.swift`.

`RctlPeerConnectionFactory` is the only application boundary allowed to own
vendor WebRTC objects. UI and feature modules consume rctl models and session
APIs instead of importing `LiveKitWebRTC` directly. The dependency can be
promoted only after the physical-device MediaProbe verifies H.264 decode,
Metal rendering, DataChannels, lifecycle cleanup, and sustained thermals.

The binary is distributed under WebRTC's three-clause BSD license. Its license
is included in the downloaded XCFramework and must be reproduced in the app's
third-party notices before release.
