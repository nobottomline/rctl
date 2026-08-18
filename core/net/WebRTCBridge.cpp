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
#include "net/VirtualMicServer.h"
#include "rtc/rtc.hpp"
#include "nlohmann/json.hpp"
#include <opus/opus.h>
#include <AudioToolbox/AudioToolbox.h>
#include <cstring>
#include <thread>

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
// Per-session outbound signaling override: local /ws/signal sessions route their
// offer/ICE to their own WebSocket via (fn,ctx) instead of the global relay
// sender g_send. Guarded by g_mtx.
struct SessionSender { void (*fn)(void *ctx, const char *json); void *ctx; };
static std::map<std::string, SessionSender> g_session_send;
static void (*g_viewer_cb)(bool) = nullptr;
static void (*g_keyframe_cb)(void) = nullptr;
static void (*g_camera_keyframe_cb)(void) = nullptr;
static void (*g_touch_cb)(int phase, int finger, double x, double y) = nullptr;
static void (*g_key_cb)(int page, int usage, int down) = nullptr;
static std::mutex g_mtx;

struct Session {
    std::shared_ptr<rtc::PeerConnection> pc;
    std::shared_ptr<rtc::Track> track;
    bool camera = false;
    std::shared_ptr<rtc::DataChannel> audioDc;
    std::shared_ptr<rtc::DataChannel> control;
    std::shared_ptr<rtc::DataChannel> filesDc;
    std::shared_ptr<rtc::DataChannel> micIn;
    std::shared_ptr<rtc::DataChannel> roomMic;
};
static std::map<std::string, std::shared_ptr<Session>> g_sessions;
// Open send tracks across all sessions (one browser may watch per session).
static std::vector<std::shared_ptr<rtc::Track>> g_tracks;
static std::vector<std::shared_ptr<rtc::Track>> g_camera_tracks;
static std::vector<std::shared_ptr<rtc::DataChannel>> g_audio_dcs;
// Room-mic (listen to the iPad mic): device->browser over its own channel + its own
// Opus encoder, kept separate from the system-output "audio" path.
static std::vector<std::shared_ptr<rtc::DataChannel>> g_microom_dcs;
static OpusEncoder *g_micEnc = nullptr;
static std::vector<int16_t> g_micPcm;
// File transfer rides its own reliable+ordered "files" DataChannel (P2P, so it
// bypasses the relay's body cap and streams any size). One transfer at a time, so
// a single active channel is enough for the daemon to send replies/chunks back.
static std::shared_ptr<rtc::DataChannel> g_files_dc;
static void (*g_files_cb)(const uint8_t *data, size_t len, int is_binary) = nullptr;
static std::chrono::steady_clock::time_point g_lastPli{};
static std::chrono::steady_clock::time_point g_lastCameraPli{};

// Opus encoder for the captured 48kHz PCM. Single-threaded (only push_audio
// touches it), so it needs no lock; only g_audio_dcs (the open audio channels)
// is shared and guarded by g_mtx.
static OpusEncoder *g_opus = nullptr;
static int g_opus_channels = 0;
static std::vector<int16_t> g_pcm;     // interleaved s16 accumulator

static void wlog(const std::string &m) {
    FILE *f = fopen("/tmp/rctld.log", "a");
    if (!f) return;
    fprintf(f, "[%ld pid=%d] [webrtc] %s\n", (long)time(NULL), getpid(), m.c_str());
    fclose(f);
}

static void send_signal(const std::string &id, const std::string &kind, const json &payload) {
    json m = {{"type", "webrtc_signal"}, {"id", id}, {"kind", kind}};
    if (!payload.is_null()) m["payload"] = payload;
    std::string s = m.dump();
    // Route to the session's own sender (local /ws/signal) if registered, else the
    // global relay sender. Copy the target under the lock, then call it unlocked
    // (the sender may block on a socket write).
    void (*fn)(void *, const char *) = nullptr;
    void *ctx = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto it = g_session_send.find(id);
        if (it != g_session_send.end()) { fn = it->second.fn; ctx = it->second.ctx; }
    }
    if (fn) fn(ctx, s.c_str());
    else if (g_send) g_send(s.c_str());
}

