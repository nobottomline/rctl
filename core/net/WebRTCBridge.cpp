// Device-side WebRTC bridge for rctld (ported from
// relay/experiments/webrtc-spike/relay_device.cpp, proven on macOS, then on
// device with synthetic video). Now streams the real Annex-B H.264 the capture
// pipeline produces.
//
// RelayClient.mm feeds inbound `webrtc_signal` envelopes to handle_signal() and
// registers a sender for outbound answer/ICE; main.mm calls push_au() for every
// encoded access unit. One libdatachannel PeerConnection per signaling session;
// the browser is the offerer and creates the channels.

#include "net/WebRTCBridge.h"
#include "rtc/rtc.hpp"
#include "nlohmann/json.hpp"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <unistd.h>
#include <mach/mach.h>

using nlohmann::json;

static void (*g_send)(const char *) = nullptr;
static void (*g_viewer_cb)(bool) = nullptr;
static std::mutex g_mtx;
static std::map<std::string, std::shared_ptr<rtc::PeerConnection>> g_sessions;

struct VideoChan {
    std::shared_ptr<rtc::DataChannel> dc;
    bool sawKey;
};
static std::vector<std::shared_ptr<VideoChan>> g_video;  // open video channels

static void wlog(const std::string &m) {
    FILE *f = fopen("/tmp/rctld.log", "a");
    if (!f) return;
    fprintf(f, "[%ld pid=%d] [webrtc] %s\n", (long)time(NULL), getpid(), m.c_str());
    fclose(f);
}

static void send_signal(const std::string &id, const std::string &kind, const json &payload) {
    if (!g_send) return;
    json m = {{"type", "webrtc_signal"}, {"id", id}, {"kind", kind}};
    if (!payload.is_null()) m["payload"] = payload;
    std::string s = m.dump();
    g_send(s.c_str());
}

static void start_session(const std::string &id) {
    auto pc = std::make_shared<rtc::PeerConnection>(rtc::Configuration{});

    pc->onLocalDescription([id](rtc::Description d) {
        send_signal(id, d.typeString(), json{{"sdp", std::string(d)}});
    });
    pc->onLocalCandidate([id](rtc::Candidate c) {
        send_signal(id, "candidate", json{{"candidate", std::string(c)}, {"mid", c.mid()}});
    });
    pc->onStateChange([id](rtc::PeerConnection::State s) {
        wlog("session " + id + " state " + std::to_string((int)s));
    });
    pc->onDataChannel([id](std::shared_ptr<rtc::DataChannel> dc) {
        if (dc->label() == "control") {
            dc->onMessage([](rtc::message_variant) {});
            return;
        }
        if (dc->label() != "video") return;
        wlog("session " + id + " video channel open");
        auto vc = std::make_shared<VideoChan>();
        vc->dc = dc;
        vc->sawKey = false;
        rtc::DataChannel *dcptr = dc.get();
        dc->onClosed([dcptr]() {
            bool lastGone = false;
            {
                std::lock_guard<std::mutex> lk(g_mtx);
                g_video.erase(std::remove_if(g_video.begin(), g_video.end(),
                                  [dcptr](const std::shared_ptr<VideoChan> &v) {
                                      return v->dc.get() == dcptr;
                                  }),
                              g_video.end());
                lastGone = g_video.empty();
            }
            if (lastGone && g_viewer_cb) g_viewer_cb(false);
        });
        bool firstViewer = false;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            firstViewer = g_video.empty();
            g_video.push_back(vc);
        }
        if (firstViewer && g_viewer_cb) g_viewer_cb(true);
    });

    std::lock_guard<std::mutex> lk(g_mtx);
    g_sessions[id] = pc;
}

extern "C" void rctl_webrtc_set_sender(void (*send)(const char *)) {
    g_send = send;
    wlog("bridge ready");
}

extern "C" void rctl_webrtc_set_viewer_cb(void (*cb)(bool)) {
    g_viewer_cb = cb;
}

