// Phase 2.5 / Phase-4 prototype: the DEVICE side of WebRTC, developed on macOS
// against the REAL relay signaling before it's ported into rctld.
//
// Connects to the relay's /device websocket as a device, then handles the
// multiplexed `webrtc_signal` envelopes the relay forwards from a browser on
// /signal/devices/{id}:
//   relay -> device: {type:"webrtc_signal", id, kind:"open"|"offer"|"candidate"|"close", payload}
//   device -> relay: {type:"webrtc_signal", id, kind:"answer"|"candidate", payload}
// One libdatachannel PeerConnection per signaling session id. The browser is the
// offerer and creates the channels; we answer and stream synthetic frames on
// "video".
//
// Usage: relay_device <wsURL> <bearerToken> <deviceID> <deviceName>
//   e.g. relay_device ws://127.0.0.1:8099/device <enroll-or-secret> dev123 "mac sim"

#include "rtc/rtc.hpp"
#include "nlohmann/json.hpp"

#include <chrono>
#include <cstring>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

using nlohmann::json;
using namespace std::chrono;

static long long now_ms() {
    return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
}

struct Session {
    std::shared_ptr<rtc::PeerConnection> pc;
};

int main(int argc, char **argv) {
    if (argc < 5) {
        std::cerr << "usage: relay_device <wsURL> <token> <deviceID> <deviceName>\n";
        return 2;
    }
    const std::string wsURL = argv[1];
    const std::string token = argv[2];
    const std::string deviceID = argv[3];
    const std::string deviceName = argv[4];

    rtc::InitLogger(rtc::LogLevel::Warning);

    auto ws = std::make_shared<rtc::WebSocket>();
    auto sessions = std::make_shared<std::map<std::string, Session>>();
    auto mtx = std::make_shared<std::mutex>();

    // Send a webrtc_signal envelope back to the relay over the device socket.
    auto sendSignal = [ws](const std::string &id, const std::string &kind, json payload) {
        json m = {{"type", "webrtc_signal"}, {"id", id}, {"kind", kind}};
        if (!payload.is_null()) m["payload"] = payload;
        ws->send(m.dump());
    };

    auto startSession = [=](const std::string &id) {
        auto pc = std::make_shared<rtc::PeerConnection>(rtc::Configuration{});
        pc->onLocalDescription([sendSignal, id](rtc::Description desc) {
            sendSignal(id, desc.typeString(), json{{"sdp", std::string(desc)}});
        });
        pc->onLocalCandidate([sendSignal, id](rtc::Candidate cand) {
            sendSignal(id, "candidate",
                       json{{"candidate", std::string(cand)}, {"mid", cand.mid()}});
        });
        pc->onStateChange([id](rtc::PeerConnection::State s) {
            std::cout << "[device] session " << id << " pc state = " << (int)s << std::endl;
        });
        pc->onDataChannel([id](std::shared_ptr<rtc::DataChannel> dc) {
            std::cout << "[device] session " << id << " channel: " << dc->label() << std::endl;
            if (dc->label() == "control") {
                dc->onMessage([](rtc::message_variant msg) {
                    if (std::holds_alternative<std::string>(msg))
                        std::cout << "[device] control rx: " << std::get<std::string>(msg) << std::endl;
                });
            } else if (dc->label() == "video") {
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
        std::lock_guard<std::mutex> lk(*mtx);
        (*sessions)[id] = Session{pc};
    };

    auto onSignal = [=](const json &m) {
        std::string id = m.value("id", "");
        std::string kind = m.value("kind", "");
        if (id.empty()) return;
        if (kind == "open") {
            std::cout << "[device] signaling session open: " << id << std::endl;
            startSession(id);
            return;
        }
        std::shared_ptr<rtc::PeerConnection> pc;
        {
            std::lock_guard<std::mutex> lk(*mtx);
            auto it = sessions->find(id);
            if (it != sessions->end()) pc = it->second.pc;
        }
        if (kind == "close") {
            std::lock_guard<std::mutex> lk(*mtx);
            sessions->erase(id);
            return;
        }
        if (!pc) return;
        json payload = m.contains("payload") ? m["payload"] : json::object();
        if (kind == "offer" || kind == "answer") {
            pc->setRemoteDescription(rtc::Description(payload.value("sdp", ""), kind));
        } else if (kind == "candidate") {
            pc->addRemoteCandidate(
                rtc::Candidate(payload.value("candidate", ""), payload.value("mid", "")));
        }
    };

    ws->onOpen([ws, deviceID, deviceName]() {
        std::cout << "[device] relay connected — hello" << std::endl;
        ws->send(json{{"type", "hello"}, {"device_id", deviceID}, {"device_name", deviceName}}.dump());
    });
    ws->onClosed([]() { std::cout << "[device] relay socket closed" << std::endl; });
    ws->onError([](std::string e) { std::cerr << "[device] ws error: " << e << std::endl; });
    ws->onMessage([=](rtc::message_variant msg) {
        if (!std::holds_alternative<std::string>(msg)) return;
        json m;
        try { m = json::parse(std::get<std::string>(msg)); } catch (...) { return; }
        std::string type = m.value("type", "");
        if (type == "hello_ack")
            std::cout << "[device] hello_ack status=" << m.value("status", "?") << std::endl;
        else if (type == "approved")
            std::cout << "[device] approved (secret stored on a real device)" << std::endl;
        else if (type == "ping")
            ws->send(json{{"type", "pong"}}.dump());
        else if (type == "webrtc_signal")
            onSignal(m);
    });

    // The relay authenticates the device WS via a Bearer token header.
    ws->open(wsURL, {{"Authorization", "Bearer " + token}});
    std::cout << "[device] connecting to " << wsURL << std::endl;
    while (true) std::this_thread::sleep_for(seconds(1));
    return 0;
}