// A PLI/FIR from the browser asks for an intra frame (it lost reference frames
// it can't recover via NACK). Force the encoder to emit a keyframe via the
// daemon. Debounced hard (1s): browsers send PLI in bursts until a keyframe
// arrives, and -- critically -- the single shared encoder broadcasts every
// keyframe to ALL tracks, so a lossy viewer (e.g. a relayed iPhone) requesting
// keyframes would otherwise storm huge intra frames onto every other viewer
// (collapsing the healthy LAN Mac too). NACK still repairs ordinary loss fast;
// PLI is only the unrecoverable-loss fallback, so a long window is cheap.
static void request_keyframe(bool camera) {
    void (*cb)(void) = camera ? g_camera_keyframe_cb : g_keyframe_cb;
    if (!cb) return;
    auto now = std::chrono::steady_clock::now();
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto &last = camera ? g_lastCameraPli : g_lastPli;
        if (now - last < std::chrono::milliseconds(1000)) return;
        last = now;
    }
    wlog(std::string(camera ? "camera" : "screen") + " PLI -> force keyframe");
    cb();
}

// Drop a session's track from the active send list when its connection dies (ICE
// disconnected/failed/closed). Otherwise a viewer that vanishes without a clean
// "close" leaves a zombie track that push_au keeps feeding, and -- worse -- the
// track list never empties, so a fresh viewer isn't seen as the "first" and the
// daemon never re-applies the remote encode profile. Idempotent with onClosed.
static void retire_track(const std::string &id) {
    bool lastGone = false;
    bool camera = false;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto it = g_sessions.find(id);
        if (it == g_sessions.end() || !it->second->track) return;
        camera = it->second->camera;
        rtc::Track *tptr = it->second->track.get();
        auto &tracks = camera ? g_camera_tracks : g_tracks;
        size_t before = tracks.size();
        tracks.erase(std::remove_if(tracks.begin(), tracks.end(),
                          [tptr](const std::shared_ptr<rtc::Track> &t) { return t.get() == tptr; }),
                       tracks.end());
        lastGone = (before > 0 && tracks.empty());
    }
    if (!camera && lastGone && g_viewer_cb) g_viewer_cb(false);
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

// Tear a WebRTC session down WITHOUT racing its own callbacks. libdatachannel
// fires track/channel/PC onClosed handlers from its worker threads; if we drop
// the last shared_ptr (destroying the Track) while such a handler is mid-flight,
// the handler's captured state (e.g. the std::string `id`) is freed under it ->
// use-after-free. That SIGSEGV crash-looped rctld and wedged the whole device on
// viewer disconnect. resetCallbacks() blocks until any in-flight handler returns
// and detaches all of them, so the destruction that follows can't race a handler
// (and the Track destructor's own triggerClosed() then invokes an empty callback).
// MUST be called WITHOUT g_mtx held: an in-flight onClosed takes g_mtx, so holding
// it here would deadlock resetCallbacks().
static void mic_teardown();
static void destroy_session(std::shared_ptr<Session> dead) {
    if (!dead) return;
    if (dead->control) dead->control->resetCallbacks();
    if (dead->filesDc) dead->filesDc->resetCallbacks();
    if (dead->audioDc) dead->audioDc->resetCallbacks();
    if (dead->micIn)   dead->micIn->resetCallbacks();
    if (dead->roomMic) dead->roomMic->resetCallbacks();
    if (dead->track)   dead->track->resetCallbacks();
    if (dead->pc)      dead->pc->resetCallbacks();
    // Purge from the global send lists; the onClosed that normally does this is
    // now detached. Recompute the viewer count so capture stops only if this was
    // the last viewer.
    bool lastGone = false;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        if (dead->track) {
            rtc::Track *tp = dead->track.get();
            auto &tracks = dead->camera ? g_camera_tracks : g_tracks;
            size_t before = tracks.size();
            tracks.erase(std::remove_if(tracks.begin(), tracks.end(),
                              [tp](const std::shared_ptr<rtc::Track> &t) { return t.get() == tp; }),
                           tracks.end());
            lastGone = (before > 0 && tracks.empty());
        }
        if (dead->audioDc) {
            rtc::DataChannel *ap = dead->audioDc.get();
            g_audio_dcs.erase(std::remove_if(g_audio_dcs.begin(), g_audio_dcs.end(),
                                  [ap](const std::shared_ptr<rtc::DataChannel> &d) { return d.get() == ap; }),
                              g_audio_dcs.end());
        }
        if (dead->roomMic) {
            rtc::DataChannel *rp = dead->roomMic.get();
            g_microom_dcs.erase(std::remove_if(g_microom_dcs.begin(), g_microom_dcs.end(),
                                  [rp](const std::shared_ptr<rtc::DataChannel> &d) { return d.get() == rp; }),
                              g_microom_dcs.end());
        }
        if (dead->filesDc && g_files_dc && g_files_dc.get() == dead->filesDc.get()) g_files_dc.reset();
    }
    if (!dead->camera && lastGone && g_viewer_cb) g_viewer_cb(false);
    if (dead->micIn) mic_teardown();   // its onClosed is detached above
    // `dead` drops at the caller: callbacks detached + none in flight -> safe.
}

