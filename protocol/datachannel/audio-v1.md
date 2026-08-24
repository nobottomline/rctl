# Audio DataChannels v1

All channels are reliable and ordered on the screen PeerConnection. Audio is
48 kHz Opus with 20 ms frames (`960` samples per channel). A packet may not exceed
`opus_packet_bytes` in `limits.json`.

Device to controller:

- `audio`: one byte channel count (`1` or `2`) followed by one Opus packet;
- `room-mic`: byte `1` followed by one mono Opus packet.

Controller to device:

- `mic-in`: one raw mono Opus packet without a channel prefix.

The first byte is not a general version byte. Version 1 is selected by protocol
major and capabilities. Empty, oversized, invalid-channel, or undecodable frames
are dropped. Queues are bounded and stale audio is discarded instead of growing
interactive latency. Closing `mic-in`, losing Talk eligibility, or losing the
viewer tears down controller microphone routing immediately.
