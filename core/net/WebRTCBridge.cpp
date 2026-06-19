// Device-side WebRTC bridge for rctld. Streams the capture pipeline's Annex-B
// H.264 over a real WebRTC RTP media track (not a DataChannel), so the browser
// decodes it natively in <video> with a jitter buffer + NACK. This replaces the
// earlier DataChannel video path: the H.264 RTP packetizer fragments each access
// unit into MTU-sized RTP packets, so there is no SCTP message-size limit and no
// manual chunking, and loss is repaired by NACK instead of waiting for the next
// keyframe.
//
// The device is the offerer: for every signaling session it offers one send-only
// H.264 track, then streams access units through the packetizer. RelayClient.mm
// feeds inbound `webrtc_signal` envelopes to handle_signal() and registers a
// sender for outbound offer/ICE; main.mm calls push_au() for every encoded AU.
// One libdatachannel PeerConnection per signaling session.

#include "net/WebRTCBridge.h"
#include "rtc/rtc.hpp"
#include "nlohmann/json.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <unistd.h>

using nlohmann::json;
using std::chrono::duration;

static void (*g_send)(const char *) = nullptr;
static void (*g_viewer_cb)(bool) = nullptr;
static void (*g_keyframe_cb)(void) = nullptr;
static void (*g_touch_cb)(int phase, int finger, double x, double y) = nullptr;
static void (*g_key_cb)(int page, int usage, int down) = nullptr;
static std::mutex g_mtx;

struct Session {
    std::shared_ptr<rtc::PeerConnection> pc;
    std::shared_ptr<rtc::Track> track;
    std::shared_ptr<rtc::DataChannel> control;
};
static std::map<std::string, std::shared_ptr<Session>> g_sessions;
// Open send tracks across all sessions (one browser may watch per session).
static std::vector<std::shared_ptr<rtc::Track>> g_tracks;
static std::chrono::steady_clock::time_point g_lastPli{};

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

// A PLI/FIR from the browser asks for an intra frame (it lost reference frames
// it can't recover via NACK). Force the encoder to emit a keyframe via the
// daemon. Debounced: browsers send PLI in bursts until a keyframe arrives, and
// the encoder needs a few frames to produce one.
static void request_keyframe() {
    if (!g_keyframe_cb) return;
    auto now = std::chrono::steady_clock::now();
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        if (now - g_lastPli < std::chrono::milliseconds(250)) return;
        g_lastPli = now;
    }
    wlog("PLI -> force keyframe");
    g_keyframe_cb();
}

// Drop a session's track from the active send list when its connection dies (ICE
// disconnected/failed/closed). Otherwise a viewer that vanishes without a clean
// "close" leaves a zombie track that push_au keeps feeding, and -- worse -- the
// track list never empties, so a fresh viewer isn't seen as the "first" and the
// daemon never re-applies the remote encode profile. Idempotent with onClosed.
static void retire_track(const std::string &id) {
    bool lastGone = false;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto it = g_sessions.find(id);
        if (it == g_sessions.end() || !it->second->track) return;
        rtc::Track *tptr = it->second->track.get();
        size_t before = g_tracks.size();
        g_tracks.erase(std::remove_if(g_tracks.begin(), g_tracks.end(),
                          [tptr](const std::shared_ptr<rtc::Track> &t) { return t.get() == tptr; }),
                       g_tracks.end());
        lastGone = (before > 0 && g_tracks.empty());
    }
    if (lastGone && g_viewer_cb) g_viewer_cb(false);
}

// Build the libdatachannel ICE config from the RTCIceServer list the relay mints
// (STUN + short-lived TURN creds). STUN URLs go through the url parser; TURN URLs
// can't (our username is "<expiry>:<session>", and the colon breaks the
// user:pass@host url form), so parse host/port/transport and pass the credential
// explicitly. Without this the device only has host candidates (same-LAN reach).
static void add_ice_servers(rtc::Configuration &config, const json &arr) {
    if (!arr.is_array()) return;
    for (const auto &entry : arr) {
        if (!entry.contains("urls") || !entry["urls"].is_array()) continue;
        std::string user = entry.value("username", "");
        std::string cred = entry.value("credential", "");
        for (const auto &u : entry["urls"]) {
            std::string url = u.get<std::string>();
            try {
                if (url.rfind("stun:", 0) == 0) {
                    config.iceServers.emplace_back(url);
                } else if (url.rfind("turn:", 0) == 0 || url.rfind("turns:", 0) == 0) {
                    bool tls = url.rfind("turns:", 0) == 0;
                    std::string rest = url.substr(url.find(':') + 1);  // host:port[?transport=x]
                    std::string transport = "udp";
                    auto q = rest.find('?');
                    if (q != std::string::npos) {
                        std::string query = rest.substr(q + 1);
                        rest = rest.substr(0, q);
                        auto tp = query.find("transport=");
                        if (tp != std::string::npos) transport = query.substr(tp + 10);
                    }
                    auto colon = rest.rfind(':');
                    if (colon == std::string::npos) continue;
                    std::string host = rest.substr(0, colon);
                    uint16_t port = (uint16_t)std::stoi(rest.substr(colon + 1));
                    auto rt = tls ? rtc::IceServer::RelayType::TurnTls
                            : (transport == "tcp" ? rtc::IceServer::RelayType::TurnTcp
                                                  : rtc::IceServer::RelayType::TurnUdp);
                    config.iceServers.emplace_back(host, port, user, cred, rt);
                }
            } catch (...) {}
        }
    }
    wlog("ice servers configured: " + std::to_string(config.iceServers.size()));
}

