// rctld — root daemon, supervised by launchd (RunAtLoad + KeepAlive).
// Hosts the transport (HTTP/WebCodecs today; WebSocket/REST/WebRTC next) and
// relays between browsers and the SpringBoard agent over a local Unix socket:
//   SB -> daemon: encoded H.264 access units + orientation
//   daemon -> SB: touch / key / reconfigure commands
// Keeping transport here means a network bug can't respring SpringBoard, and
// launchd restarts us on any crash.

#import <Foundation/Foundation.h>
#import <pthread.h>
#import <unistd.h>
#import <stdio.h>
#import <time.h>
#import "net/HttpStreamServer.h"
#import "ipc/Ipc.h"

static void dlog(const char *msg) {
    FILE *f = fopen("/tmp/rctld.log", "a");
    if (f) { fprintf(f, "[%ld pid=%d] %s\n", (long)time(NULL), getpid(), msg); fclose(f); }
}

static rctl_http_server *gHttp = NULL;
static rctl_ipc        *gSB    = NULL;                       // current SB connection
static pthread_mutex_t  gSBLock = PTHREAD_MUTEX_INITIALIZER;

// Forward an HTTP-side command to the SpringBoard agent (drops if SB is away).
static void send_to_sb(uint8_t type, const void *data, uint32_t len) {
    pthread_mutex_lock(&gSBLock);
    if (gSB) (void)rctl_ipc_send(gSB, type, data, len);
    pthread_mutex_unlock(&gSBLock);
}

static void on_input(void *ctx, int phase, int finger, double nx, double ny) {
    rctl_ipc_input m = { (int32_t)phase, (int32_t)finger, nx, ny };
    send_to_sb(RCTL_MSG_INPUT, &m, sizeof m);
}

static void on_key(void *ctx, int page, int usage, int down) {
    rctl_ipc_key m = { (int32_t)page, (int32_t)usage, (int32_t)down };
    send_to_sb(RCTL_MSG_KEY, &m, sizeof m);
}

static void on_reconfigure(void *ctx, int fps, double scale, int bitrate) {
    rctl_ipc_config m = { (int32_t)fps, scale, (int32_t)bitrate };
    send_to_sb(RCTL_MSG_CONFIG, &m, sizeof m);
    rctl_http_signal_reset(gHttp);   // stream resolution/SPS will change
}

// Accept the SB agent, pump its messages to the HTTP server, re-accept on drop.
static void *ipc_thread(void *unused) {
    rctl_ipc_server *srv = rctl_ipc_listen(RCTL_IPC_SOCK_PATH);
    if (!srv) { dlog("ipc listen FAILED"); return NULL; }
    dlog("ipc listening");
    for (;;) {
        rctl_ipc *peer = rctl_ipc_accept(srv);
        if (!peer) { usleep(100000); continue; }
        dlog("SB connected");
        pthread_mutex_lock(&gSBLock); gSB = peer; pthread_mutex_unlock(&gSBLock);

        uint8_t type; uint8_t *buf; uint32_t len;
        while (rctl_ipc_recv(peer, &type, &buf, &len)) {
            if (type == RCTL_MSG_VIDEO && len >= 1) {
                rctl_http_push_au(gHttp, buf + 1, len - 1, buf[0] != 0);
            } else if (type == RCTL_MSG_ORIENT && len >= 1) {
                rctl_http_set_orientation(gHttp, buf[0]);
            }
            free(buf);
        }

        dlog("SB disconnected");
        pthread_mutex_lock(&gSBLock);
        if (gSB == peer) gSB = NULL;
        pthread_mutex_unlock(&gSBLock);
        rctl_ipc_close(peer);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        dlog("rctld started");

        // Port 8080 may briefly still be held by the old SpringBoard-hosted server
        // during an upgrade respring — retry the bind instead of dying.
        for (int i = 0; i < 30 && !gHttp; i++) {
            gHttp = rctl_http_start(8080);
            if (!gHttp) { dlog("http bind busy, retrying"); sleep(1); }
        }
        if (!gHttp) { dlog("http start FAILED"); return 1; }
        rctl_http_set_input(gHttp, on_input, NULL);
        rctl_http_set_key(gHttp, on_key, NULL);
        rctl_http_set_reconfigure(gHttp, on_reconfigure, NULL);
        dlog("http listening on :8080");

        pthread_t t;
        pthread_create(&t, NULL, ipc_thread, NULL);

        dispatch_main();
    }
    return 0;
}