// ---- Mic intercom (Phase B.5) -------------------------------------------------
// Browser mic -> Opus over the "mic-in" DataChannel -> decode once, then route to
// the iPad speaker, the foreground app's virtual microphone, or both. Mono 48k
// matches the browser encoder and the loopback PCM bus.
extern "C" void rctl_audio_session_activate(void);  // defined in main.mm
extern "C" void rctl_audio_boost_begin(void);       // defined in main.mm
extern "C" void rctl_audio_boost_end(void);         // defined in main.mm
static std::mutex g_micMtx;
static OpusDecoder *g_micDec = nullptr;
static AudioQueueRef g_micAQ = nullptr;       // created once per process, never disposed
static bool g_micBoosted = false;             // inside a talk burst (volume raised)
static bool g_micWatchStarted = false;
static std::chrono::steady_clock::time_point g_micLast{};
static const int kMicRate = 48000;

static void mic_aq_done(void *user, AudioQueueRef aq, AudioQueueBufferRef buf) {
    (void)user;
    AudioQueueFreeBuffer(aq, buf);
}

// Re-creating an AudioQueue after AudioQueueDispose in the same process yields a
// SILENT queue on iOS (the second talk produced no sound). So the queue + decoder
// are created exactly once and kept for the process lifetime; talk on/off is just
// a gap in the frame stream. A watchdog detects that gap to restore the user's
// volume and flush/reset for the next burst -- without tearing the queue down.
static void mic_watchdog() {
    for (;;) {
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        std::lock_guard<std::mutex> lk(g_micMtx);
        if (!g_micBoosted) continue;
        auto idle = std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::steady_clock::now() - g_micLast).count();
        if (idle > 700) {
            rctl_audio_boost_end();
            if (g_micAQ) AudioQueueReset(g_micAQ);          // drop stale queued audio
            if (g_micDec) opus_decoder_ctl(g_micDec, OPUS_RESET_STATE);
            g_micBoosted = false;
            wlog("mic intercom: talk idle -> volume restored");
        }
    }
}

