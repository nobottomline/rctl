// Spike: stand-in for rctld's device side.
//
// ANSWERER. Waits for the browser's offer, accepts the UNRELIABLE/UNORDERED
// "video" DataChannel and reliable "control" channel it creates, and streams
// synthetic timestamped frames on "video" so the browser can measure one-way
// latency (same machine => shared wall clock).
//
// (The browser offers so that the offer is generated only once the browser is
// actually present — no signaling buffering needed for the spike.)

#include "rtc/rtc.hpp"
#include "nlohmann/json.hpp"

#include <chrono>
#include <cstring>
#include <iostream>
#include <memory>
#include <thread>
#include <vector>

using nlohmann::json;
using namespace std::chrono;

static long long now_ms() {
    return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
}

int main(int argc, char **argv) {
    const std::string signalUrl =
        argc > 1 ? argv[1] : "ws://localhost:8099/ws?role=native";

    rtc::InitLogger(rtc::LogLevel::Warning);
    rtc::Configuration config; // localhost: host candidates only

    auto pc = std::make_shared<rtc::PeerConnection>(config);
    auto ws = std::make_shared<rtc::WebSocket>();

    pc->onLocalDescription([ws](rtc::Description desc) {
        json m = {{"type", desc.typeString()}, {"sdp", std::string(desc)}};
        ws->send(m.dump());
    });
    pc->onLocalCandidate([ws](rtc::Candidate cand) {
        ws->send(json{{"type", "candidate"},
                      {"candidate", std::string(cand)},
                      {"mid", cand.mid()}}
                     .dump());
    });
    pc->onStateChange([](rtc::PeerConnection::State s) {
        std::cout << "[native] pc state = " << (int)s << std::endl;
    });

    // Accept the channels the browser creates.
    pc->onDataChannel([](std::shared_ptr<rtc::DataChannel> dc) {
        std::cout << "[native] data channel: " << dc->label() << std::endl;
        if (dc->label() == "control") {
            dc->onMessage([](rtc::message_variant msg) {
                if (std::holds_alternative<std::string>(msg))
                    std::cout << "[native] control rx: " << std::get<std::string>(msg) << std::endl;
            });
        } else if (dc->label() == "video") {
            std::cout << "[native] video open — streaming ~60fps" << std::endl;
            std::thread([dc]() {
                uint32_t seq = 0;
                while (dc->isOpen()) {
                    // frame: [seq u32 LE][send_ms i64 LE][type u8][payload…]
                    std::vector<std::byte> buf(13 + 1500);
                    uint32_t s = seq++;
                    long long t = now_ms();
                    uint8_t type = (s % 60 == 0) ? 1 : 0;
                    std::memcpy(buf.data(), &s, 4);
                    std::memcpy(buf.data() + 4, &t, 8);
                    std::memcpy(buf.data() + 12, &type, 1);
                    try {
                        dc->send(buf);
                    } catch (...) {
                        break;
                    }
                    std::this_thread::sleep_for(milliseconds(16));
                }
                std::cout << "[native] streaming stopped" << std::endl;
            }).detach();
        }
    });

    ws->onMessage([pc](rtc::message_variant msg) {
        if (!std::holds_alternative<std::string>(msg)) return;
        try {
            json m = json::parse(std::get<std::string>(msg));
            std::string type = m.value("type", "");
            if (type == "offer" || type == "answer") {
                pc->setRemoteDescription(rtc::Description(m["sdp"].get<std::string>(), type));
            } else if (type == "candidate") {
                pc->addRemoteCandidate(
                    rtc::Candidate(m["candidate"].get<std::string>(), m.value("mid", "")));
            }
        } catch (const std::exception &e) {
            std::cerr << "[native] signaling parse error: " << e.what() << std::endl;
        }
    });

    ws->onOpen([]() { std::cout << "[native] signaling connected — waiting for offer" << std::endl; });

    ws->open(signalUrl);
    std::cout << "[native] running (" << signalUrl << "). Ctrl-C to quit." << std::endl;
    while (true) std::this_thread::sleep_for(seconds(1));
    return 0;
}
