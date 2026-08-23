# Root Daemon

`rctld` owns the local HTTP/WebSocket API, relay connections, WebRTC transport,
root-only operations, and coordination with SpringBoard and app hooks. It does
not capture the screen or foreground camera itself.

Local `:8080` remains an intentionally unauthenticated trusted-LAN/USB interface;
read `docs/SECURITY.md` before changing exposure or authorization. Build through
the root Makefile and validate device behavior after packaging.
