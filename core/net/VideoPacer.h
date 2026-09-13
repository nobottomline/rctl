#pragma once

#include "rtc/rtc.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>

namespace rctl {

// Own complete access units around the existing RTP/NACK chain. The upstream
// packet pacer can discard the tail of an AU without retiring dependent frames.
class VideoPacer final : public rtc::MediaHandler {
    using Clock = std::chrono::steady_clock;
    struct Frame {
        rtc::message_vector packets;
        size_t next = 0;
        Clock::time_point queued;
        rtc::message_callback send;
    };
    struct State {
        std::mutex mutex;
        std::condition_variable changed;
        std::deque<Frame> frames;
        size_t bytes = 0;
        bool stopped = false;
        bool needsKeyframe = true;
        std::function<void()> requestKeyframe;
        std::shared_ptr<std::atomic<int>> bitrate;
    };
    static constexpr size_t MaxBytes = 512 * 1024;
    static constexpr size_t MaxFrames = 64;
    static constexpr auto MaxAge = std::chrono::milliseconds(500);
    static constexpr auto Tick = std::chrono::milliseconds(2);
    std::shared_ptr<rtc::MediaHandler> packetizer_;
    std::shared_ptr<State> state_;
    std::thread worker_;

    static void discard(State &s) {
        s.frames.clear();
        s.bytes = 0;
        s.needsKeyframe = true;
    }
    static void recover(const std::shared_ptr<State> &s) {
        // The bridge debounces this with ordinary PLI, outside queue locks.
        try { s->requestKeyframe(); } catch (...) {}
    }
    static void run(std::shared_ptr<State> s) {
        std::unique_lock<std::mutex> lock(s->mutex);
        auto nextTick = Clock::now();
        double budget = 0;
        while (!s->stopped) {
            s->changed.wait(lock, [&] { return s->stopped || !s->frames.empty(); });
            if (s->stopped) break;
            auto now = Clock::now();
            if (now - s->frames.front().queued > MaxAge) {
                discard(*s);
                lock.unlock(); recover(s); lock.lock();
                continue;
            }
            if (now < nextTick) {
                s->changed.wait_until(lock, nextTick, [&] { return s->stopped; });
                continue;
            }
            // Bound catch-up after scheduler stalls to one tick, not a burst of
            // accumulated credit. Include headroom for RTP and repair traffic.
            const double bytesPerTick = std::max(100000, s->bitrate->load()) * 1.5 / 8 * 0.002;
            budget = std::min(budget + bytesPerTick, bytesPerTick);
            nextTick = now + Tick;
            while (budget > 0 && !s->frames.empty() && !s->stopped) {
                if (Clock::now() - s->frames.front().queued > MaxAge) {
                    discard(*s);
                    lock.unlock(); recover(s); lock.lock();
                    break;
                }
                auto &frame = s->frames.front();
                auto packet = std::move(frame.packets[frame.next++]);
                auto send = frame.send;
                s->bytes -= packet->size();
                budget -= packet->size();
                if (frame.next == frame.packets.size()) s->frames.pop_front();
                lock.unlock();
                bool failed = false;
                try { send(std::move(packet)); } catch (...) { failed = true; }
                lock.lock();
                if (failed) {
                    discard(*s);
                    lock.unlock(); recover(s); lock.lock();
                    break;
                }
            }
        }
        discard(*s);
    }

public:
    VideoPacer(std::shared_ptr<rtc::MediaHandler> packetizer,
               std::shared_ptr<std::atomic<int>> bitrate,
               std::function<void()> requestKeyframe)
        : packetizer_(std::move(packetizer)), state_(std::make_shared<State>()) {
        state_->bitrate = std::move(bitrate);
        state_->requestKeyframe = std::move(requestKeyframe);
        worker_ = std::thread(run, state_);
    }
    ~VideoPacer() override {
        stop();
        if (worker_.get_id() == std::this_thread::get_id()) worker_.detach();
        else worker_.join();
    }
    void stop() {
        std::lock_guard<std::mutex> lock(state_->mutex);
        state_->stopped = true;
        discard(*state_);
        state_->changed.notify_all();
    }
    void media(const rtc::Description::Media &description) override {
        packetizer_->mediaChain(description);
    }
    void incoming(rtc::message_vector &messages, const rtc::message_callback &send) override {
        {
            std::lock_guard<std::mutex> lock(state_->mutex);
            if (state_->stopped) { messages.clear(); return; }
        }
        packetizer_->incomingChain(messages, send);
    }
    void outgoing(rtc::message_vector &messages, const rtc::message_callback &send) override {
        for (auto &message : messages) {
            const bool keyframe = message->frameInfo && message->frameInfo->isKeyFrame;
            {
                std::lock_guard<std::mutex> lock(state_->mutex);
                if (state_->stopped || (state_->needsKeyframe && !keyframe)) continue;
            }
            rtc::message_vector packets{std::move(message)};
            packetizer_->outgoingChain(packets, send);
            size_t bytes = 0;
            for (const auto &packet : packets) bytes += packet->size();
            if (packets.empty()) continue;
            bool request = false;
            {
                std::lock_guard<std::mutex> lock(state_->mutex);
                if (state_->stopped) continue;
                if (bytes > MaxBytes || state_->bytes + bytes > MaxBytes || state_->frames.size() >= MaxFrames) {
                    discard(*state_);
                    request = true;
                }
                if (bytes <= MaxBytes && (!state_->needsKeyframe || keyframe)) {
                    state_->frames.push_back({std::move(packets), 0, Clock::now(), send});
                    state_->bytes += bytes;
                    state_->needsKeyframe = false;
                    state_->changed.notify_one();
                }
            }
            if (request) recover(state_);
        }
        messages.clear();
    }
};

} // namespace rctl
