// Exercise the production registry and teardown against real libdatachannel.
// No capture/input callbacks are installed; no device or relay is contacted.
#include "../core/net/WebRTCBridge.cpp"
#include <cassert>

extern "C" bool rctl_audio_session_activate(void) { return true; }
extern "C" void rctl_audio_boost_begin(void) {}
extern "C" void rctl_audio_boost_end(void) {}
extern "C" int rctl_vmic_route(void) { return RCTL_TALK_SPEAKER; }
extern "C" void rctl_vmic_push(const int16_t *, int) {}

static void discard(void *, const char *) {}

static std::shared_ptr<rtc::PeerConnection> add(const char *id, void *owner) {
    auto session = std::make_shared<Session>();
    session->pc = std::make_shared<rtc::PeerConnection>();
    session->control = session->pc->createDataChannel("control");
    g_sessions[id] = session;
    rctl_webrtc_route_session(id, discard, owner);
    return session->pc;
}

int main() {
    int relayA, relayB, local;
    auto a = add("a:screen", &relayA);
    auto camera = add("a:camera", &relayA);
    auto b = add("b:screen", &relayB);
    auto lan = add("local", &local);
    rctl_webrtc_route_session("a:incomplete", discard, &relayA);
    rctl_webrtc_close_owner(nullptr);
    assert(g_sessions.size() == 4);
    rctl_webrtc_close_owner(&relayA);
    assert(a->state() == rtc::PeerConnection::State::Closed);
    assert(camera->state() == rtc::PeerConnection::State::Closed);
    assert(b->state() != rtc::PeerConnection::State::Closed);
    assert(lan->state() != rtc::PeerConnection::State::Closed);
    assert(g_sessions.size() == 2 && g_session_send.size() == 2);
    rctl_webrtc_close_owner(&relayA); // repeated disconnect is harmless
    assert(g_sessions.size() == 2);
    rctl_webrtc_close_owner(&relayB);
    rctl_webrtc_close_owner(&local);
    assert(g_sessions.empty() && g_session_send.empty());
    puts("WebRTC owner teardown passed (LAN and other relay preserved)");
}
