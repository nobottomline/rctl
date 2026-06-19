// R1 spike: send H.264 over a real WebRTC RTP media track (not a DataChannel),
// so the browser renders it natively in <video> (jitter buffer, NACK, decode).
// This is the transport we want for rctld's video. The native peer offers a
// send-only H.264 track once the browser is ready, then streams sample.h264.
//
// VALIDATED on macOS (browser <-> native): framesDecoded grows, pliCount=0,
// framesDropped=0 -- native jitter buffer + NACK + hardware decode in <video>.
//
// Build:  clang++ -std=c++17 -O2 rtp_sender.cpp -I.lib/libdatachannel/include \
//           -I.lib/libdatachannel/deps/json/single_include \
//           -L.lib/libdatachannel/build -ldatachannel -Wl,-rpath,<abs build dir> -o rtp_sender
// Run:    go run experiments/webrtc-spike/signal_server.go   (then open /rtp.html)
//         experiments/webrtc-spike/rtp_sender ws://localhost:8099/ws?role=native \
//           experiments/webrtc-spike/rtp/sample.h264
// Regenerate the (gitignored) test asset:
//   ffmpeg -f lavfi -i "testsrc=size=480x320:rate=30" -t 12 -c:v libx264 \
//     -profile:v baseline -pix_fmt yuv420p -g 30 -x264-params "repeat-headers=1" \
//     -bsf:v dump_extra -f h264 rtp/sample.h264

#include "rtc/rtc.hpp"
#include "nlohmann/json.hpp"

#include <chrono>
#include <fstream>
#include <iostream>
#include <iterator>
#include <memory>
#include <thread>
#include <vector>

using namespace std::chrono;
using nlohmann::json;
using rtc::binary;

// Split an Annex-B stream into access units (group NALs, closing on each VCL NAL).
static std::vector<binary> load_aus(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    std::vector<uint8_t> d((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    std::vector<size_t> starts;
    for (size_t i = 0; i + 3 < d.size();) {
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 0 && d[i + 3] == 1) { starts.push_back(i); i += 4; }
        else if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) { starts.push_back(i); i += 3; }
        else i++;
    }
    starts.push_back(d.size());
    std::vector<binary> aus;
    size_t auStart = starts.empty() ? 0 : starts[0];
    for (size_t k = 0; k + 1 < starts.size(); k++) {
        size_t s = starts[k], e = starts[k + 1];
        size_t hdr = (d[s + 2] == 1) ? 3 : 4;
        uint8_t t = d[s + hdr] & 0x1f;
        if (t >= 1 && t <= 5) { // VCL slice closes the access unit
            aus.emplace_back(reinterpret_cast<const std::byte *>(d.data() + auStart),
                             reinterpret_cast<const std::byte *>(d.data() + e));
            auStart = e;
        }
    }
    return aus;
}

int main(int argc, char **argv) {
    const std::string signalUrl = argc > 1 ? argv[1] : "ws://localhost:8099/ws?role=native";
    const std::string h264Path = argc > 2 ? argv[2] : "experiments/webrtc-spike/rtp/sample.h264";

    rtc::InitLogger(rtc::LogLevel::Warning);
    auto aus = load_aus(h264Path);
    std::cout << "[rtp] loaded " << aus.size() << " access units" << std::endl;

    auto pc = std::make_shared<rtc::PeerConnection>(rtc::Configuration{});
    auto ws = std::make_shared<rtc::WebSocket>();
    std::shared_ptr<rtc::Track> track;

    pc->onLocalDescription([ws](rtc::Description d) {
        ws->send(json{{"type", d.typeString()}, {"sdp", std::string(d)}}.dump());
    });
    pc->onLocalCandidate([ws](rtc::Candidate c) {
        ws->send(json{{"type", "candidate"}, {"candidate", std::string(c)}, {"mid", c.mid()}}.dump());
    });
    pc->onStateChange([](rtc::PeerConnection::State s) {
        std::cout << "[rtp] pc state " << (int)s << std::endl;
    });

    auto offer = [&]() {
        const rtc::SSRC ssrc = 42;
        rtc::Description::Video media("video", rtc::Description::Direction::SendOnly);
        media.addH264Codec(96);
        media.addSSRC(ssrc, "video-send");
        track = pc->addTrack(media);

        auto rtpConfig = std::make_shared<rtc::RtpPacketizationConfig>(
            ssrc, "video-send", 96, rtc::H264RtpPacketizer::ClockRate);
        // sample.h264 mixes 3- and 4-byte start codes (SPS/PPS use 4, SEI/IDR use
        // 3), so the packetizer must auto-detect either width -- LongStartSequence
        // mis-parses the keyframe's NALs and the browser can't assemble a frame.
        auto packetizer = std::make_shared<rtc::H264RtpPacketizer>(
            rtc::NalUnit::Separator::StartSequence, rtpConfig);
        packetizer->addToChain(std::make_shared<rtc::RtcpSrReporter>(rtpConfig));
        packetizer->addToChain(std::make_shared<rtc::RtcpNackResponder>());
        track->setMediaHandler(packetizer);

        track->onOpen([track = track, aus]() {
            std::cout << "[rtp] track open — streaming ~30fps" << std::endl;
            std::thread([track, aus]() {
                size_t i = 0;
                while (track->isOpen()) {
                    auto &au = aus[i % aus.size()];
                    double tsec = (double)i / 30.0;
                    try {
                        track->sendFrame(au, duration<double>(tsec));
                    } catch (const std::exception &e) {
                        std::cerr << "[rtp] send err: " << e.what() << std::endl;
                    }
                    i++;
                    std::this_thread::sleep_for(milliseconds(33));
                }
            }).detach();
        });

        pc->setLocalDescription();
    };

    ws->onMessage([&, pc](rtc::message_variant msg) {
        if (!std::holds_alternative<std::string>(msg)) return;
        try {
            json m = json::parse(std::get<std::string>(msg));
            std::string type = m.value("type", "");
            if (type == "start") {
                std::cout << "[rtp] browser ready — offering video track" << std::endl;
                offer();
            } else if (type == "answer" || type == "offer") {
                pc->setRemoteDescription(rtc::Description(m["sdp"].get<std::string>(), type));
            } else if (type == "candidate") {
                pc->addRemoteCandidate(rtc::Candidate(m["candidate"].get<std::string>(), m.value("mid", "")));
            }
        } catch (const std::exception &e) {
            std::cerr << "[rtp] signaling err: " << e.what() << std::endl;
        }
    });
    ws->onOpen([]() { std::cout << "[rtp] signaling connected — waiting for browser" << std::endl; });
    ws->open(signalUrl);

    std::cout << "[rtp] running" << std::endl;
    while (true) std::this_thread::sleep_for(seconds(1));
    return 0;
}
