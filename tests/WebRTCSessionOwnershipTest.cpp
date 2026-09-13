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

static void testVideoPacketBudget() {
    int owner;
    for (bool camera : {false, true}) {
        const char *id = camera ? "packet-budget-camera" : "packet-budget-screen";
        rctl_webrtc_route_session(id, discard, &owner);
        start_session(id, json::array(), camera, rctl::legacyWebRTCPermissions());
        auto handler = g_sessions.at(id)->track->getMediaHandler();
        // A large synthetic Annex-B IDR exercises every FU-A fragment, including
        // the short final fragment. No actual screen or camera data is needed.
        rtc::binary frame(128 * 1024, std::byte{0x55});
        frame[0] = frame[1] = frame[2] = std::byte{0};
        frame[3] = std::byte{1};
        frame[4] = std::byte{0x65};
        auto info = std::make_shared<rtc::FrameInfo>(std::chrono::duration<double>(0));
        info->isKeyFrame = true;
        rtc::message_vector packets{rtc::make_message(frame.begin(), frame.end(), info)};
        handler->outgoingChain(packets, [](rtc::message_ptr) {});
        assert(packets.size() > 100);
        size_t markers = 0;
        size_t payloadBytes = 0;
        for (const auto &packet : packets) {
            if (packet->type == rtc::Message::Control) continue;
            // IPv6 + UDP + TURN indication allowance + maximum negotiated SRTP
            // tag must fit the minimum IPv6 MTU, not just the H.264 payload.
            constexpr size_t transportOverhead = 40 + 8 + 64 + 16;
            assert(packet->size() + transportOverhead <= 1280);
            const auto *rtp = reinterpret_cast<const rtc::RtpHeader *>(packet->data());
            const auto *payload = reinterpret_cast<const std::byte *>(rtp->getBody());
            const size_t headerSize = payload - packet->data();
            assert(packet->size() > headerSize + 2);
            assert((std::to_integer<unsigned>(payload[0]) & 0x1f) == 28);
            markers += rtp->marker() ? 1 : 0;
            payloadBytes += packet->size() - headerSize - 2;
        }
        assert(markers == 1);
        assert(payloadBytes == frame.size() - 5);
        rctl_webrtc_close_owner(&owner);
        assert(!g_sessions.count(id));
    }
    puts("Screen/camera RTP packets fit the IPv6/TURN/SRTP budget without losing NAL bytes");
}
static std::string challengeNonce;
static void captureChallenge(void *, const char *raw) {
    auto message = json::parse(raw);
    if (message["kind"] == "authorization_challenge") challengeNonce = message["payload"]["nonce"].get<std::string>();
}

static void testLeaseClock() {
    rctl::ControllerAuthorizationLease lease(3, 100);
    assert(!lease.authorized(100));
    lease.challenge("first", 100);
    assert(!lease.renew(2, "first", 101));
    assert(!lease.renew(3, "wrong", 101));
    assert(lease.renew(3, "first", 110));
    assert(lease.expiresAt == 120); // delayed response buys no extra time
    assert(!lease.renew(3, "first", 111)); // one-time challenge
    assert(lease.challengeDue(111));
    lease.challenge("next", 111);
    assert(lease.renew(3, "next", 112));
    assert(lease.expiresAt == 131);
    lease.challenge("late", 116);
    assert(!lease.renew(3, "late", 131)); // expired access cannot resurrect
    assert(!lease.authorized(131));
    lease.retired = true;
    assert(!lease.authorized(112));
}

static std::shared_ptr<rtc::PeerConnection> add(const char *id, void *owner) {
    auto session = std::make_shared<Session>();
    session->pc = std::make_shared<rtc::PeerConnection>();
    session->control = session->pc->createDataChannel("control");
    g_sessions[id] = session;
    rctl_webrtc_route_session(id, discard, owner);
    return session->pc;
}

int main() {
    testVideoPacketBudget();
    testLeaseClock();
    int relayA, relayB, local;
    auto a = add("a:screen", &relayA);
    auto camera = add("a:camera", &relayA);
    auto b = add("b:screen", &relayB);
    auto lan = add("local", &local);
    rctl_webrtc_route_session("leased", captureChallenge, &relayA);
    rctl_webrtc_handle_signal(R"({"id":"leased","kind":"open","payload":{"role":"screen","scopes":["screen.view"],"authorization_revision":3,"ice":[]}})");
    assert(!g_sessions.count("leased") && g_authorizations.count("leased"));
    assert(challengeNonce.size() == 64);
    auto reply = json{{"id","leased"},{"kind","authorization_renew"},{"payload",{{"nonce",challengeNonce},{"authorization_revision",3}}}}.dump();
    rctl_webrtc_handle_signal(reply.c_str());
    assert(g_sessions.count("leased"));
    auto leasedPC = g_sessions.at("leased")->pc;
    auto lease = g_authorizations.at("leased").lease;
    double expiry = lease->expiresAt;
    rctl_webrtc_handle_signal(reply.c_str());
    assert(lease->expiresAt == expiry);
    authorization_tick(expiry);
    assert(leasedPC->state() == rtc::PeerConnection::State::Closed);
    assert(!g_sessions.count("leased") && !g_authorizations.count("leased"));
    rctl_webrtc_handle_signal(reply.c_str());
    assert(!g_sessions.count("leased"));
    assert(!authorized(lease));
    // Unconfirmed opens disappear with their owning transport too.
    rctl_webrtc_route_session("pending", captureChallenge, &relayA);
    rctl_webrtc_handle_signal(R"({"id":"pending","kind":"open","payload":{"role":"camera","scopes":["camera"],"authorization_revision":3}})");
    assert(g_authorizations.count("pending") && !g_sessions.count("pending"));
    rctl_webrtc_route_session("a:incomplete", discard, &relayA);
    rctl_webrtc_close_owner(nullptr);
    assert(g_sessions.size() == 4);
    rctl_webrtc_close_owner(&relayA);
    assert(g_authorizations.empty());
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
    puts("WebRTC authorization lease, delayed/replayed replies and owner teardown passed (LAN and other relay preserved)");
}
