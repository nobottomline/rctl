#pragma once
// Local SB<->daemon IPC over a Unix-domain socket. The daemon (rctld) listens;
// the SpringBoard agent (rctlsbcap) connects. Framing: [1B type][4B BE len][payload].
// Both ends are arm64, so the fixed-layout payload structs are exchanged by value.

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RCTL_IPC_SOCK_PATH "/var/run/rctl-ipc.sock"
#define RCTL_AUDIO_IPC_SOCK_PATH "/var/run/rctl-audio.sock"
#define RCTL_AUDIO_TCP_PORT 8079

enum {
    RCTL_MSG_VIDEO  = 0x01,  // SB->daemon: [1B keyframe flag][Annex-B AU]
    RCTL_MSG_ORIENT = 0x02,  // SB->daemon: [1B UIInterfaceOrientation 1..4]
    RCTL_MSG_AUDIO  = 0x03,  // audio-source->daemon: PCM packet, see HttpStreamServer.h
    RCTL_MSG_INPUT  = 0x10,  // daemon->SB: rctl_ipc_input
    RCTL_MSG_KEY    = 0x11,  // daemon->SB: rctl_ipc_key
    RCTL_MSG_CONFIG = 0x12,  // daemon->SB: rctl_ipc_config
    RCTL_MSG_LAUNCH = 0x13,  // daemon->SB: bundle id (UTF-8)
    RCTL_MSG_ALERT  = 0x14,  // daemon->SB: "title\nmessage" (UTF-8)
    RCTL_MSG_TOAST  = 0x15,  // daemon->SB: toast text (UTF-8)
    RCTL_MSG_SETCLIP= 0x16,  // daemon->SB: set the pasteboard to this text
    RCTL_MSG_OPENURL= 0x17,  // daemon->SB: open this URL
    RCTL_MSG_QUERY  = 0x18,  // daemon->SB: [4B BE reqid][1B qtype][payload], expects a REPLY
    RCTL_MSG_REPLY  = 0x19,  // SB->daemon: [4B BE reqid][payload]
    RCTL_MSG_ACTIVE = 0x1A,  // daemon->SB: [1B active] run capture+keep-awake (1) or idle/sleep (0)
    RCTL_MSG_FX     = 0x1B,  // daemon->SB: [1B subtype][data] fun FX (1=say,2=sound,3=flash,4=banner)
};

// Query types carried in RCTL_MSG_QUERY (request/response over the socket).
enum { RCTL_Q_CLIPBOARD = 1, RCTL_Q_DEVINFO = 2, RCTL_Q_APPLIST = 3 };

#pragma pack(push, 1)
typedef struct { int32_t phase; int32_t finger; double x; double y; } rctl_ipc_input;
typedef struct { int32_t page;  int32_t usage;  int32_t down;        } rctl_ipc_key;
typedef struct { int32_t fps;   double  scale;  int32_t bitrate;     } rctl_ipc_config;
#pragma pack(pop)

typedef struct rctl_ipc rctl_ipc;                // one connected endpoint
typedef struct rctl_ipc_server rctl_ipc_server;  // listening socket (daemon)

// Daemon side.
rctl_ipc_server *rctl_ipc_listen(const char *path);  // unlink + bind + listen
rctl_ipc        *rctl_ipc_accept(rctl_ipc_server *s);// blocks until a peer connects

// SB side: one connection attempt; NULL if the daemon isn't up yet.
rctl_ipc *rctl_ipc_connect(const char *path);

// Send a framed message (payload may be NULL/0). false => peer gone.
bool rctl_ipc_send(rctl_ipc *c, uint8_t type, const void *data, uint32_t len);
// Like send, but with a 1-byte prefix prepended to the payload (no caller copy).
bool rctl_ipc_send_prefixed(rctl_ipc *c, uint8_t type, uint8_t prefix,
                            const void *data, uint32_t len);
// Receive one framed message; *out is malloc'd (caller frees), NULL if len==0.
// Blocks. false => EOF/error.
bool rctl_ipc_recv(rctl_ipc *c, uint8_t *type, uint8_t **out, uint32_t *len);

void rctl_ipc_close(rctl_ipc *c);

#ifdef __cplusplus
}
#endif