static void mic_play_opus(const uint8_t *opus, size_t len) {
    std::lock_guard<std::mutex> lk(g_micMtx);
    if (!g_micDec) {
        int err = 0;
        g_micDec = opus_decoder_create(kMicRate, 1, &err);
        if (err != OPUS_OK) { g_micDec = nullptr; return; }
    }
    auto now = std::chrono::steady_clock::now();
    bool newBurst = g_micLast.time_since_epoch().count() == 0 ||
                    std::chrono::duration_cast<std::chrono::milliseconds>(now - g_micLast).count() > 700;
    if (newBurst) opus_decoder_ctl(g_micDec, OPUS_RESET_STATE);
    g_micLast = now;
    int16_t pcm[5760];   // up to 120ms @ 48k mono
    int frames = opus_decode(g_micDec, opus, (opus_int32)len, pcm, 5760, 0);
    if (frames <= 0) return;

    int route = rctl_vmic_route();
    if (route == RCTL_TALK_VIRTUAL_MIC || route == RCTL_TALK_BOTH) rctl_vmic_push(pcm, frames);
    if (route == RCTL_TALK_VIRTUAL_MIC) {
        if (g_micBoosted) {
            rctl_audio_boost_end();
            if (g_micAQ) AudioQueueReset(g_micAQ);
            g_micBoosted = false;
        }
        return;
    }

    if (!g_micAQ) {
        AudioStreamBasicDescription a = {};
        a.mSampleRate = kMicRate;
        a.mFormatID = kAudioFormatLinearPCM;
        a.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        a.mChannelsPerFrame = 1;
        a.mBitsPerChannel = 16;
        a.mBytesPerFrame = 2;
        a.mFramesPerPacket = 1;
        a.mBytesPerPacket = 2;
        rctl_audio_session_activate();
        if (AudioQueueNewOutput(&a, mic_aq_done, nullptr, nullptr, nullptr, 0, &g_micAQ) != noErr) {
            g_micAQ = nullptr; return;
        }
        AudioQueueSetParameter(g_micAQ, kAudioQueueParam_Volume, 1.0f);
        AudioQueueStart(g_micAQ, nullptr);
        wlog("mic intercom: AudioQueue started (persistent)");
        if (!g_micWatchStarted) { std::thread(mic_watchdog).detach(); g_micWatchStarted = true; }
    }
    // Burst start after idle: re-route + raise volume and flush stale speaker audio.
    if (!g_micBoosted) {
        rctl_audio_session_activate();
        rctl_audio_boost_begin();
        AudioQueueReset(g_micAQ);
        g_micBoosted = true;
        wlog("mic intercom: talk burst start");
    }
    UInt32 bytes = (UInt32)frames * 2;
    AudioQueueBufferRef buf = nullptr;
    if (AudioQueueAllocateBuffer(g_micAQ, bytes, &buf) != noErr) return;
    memcpy(buf->mAudioData, pcm, bytes);
    buf->mAudioDataByteSize = bytes;
    AudioQueueEnqueueBuffer(g_micAQ, buf, 0, nullptr);
}

// Session/channel gone: restore the user's volume promptly and reset, but KEEP the
// queue alive (disposing + recreating it later goes silent on iOS).
static void mic_teardown() {
    std::lock_guard<std::mutex> lk(g_micMtx);
    if (g_micBoosted) {
        rctl_audio_boost_end();
        if (g_micAQ) AudioQueueReset(g_micAQ);
        if (g_micDec) opus_decoder_ctl(g_micDec, OPUS_RESET_STATE);
        g_micBoosted = false;
    }
}