static void start_session(const std::string &id, const json &ice) {
    auto sess = std::make_shared<Session>();
    rtc::Configuration config;
    add_ice_servers(config, ice);
    auto pc = std::make_shared<rtc::PeerConnection>(config);
    sess->pc = pc;

    pc->onLocalDescription([id](rtc::Description d) {
        send_signal(id, d.typeString(), json{{"sdp", std::string(d)}});
    });
    pc->onLocalCandidate([id](rtc::Candidate c) {
        send_signal(id, "candidate", json{{"candidate", std::string(c)}, {"mid", c.mid()}});
    });
    pc->onStateChange([id](rtc::PeerConnection::State s) {
        wlog("session " + id + " state " + std::to_string((int)s));
        if (s == rtc::PeerConnection::State::Disconnected ||
            s == rtc::PeerConnection::State::Failed ||
            s == rtc::PeerConnection::State::Closed)
            retire_track(id);
    });

    // Offer one send-only H.264 track (device -> browser). The browser answers
    // with a recvonly video m-line and attaches the track to a <video> element.
    const rtc::SSRC ssrc = 42;
    const int kPlayoutDelayExtId = 1;
    rtc::Description::Video media("video", rtc::Description::Direction::SendOnly);
    media.addH264Codec(96);
    media.addSSRC(ssrc, "rctl-video");
    // Ask the receiver to play out with zero added delay (min = max = 0). For
    // remote control we want the freshest frame, not a smoothing buffer; this is
    // the standard playout-delay RTP header extension, which the packetizer
    // stamps on every packet -- far more reliable than the browser-side
    // jitterBufferTarget hint (Safari ignores it, leaving ~110ms of buffer).
    media.addExtMap(rtc::Description::Media::ExtMap(
        kPlayoutDelayExtId, "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"));
    auto track = pc->addTrack(media);
    sess->track = track;

    auto rtpConfig = std::make_shared<rtc::RtpPacketizationConfig>(
        ssrc, "rctl-video", 96, rtc::H264RtpPacketizer::ClockRate);
    // min = 0 keeps latency at the floor when the link is clean; max = 6 (60ms)
    // lets the receiver's jitter buffer grow just enough to ride out an occasional
    // Wi-Fi loss/jitter burst (giving NACK retransmits time to arrive) instead of
    // freezing -- the buffer shrinks back toward 0 once the link settles.
    rtpConfig->playoutDelayId = kPlayoutDelayExtId;
    rtpConfig->playoutDelayMin = 0;
    rtpConfig->playoutDelayMax = 6;
    // StartSequence auto-detects 3- and 4-byte Annex-B start codes; the encoder
    // mixes them (SPS/PPS vs SEI/IDR), and LongStartSequence would mis-parse the
    // keyframe's NALs so the browser could never assemble a frame.
    auto packetizer = std::make_shared<rtc::H264RtpPacketizer>(
        rtc::NalUnit::Separator::StartSequence, rtpConfig);
    packetizer->addToChain(std::make_shared<rtc::RtcpSrReporter>(rtpConfig));
    packetizer->addToChain(std::make_shared<rtc::RtcpNackResponder>());
    // Let the browser pull a fresh intra frame on demand (PLI): a late-joining
    // second viewer, or loss that NACK can't repair, gets a keyframe right away
    // instead of waiting up to the encoder's GOP for the next periodic IDR.
    packetizer->addToChain(std::make_shared<rtc::PliHandler>([]() { request_keyframe(); }));
    track->setMediaHandler(packetizer);

    rtc::Track *tptr = track.get();
    // Capture the raw pointer, not the shared_ptr: a track that owns a callback
    // which owns the track is a reference cycle that never frees. Re-fetch the
    // shared_ptr from the session when the track opens.
    track->onOpen([id, tptr]() {
        bool firstViewer = false;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            auto it = g_sessions.find(id);
            if (it == g_sessions.end() || !it->second->track || it->second->track.get() != tptr) return;
            firstViewer = g_tracks.empty();
            g_tracks.push_back(it->second->track);
        }
        if (firstViewer && g_viewer_cb) g_viewer_cb(true);
        wlog("session " + id + " video track open");
    });
    track->onClosed([id, tptr]() {
        bool lastGone = false;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            g_tracks.erase(std::remove_if(g_tracks.begin(), g_tracks.end(),
                              [tptr](const std::shared_ptr<rtc::Track> &t) {
                                  return t.get() == tptr;
                              }),
                          g_tracks.end());
            lastGone = g_tracks.empty();
        }
        if (lastGone && g_viewer_cb) g_viewer_cb(false);
        wlog("session " + id + " video track closed");
    });

    // Control channel: the browser sends input (touch/keys) over this reliable,
    // ordered DataChannel instead of an HTTP round-trip per event -- low-latency
    // remote control on the same PeerConnection as the video. The device, as the
    // offerer, creates it so the data m-line is in the offer.
    auto control = pc->createDataChannel("control");
    sess->control = control;
    control->onMessage([](rtc::message_variant msg) {
        if (!std::holds_alternative<std::string>(msg)) return;
        try {
            json e = json::parse(std::get<std::string>(msg));
            const std::string t = e.value("t", "");
            if (t == "t" && g_touch_cb)
                g_touch_cb(e.value("p", 0), e.value("i", 0), e.value("x", 0.0), e.value("y", 0.0));
            else if (t == "k" && g_key_cb)
                g_key_cb(e.value("pg", 0), e.value("u", 0), e.value("d", 0));
        } catch (...) {}
    });

    {
        std::lock_guard<std::mutex> lk(g_mtx);
        g_sessions[id] = sess;
    }
    pc->setLocalDescription();  // device offers
}

