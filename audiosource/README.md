# rctlaudiosource

Diagnostic-only mediaserverd audio-source skeleton.

This target is not part of the normal rctl package. It has no hooks and does not
touch system render/capture callbacks. When explicitly loaded into mediaserverd
with `/tmp/rctl-audiosource-tone` present, it sends a short synthetic S16LE PCM
tone to `/var/run/rctl-audio.sock` as `RCTL_MSG_AUDIO`.

Purpose:

- prove a non-SpringBoard process can feed the daemon audio ingest path;
- keep the future system-audio tap isolated from HTTP/WebCodecs code;
- provide reusable packet formatting and socket-send code for the real tap.