static void start_session(const std::string &id, const json &ice, bool camera) {
    auto sess = std::make_shared<Session>();
    sess->camera = camera;
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
    const rtc::SSRC ssrc = camera ? 43 : 42;
    const char *mediaName = camera ? "camera" : "video";
    const char *cname = camera ? "rctl-camera" : "rctl-video";
    const int kPlayoutDelayExtId = 1;
    rtc::Description::Video media(mediaName, rtc::Description::Direction::SendOnly);
    media.addH264Codec(96);
    media.addSSRC(ssrc, cname);
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
        ssrc, cname, 96, rtc::H264RtpPacketizer::ClockRate);
    // min = 0 keeps latency at the floor when the link is clean; max = 6 (60ms)
    // lets the receiver's jitter buffer grow just enough to ride out an occasional
    // Wi-Fi loss/jitter burst (giving NACK retransmits time to arrive) instead of
    // freezing -- the buffer shrinks back toward 0 once the link settles.
    rtpConfig->playoutDelayId = kPlayoutDelayExtId;
    // Direct-LAN (local /ws/signal) sessions have near-zero network latency, so the
    // receiver's jitter buffer sits almost empty -> the encoder's bursty delivery
    // (keyframes, motion spikes) shows as freezes. Give the local path a small floor
    // so it rides those out; the relay path keeps the freshest-frame floor since its
    // own RTT already buffers. Units are 10ms (min 5 = 50ms, max 15 = 150ms).
    bool localSession = id.rfind("lws_", 0) == 0 || id.rfind("lcam_", 0) == 0;
    rtpConfig->playoutDelayMin = localSession ? 5 : 0;
    rtpConfig->playoutDelayMax = localSession ? 15 : 6;
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
    packetizer->addToChain(std::make_shared<rtc::PliHandler>([camera]() { request_keyframe(camera); }));
    track->setMediaHandler(packetizer);

    rtc::Track *tptr = track.get();
    // Capture the raw pointer, not the shared_ptr: a track that owns a callback
    // which owns the track is a reference cycle that never frees. Re-fetch the
    // shared_ptr from the session when the track opens.
    track->onOpen([id, tptr]() {
        bool firstViewer = false;
        bool camera = false;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            auto it = g_sessions.find(id);
            if (it == g_sessions.end() || !it->second->track || it->second->track.get() != tptr) return;
            camera = it->second->camera;
            auto &tracks = camera ? g_camera_tracks : g_tracks;
            firstViewer = tracks.empty();
            tracks.push_back(it->second->track);
        }
        if (!camera && firstViewer && g_viewer_cb) g_viewer_cb(true);
        wlog("session " + id + (camera ? " camera" : " screen") + " track open");
    });
    track->onClosed([id, tptr]() {
        bool lastGone = false;
        bool camera = false;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            auto it = g_sessions.find(id);
            camera = it != g_sessions.end() && it->second->camera;
            auto &tracks = camera ? g_camera_tracks : g_tracks;
            tracks.erase(std::remove_if(tracks.begin(), tracks.end(),
                              [tptr](const std::shared_ptr<rtc::Track> &t) {
                                  return t.get() == tptr;
                              }),
                          tracks.end());
            lastGone = tracks.empty();
        }
        if (!camera && lastGone && g_viewer_cb) g_viewer_cb(false);
        wlog("session " + id + (camera ? " camera" : " screen") + " track closed");
    });

    // Camera gets a dedicated PeerConnection. The iOS libsrtp/mbedtls build has
    // proven unreliable with a second media SSRC on the screen connection; one
    // H.264 track per connection keeps native RTP/NACK/PLI without that failure.
    if (camera) {
        std::shared_ptr<Session> prior;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            auto it = g_sessions.find(id);
            if (it != g_sessions.end()) prior = it->second;
            g_sessions[id] = sess;
        }
        destroy_session(prior);
        pc->setLocalDescription();
        return;
    }

    // Audio: Opus over a dedicated DataChannel (NOT a media track). The iOS
    // libsrtp/mbedtls backend drops ALL media RTP the moment a 2nd SRTP stream
    // (an audio SSRC) is added -- works on the macOS OpenSSL build, fails on iOS.
    // So audio rides SCTP (the DataChannel) instead: no 2nd media SSRC, no SRTP,
    // no risk to the video transport. The browser decodes the Opus frames with
    // WebCodecs and plays them. Reliable+ordered (default) -- audio needs order.
    auto audioDc = pc->createDataChannel("audio");
    sess->audioDc = audioDc;
    rtc::DataChannel *adptr = audioDc.get();
    audioDc->onOpen([id, adptr]() {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto it = g_sessions.find(id);
        if (it == g_sessions.end() || !it->second->audioDc || it->second->audioDc.get() != adptr) return;
        g_audio_dcs.push_back(it->second->audioDc);
        wlog("session " + id + " audio channel open");
    });
    audioDc->onClosed([adptr]() {
        std::lock_guard<std::mutex> lk(g_mtx);
        g_audio_dcs.erase(std::remove_if(g_audio_dcs.begin(), g_audio_dcs.end(),
                              [adptr](const std::shared_ptr<rtc::DataChannel> &d) { return d.get() == adptr; }),
                          g_audio_dcs.end());
    });

    // Room-mic channel (device -> browser): the iPad's own microphone, Opus over a
    // dedicated channel (separate encoder from the system-audio path so the two
    // sources don't share Opus state).
    auto roomMic = pc->createDataChannel("room-mic");
    sess->roomMic = roomMic;
    rtc::DataChannel *rmptr = roomMic.get();
    roomMic->onOpen([id, rmptr]() {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto it = g_sessions.find(id);
        if (it == g_sessions.end() || !it->second->roomMic || it->second->roomMic.get() != rmptr) return;
        g_microom_dcs.push_back(it->second->roomMic);
        wlog("session " + id + " room-mic channel open");
    });
    roomMic->onClosed([rmptr]() {
        std::lock_guard<std::mutex> lk(g_mtx);
        g_microom_dcs.erase(std::remove_if(g_microom_dcs.begin(), g_microom_dcs.end(),
                              [rmptr](const std::shared_ptr<rtc::DataChannel> &d) { return d.get() == rmptr; }),
                          g_microom_dcs.end());
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

    // File transfer channel: the browser sends JSON control (get/put) + raw binary
    // chunks; we reply with JSON + raw binary chunks, all P2P. Reliable+ordered
    // (default) so bytes cannot drop or reorder.
    auto filesDc = pc->createDataChannel("files");
    sess->filesDc = filesDc;
    rtc::DataChannel *fptr = filesDc.get();
    filesDc->onOpen([id, fptr]() {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto it = g_sessions.find(id);
        if (it == g_sessions.end() || !it->second->filesDc || it->second->filesDc.get() != fptr) return;
        g_files_dc = it->second->filesDc;
        wlog("session " + id + " files channel open");
    });
    filesDc->onMessage([](rtc::message_variant msg) {
        if (!g_files_cb) return;
        if (std::holds_alternative<std::string>(msg)) {
            const std::string &s = std::get<std::string>(msg);
            g_files_cb(reinterpret_cast<const uint8_t *>(s.data()), s.size(), 0);
        } else {
            const auto &b = std::get<rtc::binary>(msg);
            g_files_cb(reinterpret_cast<const uint8_t *>(b.data()), b.size(), 1);
        }
    });
    filesDc->onClosed([fptr]() {
        std::lock_guard<std::mutex> lk(g_mtx);
        if (g_files_dc && g_files_dc.get() == fptr) g_files_dc.reset();
    });

    // Mic-in channel (Phase B.5): the browser sends Opus frames of its microphone;
    // we decode + play them through the iPad speaker (intercom). Reliable+ordered
    // (default) like the audio channel -- simple and proven; can switch to lossy
    // for lower latency later.
    auto micIn = pc->createDataChannel("mic-in");
    sess->micIn = micIn;
    micIn->onMessage([](rtc::message_variant msg) {
        if (!std::holds_alternative<rtc::binary>(msg)) return;
        const auto &b = std::get<rtc::binary>(msg);
        mic_play_opus(reinterpret_cast<const uint8_t *>(b.data()), b.size());
    });
    micIn->onClosed([]() { mic_teardown(); });

    std::shared_ptr<Session> prior;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto it = g_sessions.find(id);
        if (it != g_sessions.end()) prior = it->second;
        g_sessions[id] = sess;
    }
    destroy_session(prior);     // safe teardown if a stale session reused this id
    pc->setLocalDescription();  // device offers
}

