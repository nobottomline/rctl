// Device-side WebRTC bridge for rctld (ported from
// relay/experiments/webrtc-spike/relay_device.cpp, proven on macOS).
//
// RelayClient.mm calls rctl_webrtc_handle_signal() for every `webrtc_signal`
// envelope the relay forwards over the /device connection, and registers a
// sender via rctl_webrtc_set_sender() so outbound signaling (answer / ICE) goes
// back over that same connection. One libdatachannel PeerConnection per
// signaling session; the browser is the offerer and creates the channels.
//
// Video is synthetic for now -- Phase 4 next step feeds real H.264 Access Units
// from the local capture pipeline onto the unreliable "video" channel.

#include "rtc/rtc.hpp"
#include "nlohmann/json.hpp"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

using nlohmann::json;
using namespace std::chrono;

static void (*g_send)(const char *) = nullptr;
static std::mutex g_mtx;
static std::map<std::string, std::shared_ptr<rtc::PeerConnection>> g_sessions;

static void wlog(const std::string &m) {
    FILE *f = fopen("/tmp/rctld.log", "a");
    if (!f) return;
    fprintf(f, "[%ld pid=%d] [webrtc] %s\n", (long)time(NULL), getpid(), m.c_str());
    fclose(f);
}

static long long now_ms() {
    return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
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
        } else if (dc->label() == "video") {
            wlog("session " + id + " video open -- streaming");
            std::thread([dc]() {
                uint32_t seq = 0;
                while (dc->isOpen()) {
                    std::vector<std::byte> buf(13 + 1500);
                    uint32_t s = seq++;
                    long long t = now_ms();
                    uint8_t type = (s % 60 == 0) ? 1 : 0;
                    std::memcpy(buf.data(), &s, 4);
                    std::memcpy(buf.data() + 4, &t, 8);
                    std::memcpy(buf.data() + 12, &type, 1);
                    try { dc->send(buf); } catch (...) { break; }
                    std::this_thread::sleep_for(milliseconds(16));
                }
            }).detach();
        }
    });

    std::lock_guard<std::mutex> lk(g_mtx);
    g_sessions[id] = pc;
}

extern "C" void rctl_webrtc_set_sender(void (*send)(const char *)) {
    g_send = send;
    wlog("bridge ready");
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
