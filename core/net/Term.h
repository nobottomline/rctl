#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Handles a WebSocket upgrade on /ws/term and bridges it to a root PTY shell.
// `ws_protocol` (may be NULL) is the exact subprotocol the gate accepted and
// that the 101 response must echo. Takes ownership of `fd` and closes it
// before returning.
void rctl_term_handle_ws(int fd, const char *req, const char *ws_protocol);

// Handles a WebSocket upgrade on /ws/signal and bridges it to the WebRTC bridge
// for device-local P2P signaling (host-only ICE -> direct-LAN WebRTC). Takes
// ownership of `fd` and closes it before returning.
void rctl_signal_handle_ws(int fd, const char *req, const char *ws_protocol);

#ifdef __cplusplus
}
#endif