extern "C" void rctl_webrtc_handle_signal(const char *jsonStr) {
    if (!jsonStr) return;
    json m;
    try { m = json::parse(jsonStr); } catch (...) { return; }
    std::string id = m.value("id", "");
    std::string kind = m.value("kind", "");
    if (id.empty()) return;

    if (kind == "open") {
        wlog("session open " + id);
        start_session(id);
        return;
    }
    if (kind == "close") {
        std::lock_guard<std::mutex> lk(g_mtx);
        g_sessions.erase(id);
        return;
    }

    std::shared_ptr<rtc::PeerConnection> pc;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto it = g_sessions.find(id);
        if (it != g_sessions.end()) pc = it->second;
    }
    if (!pc) return;

    json p = m.contains("payload") ? m["payload"] : json::object();
    try {
        if (kind == "offer" || kind == "answer") {
            pc->setRemoteDescription(rtc::Description(p.value("sdp", std::string()), kind));
        } else if (kind == "candidate") {
            pc->addRemoteCandidate(
                rtc::Candidate(p.value("candidate", std::string()), p.value("mid", std::string())));
        }
    } catch (const std::exception &e) {
        wlog(std::string("signal error: ") + e.what());
    }
}

// Each video channel gets: [1B keyframe][8B pts_us big-endian][Annex-B AU].
// A channel only starts receiving once a keyframe has passed (so WebCodecs can
// configure and decode); the channel is unreliable, so a dropped AU just waits
// for the next keyframe.
extern "C" void rctl_webrtc_push_au(const uint8_t *data, size_t len, bool keyframe, uint64_t pts_us) {
    if (!data || len == 0) return;
    // Fragment: a DataChannel message can\'t exceed the negotiated SCTP limit
    // (~256KB in Chrome), and keyframes blow past it. Chunk frame layout:
    //   [1B keyframe][8B pts_us BE][4B totalLen BE][4B offset BE][chunk]
    const size_t MAX_CHUNK = 60000;                 // under the SCTP message limit
    const size_t MAX_BUFFERED = 2u * 1024 * 1024;   // drop if the channel falls this far behind

    std::lock_guard<std::mutex> lk(g_mtx);
    if (keyframe)
        for (auto &vc : g_video) vc->sawKey = true;

    for (auto &vc : g_video) {
        if (!vc->dc->isOpen() || !vc->sawKey) continue;
        // Backpressure: never let the send queue (and memory) grow unbounded when
        // the receiver can\'t keep up -- drop this AU and re-sync at the next
        // keyframe. This is the unreliable-video principle (prefer the newest
        // frame), and it keeps rctld from being killed under load.
        if (vc->dc->bufferedAmount() > MAX_BUFFERED) {
            vc->sawKey = false;
            wlog("backpressure drop, buffered=" + std::to_string(vc->dc->bufferedAmount()));
            continue;
        }
        try {
            for (size_t off = 0; off < len; off += MAX_CHUNK) {
                size_t clen = (len - off < MAX_CHUNK) ? (len - off) : MAX_CHUNK;
                std::vector<std::byte> msg(17 + clen);
                uint8_t *b = reinterpret_cast<uint8_t *>(msg.data());
                b[0] = keyframe ? 1 : 0;
                for (int i = 0; i < 8; i++) b[1 + i] = (uint8_t)(pts_us >> (56 - 8 * i));
                uint32_t tl = (uint32_t)len, o32 = (uint32_t)off;
                for (int i = 0; i < 4; i++) b[9 + i] = (uint8_t)(tl >> (24 - 8 * i));
                for (int i = 0; i < 4; i++) b[13 + i] = (uint8_t)(o32 >> (24 - 8 * i));
                std::memcpy(b + 17, data + off, clen);
                vc->dc->send(msg);
            }
        } catch (...) {}
    }

    if (keyframe) {
        size_t maxBuf = 0;
        for (auto &vc : g_video)
            if (vc->dc->bufferedAmount() > maxBuf) maxBuf = vc->dc->bufferedAmount();
        struct mach_task_basic_info info;
        mach_msg_type_number_t cnt = MACH_TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &cnt) == KERN_SUCCESS)
            wlog("kf " + std::to_string(len) + "B rss=" + std::to_string(info.resident_size / (1024 * 1024)) +
                 "MB buffered=" + std::to_string(maxBuf / 1024) + "KB chans=" + std::to_string(g_video.size()));
    }
}
