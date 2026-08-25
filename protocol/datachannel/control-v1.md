# Control DataChannel v1

Label: `control`. Transport: reliable, ordered SCTP DataChannel created by the
device on the screen PeerConnection. Direction: controller to device.

Every message is UTF-8 JSON matching `schemas/control.schema.json` and no larger
than `control_json_bytes` in `limits.json`.

Touch:

```json
{"t":"t","p":1,"i":2,"x":0.125,"y":0.875}
```

- `p`: `0` down, `1` move, `2` up.
- `i`: stable finger id from `0` through `10` for the contact lifetime.
- `x`, `y`: finite normalized coordinates in fixed portrait framebuffer space,
  inclusive range `0...1`.

Key:

```json
{"t":"k","pg":12,"u":64,"d":1}
```

- `pg`: HID usage page. Current clients use keyboard `7`, consumer `12`, and
  rctl SpringBoard actions `240`.
- `u`: HID usage.
- `d`: `1` press, `0` release, `2` atomic press and release. Text and ordinary
  non-modifier keys use `2` so a lost or delayed release cannot leave a key held;
  modifiers use explicit ordered `1` / `0` transitions.

Receivers reject binary, oversized, malformed, non-finite, out-of-range, or
unknown messages without invoking input. Move events may be coalesced before
sending; down/up and key transitions may not be reordered or discarded.
