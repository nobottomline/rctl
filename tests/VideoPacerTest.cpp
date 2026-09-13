#include "net/VideoPacer.h"
#include <cassert>
#include <cstdio>
#include <stdexcept>

using namespace std::chrono_literals;

static void enqueue(rctl::VideoPacer &pacer, size_t size, unsigned value, bool key,
                    const rtc::message_callback &send) {
    auto info = std::make_shared<rtc::FrameInfo>(std::chrono::duration<double>(0));
    info->isKeyFrame = key;
    rtc::binary bytes(size, std::byte(value));
    rtc::message_vector messages{rtc::make_message(bytes.begin(), bytes.end(), info)};
    pacer.outgoing(messages, send);
    assert(messages.empty());
}

static void pacing() {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<std::chrono::steady_clock::time_point> times;
    auto rate = std::make_shared<std::atomic<int>>(1000000);
    rctl::VideoPacer pacer(std::make_shared<rtc::MediaHandler>(), rate, [] { assert(false); });
    auto send = [&](rtc::message_ptr) {
        std::lock_guard<std::mutex> lock(mutex);
        times.push_back(std::chrono::steady_clock::now());
        changed.notify_one();
    };
    for (int i = 0; i < 20; ++i) enqueue(pacer, 1024, 1, i == 0, send);
    std::unique_lock<std::mutex> lock(mutex);
    assert(changed.wait_for(lock, 3s, [&] { return times.size() == 20; }));
    assert(times.back() - times.front() >= 50ms);
}

// Hold one in-flight callback to make overflow, expiry, and stop deterministic.
static void recovery(bool expire, bool stop) {
    std::mutex mutex;
    std::condition_variable changed;
    bool entered = false, release = false;
    int requests = 0;
    std::vector<unsigned> sent;
    auto rate = std::make_shared<std::atomic<int>>(5000000);
    {
    rctl::VideoPacer pacer(std::make_shared<rtc::MediaHandler>(), rate, [&] {
        std::lock_guard<std::mutex> lock(mutex);
        requests++;
        changed.notify_all();
    });
    auto send = [&](rtc::message_ptr packet) {
        std::unique_lock<std::mutex> lock(mutex);
        const auto value = std::to_integer<unsigned>(packet->front());
        sent.push_back(value);
        if (value == 1) {
            entered = true;
            changed.notify_all();
            changed.wait(lock, [&] { return release; });
        }
        changed.notify_all();
    };
    enqueue(pacer, 1024, 1, true, send);
    {
        std::unique_lock<std::mutex> lock(mutex);
        assert(changed.wait_for(lock, 3s, [&] { return entered; }));
    }
    if (stop || expire) {
        enqueue(pacer, 1024, 2, false, send);
        if (stop) pacer.stop();
        else std::this_thread::sleep_for(550ms);
    } else {
        enqueue(pacer, 512 * 1024 + 1, 2, false, send);
        enqueue(pacer, 1024, 2, false, send);
    }
    {
        std::lock_guard<std::mutex> lock(mutex);
        release = true;
        changed.notify_all();
    }
    if (!stop) {
        {
            std::unique_lock<std::mutex> lock(mutex);
            assert(changed.wait_for(lock, 3s, [&] { return requests > 0; }));
        }
        enqueue(pacer, 1024, 2, false, send);
        enqueue(pacer, 1024, 3, true, send);
        std::unique_lock<std::mutex> lock(mutex);
        assert(changed.wait_for(lock, 3s, [&] { return sent.size() >= 2; }));
        assert((sent == std::vector<unsigned>{1, 3}));
    } else {
        enqueue(pacer, 1024, 3, true, send);
    }
    }
    if (stop) assert((sent == std::vector<unsigned>{1}));
}

static void sendFailure() {
    std::mutex mutex;
    std::condition_variable changed;
    bool recovered = false;
    std::vector<unsigned> sent;
    auto rate = std::make_shared<std::atomic<int>>(5000000);
    rctl::VideoPacer pacer(std::make_shared<rtc::MediaHandler>(), rate, [&] {
        std::lock_guard<std::mutex> lock(mutex);
        recovered = true;
        changed.notify_all();
    });
    enqueue(pacer, 1024, 1, true, [](rtc::message_ptr) {
        throw std::runtime_error("synthetic send failure");
    });
    {
        std::unique_lock<std::mutex> lock(mutex);
        assert(changed.wait_for(lock, 3s, [&] { return recovered; }));
    }
    auto send = [&](rtc::message_ptr packet) {
        std::lock_guard<std::mutex> lock(mutex);
        sent.push_back(std::to_integer<unsigned>(packet->front()));
        changed.notify_all();
    };
    enqueue(pacer, 1024, 2, false, send);
    enqueue(pacer, 1024, 3, true, send);
    std::unique_lock<std::mutex> lock(mutex);
    assert(changed.wait_for(lock, 3s, [&] { return !sent.empty(); }));
    assert((sent == std::vector<unsigned>{3}));
}

int main() {
    pacing();
    recovery(false, false);
    recovery(true, false);
    recovery(false, true);
    sendFailure();
    puts("Video pacing, whole-frame overflow recovery, expiry, send failure, and stop passed");
}
