# State DataChannel v1

Label: `state`. Transport: reliable, ordered SCTP DataChannel created by the
device on screen and camera PeerConnections. Direction: device to controller.

Every message is UTF-8 JSON matching `schemas/state.schema.json` and no larger
than `control_json_bytes` in `limits.json`. The device sends its latest state
when the channel opens and sends a replacement message after each change.

```json
{"v":1,"orientation":4}
```

- `v`: state-message schema version. Version 1 is the only accepted value.
- `orientation`: `UIInterfaceOrientation` value `1...4`. Encoded video remains
  in fixed portrait framebuffer coordinates; the controller rotates presentation
  and maps input back into that fixed space.

Receivers reject binary, oversized, malformed, unsupported-version, and
out-of-range messages. Unknown object fields are ignored within version 1.
