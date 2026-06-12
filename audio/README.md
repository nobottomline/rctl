# rctlaudio

`rctlaudio` is the guarded mediaserverd system-audio agent.

The top-level package builds this target from `audio/` and ships it as an
inactive payload under `/usr/local/lib/rctl/audio`. It is not loaded at boot.
`rctld` activates it only when `/v1/audio_capture?on=1` is requested:

1. copy `rctlaudio.dylib` and `rctlaudio.plist` into the active MobileSubstrate path;
2. create `/tmp/rctl-audio-capture`;
3. restart `mediaserverd`;
4. receive timestamped PCM packets on `127.0.0.1:8079`.

The agent hooks supported AudioQueue/AudioUnit playback paths, copies Linear PCM
into a bounded queue, and returns to the render path immediately. Network I/O is
done by a worker thread. A 180 second watchdog stops capture if the active files
are accidentally left behind.

`/tmp/rctl-audio-tone` is kept as an internal diagnostic mode for validating the
audio ingest path without relying on real app playback. The browser UI no longer
exposes this mode.
