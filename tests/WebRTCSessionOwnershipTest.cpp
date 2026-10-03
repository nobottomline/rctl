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
static std::string lastSignalKind;
static void captureChallenge(void *, const char *raw) {
    auto message = json::parse(raw);
    lastSignalKind = message.value("kind", std::string());
    if (message["kind"] == "authorization_challenge") challengeNonce = message["payload"]["nonce"].get<std::string>();
}

static bool endConfirmed = true;
static unsigned fencedEnds = 0;
static bool guestEnd(const char *, bool wait) { if (wait) ++fencedEnds; return !wait || endConfirmed; }
static void testGuestPolicyAndRetirement() {
    int owner;
    // The existing raw owner API accepts arbitrary integer fields. Shadow state
    // used to avoid guest/owner conflicts must not grow from discarded IDs.
    rctl_webrtc_owner_input_event(0, 0, -1, 0);
    rctl_webrtc_owner_input_event(0, 0, 11, 0);
    rctl_webrtc_owner_input_event(1, 7, 1000000, 1);
    rctl_webrtc_owner_input_event(1, 12, 1000000, 1);
    assert(g_ownerContacts.empty() && g_ownerKeys.empty());
    rctl_webrtc_owner_input_event(0, 0, 0, 0);
    rctl_webrtc_owner_input_event(1, 7, 4, 1);
    assert(g_ownerContacts.size() == 1 && g_ownerKeys.size() == 1);
    rctl_webrtc_owner_input_event(0, 2, 0, 0);
    rctl_webrtc_owner_input_event(1, 7, 4, 0);
    assert(g_ownerContacts.empty() && g_ownerKeys.empty());
    rctl_webrtc_set_guest_input_cb(nullptr, guestEnd);
    for (bool confirm : {true, false}) {
        const std::string id = confirm ? "guest-confirmed" : "guest-unconfirmed";
        rctl_webrtc_route_session(id.c_str(), captureChallenge, &owner);
        const auto open = json{{"id", id}, {"kind", "open"}, {"payload", {
            {"access_mode", "guest-v1"}, {"allow_direct", true}, {"role", "screen"},
            {"authorization_revision", 1}, {"permissions", {"screen.view", "input.keyboard"}}, {"ice", json::array()}
        }}}.dump();
        rctl_webrtc_handle_signal(open.c_str());
        assert(!g_sessions.count(id) && g_authorizations.count(id));
        auto renew = json{{"id", id}, {"kind", "authorization_renew"}, {"payload", {
            {"nonce", challengeNonce}, {"authorization_revision", 1}
        }}};
        // Guest renewals cannot inherit the native controller's default budget.
        rctl_webrtc_handle_signal(renew.dump().c_str());
        assert(!g_sessions.count(id));
        renew["payload"]["remaining_ms"] = 20000;
        rctl_webrtc_handle_signal(renew.dump().c_str());
        auto session = g_sessions.at(id);
        assert(session->track && session->control && session->stateDc);
        assert(!session->audioDc && !session->roomMic && !session->micIn && !session->filesDc && !session->pointer);
        assert(session->guestInput && session->lease->authorized(authorization_now()));
        assert(session->guestInput->key(7, 4, 1, true, false));
        g_guestInputOwner = id;
        endConfirmed = confirm;
        rctl_webrtc_handle_signal(json{{"id", id}, {"kind", "close"}}.dump().c_str());
        assert(!g_sessions.count(id) && !g_authorizations.count(id));
        assert(session->pc->state() == rtc::PeerConnection::State::Closed);
        assert(session->guestInput->disabled && session->guestInput->keys.empty() && g_guestInputOwner.empty());
        assert(lastSignalKind == (confirm ? "closed" : "close"));
        if (!confirm) {
            assert(g_guestRetiring.count(id));
            rctl_webrtc_handle_signal(json{{"id", id}, {"kind", "close"}}.dump().c_str());
            assert(lastSignalKind == "close" && g_guestRetiring.count(id));
            endConfirmed = true;
            rctl_webrtc_handle_signal(json{{"id", id}, {"kind", "close"}}.dump().c_str());
            assert(lastSignalKind == "closed" && !g_guestRetiring.count(id));
        }
        rctl_webrtc_unroute_session(id.c_str());
    }
    assert(fencedEnds == 6);
    rctl_webrtc_set_guest_input_cb(nullptr, nullptr);
    rctl_webrtc_route_session("bad-guest", captureChallenge, &owner);
    rctl_webrtc_handle_signal(R"({"id":"bad-guest","kind":"open","payload":{"role":"screen","access_mode":"guest-v1","allow_direct":false,"authorization_revision":1,"permissions":["screen.view","device.control"]}})");
    assert(!g_sessions.count("bad-guest") && !g_authorizations.count("bad-guest"));
    rctl_webrtc_unroute_session("bad-guest");
    auto ownerSession = std::make_shared<Session>();
    ownerSession->pc = std::make_shared<rtc::PeerConnection>();
    g_sessions["owner-survives"] = ownerSession;
    rctl_webrtc_route_session("owner-survives", discard, &owner);
    rctl_webrtc_route_session("guest-sb-loss", captureChallenge, &owner);
    rctl_webrtc_handle_signal(R"({"id":"guest-sb-loss","kind":"open","payload":{"role":"screen","access_mode":"guest-v1","allow_direct":true,"authorization_revision":1,"permissions":["screen.view"],"ice":[]}})");
    rctl_webrtc_handle_signal(json{{"id","guest-sb-loss"},{"kind","authorization_renew"},{"payload",{{"nonce",challengeNonce},{"authorization_revision",1},{"remaining_ms",20000}}}}.dump().c_str());
    auto view = g_sessions.at("guest-sb-loss");
    assert(view->track && !view->control && !view->guestInput);
    rctl_webrtc_guest_input_unavailable();
    assert(!g_sessions.count("guest-sb-loss") && !g_authorizations.count("guest-sb-loss"));
    assert(view->pc->state() == rtc::PeerConnection::State::Closed);
    assert(ownerSession->pc->state() != rtc::PeerConnection::State::Closed);
    rctl_webrtc_close_owner(&owner);
    puts("Guest device policy, renewal budgets, channel isolation and confirmed/unconfirmed retirement passed");
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
    testGuestPolicyAndRetirement();
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
