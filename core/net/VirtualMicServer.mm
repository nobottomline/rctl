#import "net/VirtualMicServer.h"

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <atomic>
#import <condition_variable>
#import <deque>
#import <mutex>
#import <netinet/in.h>
#import <pthread.h>
#import <sys/socket.h>
#import <unistd.h>
#import <vector>

static const uint16_t kVirtualMicPort = 8082;
static const size_t kMaxQueuedFrames = 8;
static const size_t kMaxClients = 8;

static std::atomic<int> g_route{RCTL_TALK_SPEAKER};
static std::mutex g_clients_mutex;
static std::vector<int> g_clients;
static std::mutex g_queue_mutex;
static std::condition_variable g_queue_cond;
static std::deque<std::vector<int16_t>> g_queue;

static bool write_all(int fd, const void *buffer, size_t length) {
    const uint8_t *bytes = static_cast<const uint8_t *>(buffer);
    while (length) {
        ssize_t written = send(fd, bytes, length, 0);
        if (written <= 0) return false;
        bytes += written;
        length -= static_cast<size_t>(written);
    }
    return true;
}

static void broadcast(const std::vector<int16_t> &frame) {
    uint32_t bytes = static_cast<uint32_t>(frame.size() * sizeof(int16_t));
    uint32_t header = htonl(bytes);
    std::lock_guard<std::mutex> lock(g_clients_mutex);
    for (auto it = g_clients.begin(); it != g_clients.end();) {
        if (!write_all(*it, &header, sizeof(header)) || !write_all(*it, frame.data(), bytes)) {
            close(*it);
            it = g_clients.erase(it);
        } else {
            ++it;
        }
    }
}

static void *sender_main(void *) {
    pthread_setname_np("com.greatlove.rctl.vmic.send");
    for (;;) {
        std::vector<int16_t> frame;
        {
            std::unique_lock<std::mutex> lock(g_queue_mutex);
            g_queue_cond.wait(lock, [] { return !g_queue.empty(); });
            frame = std::move(g_queue.front());
            g_queue.pop_front();
        }
        if (!frame.empty()) broadcast(frame);
    }
    return nullptr;
}

static void *accept_main(void *rawListener) {
    pthread_setname_np("com.greatlove.rctl.vmic.accept");
    int listener = static_cast<int>(reinterpret_cast<intptr_t>(rawListener));
    int one = 1;
    for (;;) {
        int client = accept(listener, nullptr, nullptr);
        if (client < 0) { usleep(100000); continue; }
#ifdef SO_NOSIGPIPE
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        timeval timeout = {.tv_sec = 0, .tv_usec = 100000};
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        std::lock_guard<std::mutex> lock(g_clients_mutex);
        if (g_clients.size() >= kMaxClients) close(client);
        else g_clients.push_back(client);
    }
    return nullptr;
}

int rctl_vmic_server_start(void) {
    static std::once_flag once;
    static int result = 0;
    std::call_once(once, [] {
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        if (listener < 0) return;
        int one = 1;
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        sockaddr_in address = {};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        address.sin_port = htons(kVirtualMicPort);
        if (bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 ||
            listen(listener, 8) != 0) {
            close(listener);
            return;
        }
        pthread_t acceptThread;
        pthread_t senderThread;
        if (pthread_create(&senderThread, nullptr, sender_main, nullptr) != 0) {
            close(listener);
            return;
        }
        if (pthread_create(&acceptThread, nullptr, accept_main,
                           reinterpret_cast<void *>(static_cast<intptr_t>(listener))) != 0) {
            close(listener);
            pthread_cancel(senderThread);
            pthread_join(senderThread, nullptr);
            return;
        }
        pthread_detach(acceptThread);
        pthread_detach(senderThread);
        result = 1;
    });
    return result;
}

void rctl_vmic_push(const int16_t *pcm, int frames) {
    if (!pcm || frames <= 0 || g_route.load(std::memory_order_relaxed) == RCTL_TALK_SPEAKER) return;
    std::vector<int16_t> copy(pcm, pcm + frames);
    {
        std::lock_guard<std::mutex> lock(g_queue_mutex);
        while (g_queue.size() >= kMaxQueuedFrames) g_queue.pop_front();
        g_queue.push_back(std::move(copy));
    }
    g_queue_cond.notify_one();
}

void rctl_vmic_set_route(int route) {
    if (route < RCTL_TALK_SPEAKER || route > RCTL_TALK_BOTH) route = RCTL_TALK_SPEAKER;
    g_route.store(route, std::memory_order_relaxed);
}

int rctl_vmic_route(void) {
    return g_route.load(std::memory_order_relaxed);
}
