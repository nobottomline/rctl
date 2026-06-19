// Phase 4 feasibility probe: confirm the cross-compiled libdatachannel actually
// links into rctld and initializes on the device. Creates and tears down a
// PeerConnection + DataChannel at daemon startup and logs the result to
// /tmp/rctld.log. Temporary — the real WebRTC device logic (ported from
// experiments/webrtc-spike/relay_device.cpp) replaces this.

#include "rtc/rtc.hpp"

#include <cstdio>
#include <ctime>
#include <memory>
#include <unistd.h>

static void wprobe_log(const char *msg) {
    FILE *f = fopen("/tmp/rctld.log", "a");
    if (!f) return;
    fprintf(f, "[%ld pid=%d] [webrtc] %s\n", (long)time(NULL), getpid(), msg);
    fclose(f);
}

extern "C" void rctl_webrtc_probe(void) {
    try {
        rtc::InitLogger(rtc::LogLevel::Warning);
        auto pc = std::make_shared<rtc::PeerConnection>(rtc::Configuration{});
        auto dc = pc->createDataChannel("probe");
        (void)dc;
        wprobe_log("probe OK: libdatachannel linked, PeerConnection + DataChannel created");
        pc->close();
    } catch (const std::exception &e) {
        char buf[256];
        snprintf(buf, sizeof buf, "probe FAILED: %s", e.what());
        wprobe_log(buf);
    } catch (...) {
        wprobe_log("probe FAILED: unknown exception");
    }
}
