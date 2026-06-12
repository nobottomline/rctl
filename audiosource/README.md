# rctlaudiosource

Diagnostic-only mediaserverd audio-source skeleton.

This target is not part of the normal rctl package. It has no hooks and does not
touch system render/capture callbacks. When explicitly loaded into mediaserverd
with `/tmp/rctl-audiosource-tone` present, it sends a short synthetic S16LE PCM
tone to `/var/run/rctl-audio.sock` as `RCTL_MSG_AUDIO`.

With `/tmp/rctl-audiosource-capture` present, it installs diagnostic hooks for
AudioQueue/AudioUnit playback paths and forwards supported Linear PCM to
`rctld` over `127.0.0.1:8079`. This capture mode has an internal 180 second TTL
watchdog and is still a probe, not a production service.

Purpose:

- prove a non-SpringBoard process can feed the daemon audio ingest path;
- keep the future system-audio tap isolated from HTTP/WebCodecs code;
- provide reusable packet formatting and socket-send code for the real tap.
- validate capture boundaries without leaving a permanent mediaserverd hook.
