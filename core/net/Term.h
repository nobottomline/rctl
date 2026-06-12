#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Handles a WebSocket upgrade on /ws/term and bridges it to a root PTY shell.
// Takes ownership of `fd` and closes it before returning.
void rctl_term_handle_ws(int fd, const char *req);

#ifdef __cplusplus
}
#endif