extern "C" void rctl_webrtc_route_session(const char *id, void (*send)(void *ctx, const char *json), void *ctx) {
    if (!id || !send) return;
    std::lock_guard<std::mutex> lk(g_mtx);
    g_session_send[std::string(id)] = SessionSender{send, ctx};
}

extern "C" void rctl_webrtc_unroute_session(const char *id) {
    if (!id) return;
    std::lock_guard<std::mutex> lk(g_mtx);
    g_session_send.erase(std::string(id));
}

// The local browser sends {kind, payload}; wrap it with the session id into the
// {type, id, kind, payload} envelope handle_signal expects, and dispatch.
extern "C" void rctl_webrtc_handle_local_signal(const char *id, const char *browser_json) {
    if (!id || !browser_json) return;
    json b;
    try { b = json::parse(browser_json); } catch (...) { return; }
    json m = {{"type", "webrtc_signal"}, {"id", std::string(id)}};
    if (b.contains("kind")) m["kind"] = b["kind"];
    if (b.contains("payload")) m["payload"] = b["payload"];
    rctl_webrtc_handle_signal(m.dump().c_str());
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

extern "C" void rctl_webrtc_set_camera_keyframe_cb(void (*cb)(void)) {
    g_camera_keyframe_cb = cb;
}

extern "C" void rctl_webrtc_set_input_cb(void (*touch)(int, int, double, double),
                                         void (*key)(int, int, int)) {
    g_touch_cb = touch;
    g_key_cb = key;
}

extern "C" void rctl_webrtc_set_files_cb(void (*cb)(const uint8_t *, size_t, int)) {
    g_files_cb = cb;
}

extern "C" void rctl_webrtc_files_send_text(const char *s) {
    if (!s) return;
    std::shared_ptr<rtc::DataChannel> dc;
    { std::lock_guard<std::mutex> lk(g_mtx); dc = g_files_dc; }
    if (dc && dc->isOpen()) { try { dc->send(std::string(s)); } catch (...) {} }
}

extern "C" void rctl_webrtc_files_send_binary(const uint8_t *data, size_t len) {
    if (!data || !len) return;
    std::shared_ptr<rtc::DataChannel> dc;
    { std::lock_guard<std::mutex> lk(g_mtx); dc = g_files_dc; }
    if (dc && dc->isOpen()) {
        rtc::binary b(reinterpret_cast<const std::byte *>(data),
                      reinterpret_cast<const std::byte *>(data + len));
        try { dc->send(std::move(b)); } catch (...) {}
    }
}

extern "C" uint64_t rctl_webrtc_files_buffered(void) {
    std::shared_ptr<rtc::DataChannel> dc;
    { std::lock_guard<std::mutex> lk(g_mtx); dc = g_files_dc; }
    return dc ? (uint64_t)dc->bufferedAmount() : 0;
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
        json payload = m.contains("payload") ? m["payload"] : json::array();
        json ice = payload;
        bool camera = false;
        if (payload.is_object()) {
            ice = payload.contains("ice") ? payload["ice"] : json::array();
            camera = payload.value("role", std::string("screen")) == "camera";
        }
        start_session(id, ice, camera);
        return;
    }
    if (kind == "close") {
        // Move the session out under the lock, then tear it down OUTSIDE the lock
        // via destroy_session() (which detaches callbacks before the last ref
        // drops -- see its note; doing this under g_mtx would deadlock).
        std::shared_ptr<Session> dead;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            auto it = g_sessions.find(id);
            if (it != g_sessions.end()) { dead = it->second; g_sessions.erase(it); }
        }
        destroy_session(dead);
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

extern "C" void rctl_webrtc_push_camera_au(const uint8_t *data, size_t len, bool keyframe, uint64_t pts_us) {
    if (!data || len == 0) return;

    std::vector<std::shared_ptr<rtc::Track>> tracks;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        if (g_camera_tracks.empty()) return;
        tracks = g_camera_tracks;
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
        wlog("camera keyframe " + std::to_string(len) + "B -> " + std::to_string(tracks.size()) + " track(s)");
}

// Encode captured 48kHz PCM to Opus and send every open audio DataChannel. Opus
// needs fixed 20ms frames (960 samples/channel @ 48kHz), so accumulate and drain.
// Wire format per message: [1B channels][Opus frame] -- the browser configures a
// WebCodecs Opus decoder from the channel count, then decodes each frame.
extern "C" void rctl_webrtc_push_mic(const int16_t *pcm, int frames, int channels, int rate) {
    if (!pcm || frames <= 0 || channels != 1 || rate != 48000) return;
    std::vector<std::shared_ptr<rtc::DataChannel>> dcs;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        if (g_microom_dcs.empty()) return;   // nobody listening
        dcs = g_microom_dcs;
    }
    if (!g_micEnc) {
        int err = 0;
        g_micEnc = opus_encoder_create(48000, 1, OPUS_APPLICATION_VOIP, &err);
        g_micPcm.clear();
        if (err != 0 || !g_micEnc) { g_micEnc = nullptr; return; }
    }
    g_micPcm.insert(g_micPcm.end(), pcm, pcm + (size_t)frames);
    const int FRAME = 960;  // 20ms @ 48k mono
    const size_t MAX_BUFFERED = 256u * 1024;
    unsigned char out[4000];
    while ((int)g_micPcm.size() >= FRAME) {
        int n = opus_encode(g_micEnc, g_micPcm.data(), FRAME, out, (opus_int32)sizeof out);
        g_micPcm.erase(g_micPcm.begin(), g_micPcm.begin() + FRAME);
        if (n <= 0) continue;
        std::vector<std::byte> msg(1 + (size_t)n);
        msg[0] = static_cast<std::byte>(1);
        std::memcpy(msg.data() + 1, out, (size_t)n);
        for (auto &d : dcs) {
            if (!d->isOpen() || d->bufferedAmount() > MAX_BUFFERED) continue;
            try { d->send(msg); } catch (...) {}
        }
    }
}