extern "C" void rctl_webrtc_set_sender(void (*send)(const char *)) {
    g_send = send;
    wlog("bridge ready");
}

extern "C" void rctl_webrtc_set_viewer_cb(void (*cb)(bool)) {
    g_viewer_cb = cb;
}

extern "C" void rctl_webrtc_set_keyframe_cb(void (*cb)(void)) {
    g_keyframe_cb = cb;
}

extern "C" void rctl_webrtc_set_input_cb(void (*touch)(int, int, double, double),
                                         void (*key)(int, int, int)) {
    g_touch_cb = touch;
    g_key_cb = key;
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
        start_session(id, m.contains("payload") ? m["payload"] : json::array());
        return;
    }
    if (kind == "close") {
        // Move the session out under the lock, then let it destruct WITHOUT the
        // lock held -- the PeerConnection's teardown fires track onClosed, which
        // also takes g_mtx (holding it here would deadlock).
        std::shared_ptr<Session> dead;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            auto it = g_sessions.find(id);
            if (it != g_sessions.end()) { dead = it->second; g_sessions.erase(it); }
        }
        return;
    }

    std::shared_ptr<rtc::PeerConnection> pc;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto it = g_sessions.find(id);
        if (it != g_sessions.end()) pc = it->second->pc;
    }
    if (!pc) return;

    json p = m.contains("payload") ? m["payload"] : json::object();
    try {
        if (kind == "answer" || kind == "offer") {
            // The device offers, so the browser normally replies with "answer";
            // accept "offer" too for robustness against a renegotiation.
            pc->setRemoteDescription(rtc::Description(p.value("sdp", std::string()), kind));
        } else if (kind == "candidate") {
            pc->addRemoteCandidate(
                rtc::Candidate(p.value("candidate", std::string()), p.value("mid", std::string())));
        }
    } catch (const std::exception &e) {
        wlog(std::string("signal error: ") + e.what());
    }
}

// Feed one encoded Annex-B access unit to every open video track. The H.264 RTP
// packetizer fragments it into MTU-sized RTP packets; loss is repaired by NACK,
// and the browser's jitter buffer absorbs timing. Whole-AU send (no chunking).
extern "C" void rctl_webrtc_push_au(const uint8_t *data, size_t len, bool keyframe, uint64_t pts_us) {
    if (!data || len == 0) return;

    std::vector<std::shared_ptr<rtc::Track>> tracks;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        if (g_tracks.empty()) return;
        tracks = g_tracks;  // snapshot; send outside the lock
    }

    rtc::binary au(reinterpret_cast<const std::byte *>(data),
                   reinterpret_cast<const std::byte *>(data + len));
    rtc::FrameInfo info(duration<double>((double)pts_us / 1e6));
    info.isKeyFrame = keyframe;

    for (auto &t : tracks) {
        if (!t->isOpen()) continue;
        try { t->sendFrame(au, info); } catch (...) {}
    }

    if (keyframe)
        wlog("keyframe " + std::to_string(len) + "B -> " + std::to_string(tracks.size()) + " track(s)");
}