extern "C" void rctl_webrtc_push_audio(const int16_t *pcm, int frames, int channels,
                                       int rate, uint64_t pts_us) {
    (void)pts_us;
    if (!pcm || frames <= 0 || channels < 1 || channels > 2 || rate != 48000) return;

    std::vector<std::shared_ptr<rtc::DataChannel>> dcs;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        if (g_audio_dcs.empty()) return;  // nobody listening
        dcs = g_audio_dcs;
    }

    // The encoder state is only touched here (single IPC thread) -> no lock needed.
    if (!g_opus || g_opus_channels != channels) {
        if (g_opus) opus_encoder_destroy(g_opus);
        int err = 0;
        g_opus = opus_encoder_create(48000, channels, OPUS_APPLICATION_AUDIO, &err);
        g_opus_channels = channels;
        g_pcm.clear();
        if (err != 0 || !g_opus) { g_opus = nullptr; return; }
    }

    g_pcm.insert(g_pcm.end(), pcm, pcm + (size_t)frames * channels);
    const int FRAME = 960;  // 20ms @ 48kHz, per channel
    const size_t MAX_BUFFERED = 512u * 1024;  // drop if a channel falls behind
    unsigned char out[4000];
    while ((int)g_pcm.size() >= FRAME * channels) {
        int n = opus_encode(g_opus, g_pcm.data(), FRAME, out, (opus_int32)sizeof out);
        g_pcm.erase(g_pcm.begin(), g_pcm.begin() + (size_t)FRAME * channels);
        if (n <= 0) continue;
        std::vector<std::byte> msg(1 + (size_t)n);
        msg[0] = static_cast<std::byte>(channels);
        std::memcpy(msg.data() + 1, out, (size_t)n);
        for (auto &d : dcs) {
            if (!d->isOpen() || d->bufferedAmount() > MAX_BUFFERED) continue;
            try { d->send(msg); } catch (...) {}
        }
    }
}
