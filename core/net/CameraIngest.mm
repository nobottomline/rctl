#include "net/CameraIngest.h"
#include "net/CameraProtocol.h"
#include "net/MpegTsRecorder.h"
#include "net/WebRTCBridge.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <notify.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t g_camera_lock = PTHREAD_MUTEX_INITIALIZER;
static bool g_camera_enabled = false;
static int g_camera_position = 1;
static int g_camera_fps = 10;
static int g_camera_bitrate = 1500000;
static uint64_t g_camera_generation = 1;
static uint64_t g_camera_owner_epoch = 0;
static uint64_t g_camera_frames = 0;
static uint64_t g_camera_bytes = 0;
static uint64_t g_camera_last_frame_ms = 0;
static uint64_t g_camera_lease_deadline_ms = 0;
static char g_camera_owner[128] = {0};
static void (*g_camera_expired_cb)(void) = NULL;
static pthread_mutex_t g_record_lock = PTHREAD_MUTEX_INITIALIZER;
static rctl_ts_recorder *g_camera_recorder = NULL;
static uint64_t g_record_last_bytes = 0;
static uint64_t g_record_last_ms = 0;

static uint64_t camera_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static uint64_t camera_hton64(uint64_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return ((uint64_t)htonl((uint32_t)(value & 0xffffffffULL)) << 32) |
           htonl((uint32_t)(value >> 32));
#else
    return value;
#endif
}

static uint64_t camera_ntoh64(uint64_t value) { return camera_hton64(value); }

static bool camera_read_full(int fd, void *buffer, size_t length) {
    uint8_t *out = (uint8_t *)buffer;
    while (length > 0) {
        ssize_t count = read(fd, out, length);
        if (count <= 0) return false;
        out += (size_t)count;
        length -= (size_t)count;
    }
    return true;
}

static void camera_sanitize_owner(char *dst, size_t dst_len, const uint8_t *src, size_t src_len) {
    if (!dst_len) return;
    size_t n = src_len < dst_len - 1 ? src_len : dst_len - 1;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = src[i];
        dst[i] = (isalnum(c) || c == '.' || c == '-' || c == '_') ? (char)c : '_';
    }
    dst[n] = 0;
}

static void *camera_client_main(void *raw_fd) {
    int fd = (int)(intptr_t)raw_fd;
    uint64_t epoch = 0;
    uint64_t generation = 0;
    bool greeted = false;

    for (;;) {
        rctl_camera_header header;
        if (!camera_read_full(fd, &header, sizeof(header))) break;
        if (ntohl(header.magic_be) != RCTL_CAMERA_MAGIC ||
            header.version != RCTL_CAMERA_VERSION) break;
        uint32_t length = ntohl(header.length_be);
        uint16_t flags = ntohs(header.flags_be);
        uint64_t pts_us = camera_ntoh64(header.pts_us_be);
        uint64_t message_generation = camera_ntoh64(header.generation_be);
        if (length > RCTL_CAMERA_MAX_PAYLOAD) break;
        uint8_t *payload = length ? (uint8_t *)malloc(length) : NULL;
        if (length && (!payload || !camera_read_full(fd, payload, length))) {
            free(payload);
            break;
        }

        if (header.type == RCTL_CAMERA_MSG_HELLO && !greeted) {
            pthread_mutex_lock(&g_camera_lock);
            if (g_camera_enabled && message_generation == g_camera_generation) {
                generation = message_generation;
                epoch = ++g_camera_owner_epoch;
                camera_sanitize_owner(g_camera_owner, sizeof(g_camera_owner), payload, length);
                g_camera_last_frame_ms = 0;
                greeted = true;
            }
            pthread_mutex_unlock(&g_camera_lock);
        } else if (header.type == RCTL_CAMERA_MSG_VIDEO && greeted && length > 0) {
            bool current = false;
            pthread_mutex_lock(&g_camera_lock);
            current = g_camera_enabled && generation == g_camera_generation &&
                      epoch == g_camera_owner_epoch;
            if (current) {
                g_camera_frames++;
                g_camera_bytes += length;
                g_camera_last_frame_ms = camera_now_ms();
            }
            pthread_mutex_unlock(&g_camera_lock);
            if (current)
                rctl_webrtc_push_camera_au(payload, length,
                    (flags & RCTL_CAMERA_FLAG_KEYFRAME) != 0, pts_us);
            if (current) {
                pthread_mutex_lock(&g_record_lock);
                if (g_camera_recorder &&
                    !rctl_ts_recorder_write(g_camera_recorder, payload, length,
                        (flags & RCTL_CAMERA_FLAG_KEYFRAME) != 0, pts_us)) {
                    g_record_last_bytes = rctl_ts_recorder_bytes(g_camera_recorder);
                    g_record_last_ms = rctl_ts_recorder_duration_ms(g_camera_recorder);
                    rctl_ts_recorder_close(g_camera_recorder);
                    g_camera_recorder = NULL;
                }
                pthread_mutex_unlock(&g_record_lock);
            }
        }
        free(payload);
        if (!greeted) break;
    }

    close(fd);
    return NULL;
}

static void *camera_listener_main(void *raw_listener) {
    int listener = (int)(intptr_t)raw_listener;
    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) continue;
        pthread_t thread;
        if (pthread_create(&thread, NULL, camera_client_main, (void *)(intptr_t)fd) == 0)
            pthread_detach(thread);
        else
            close(fd);
    }
}

static void *camera_watchdog_main(void *) {
    for (;;) {
        sleep(2);
        bool expired = false;
        int position = 1, fps = 10, bitrate = 1500000;
        void (*expired_cb)(void) = NULL;
        pthread_mutex_lock(&g_camera_lock);
        uint64_t now = camera_now_ms();
        expired = g_camera_enabled && g_camera_lease_deadline_ms && now > g_camera_lease_deadline_ms;
        position = g_camera_position;
        fps = g_camera_fps;
        bitrate = g_camera_bitrate;
        expired_cb = g_camera_expired_cb;
        pthread_mutex_unlock(&g_camera_lock);
        if (expired) {
            rctl_camera_set_enabled(false, position, fps, bitrate);
            if (expired_cb) expired_cb();
        }
    }
}

bool rctl_camera_ingest_start(void) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return false;
    int one = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(RCTL_CAMERA_INGEST_PORT);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(listener, 4) != 0) {
        close(listener);
        return false;
    }
    pthread_t thread;
    if (pthread_create(&thread, NULL, camera_listener_main, (void *)(intptr_t)listener) != 0) {
        close(listener);
        return false;
    }
    pthread_detach(thread);
    pthread_t watchdog;
    if (pthread_create(&watchdog, NULL, camera_watchdog_main, NULL) == 0)
        pthread_detach(watchdog);
    return true;
}

void rctl_camera_set_expired_cb(void (*callback)(void)) {
    pthread_mutex_lock(&g_camera_lock);
    g_camera_expired_cb = callback;
    pthread_mutex_unlock(&g_camera_lock);
}

uint64_t rctl_camera_set_enabled(bool enabled, int position, int fps, int bitrate_bps) {
    if (position != 2) position = 1;
    if (fps < 5) fps = 5;
    if (fps > 30) fps = 30;
    if (bitrate_bps < 300000) bitrate_bps = 300000;
    if (bitrate_bps > 5000000) bitrate_bps = 5000000;

    pthread_mutex_lock(&g_camera_lock);
    bool changed = enabled != g_camera_enabled || position != g_camera_position ||
                   fps != g_camera_fps || bitrate_bps != g_camera_bitrate;
    g_camera_enabled = enabled;
    g_camera_position = position;
    g_camera_fps = fps;
    g_camera_bitrate = bitrate_bps;
    g_camera_lease_deadline_ms = enabled ? camera_now_ms() + 30000 : 0;
    if (changed) {
        g_camera_generation++;
        g_camera_owner_epoch++;
        g_camera_last_frame_ms = 0;
        g_camera_owner[0] = 0;
    }
    uint64_t generation = g_camera_generation;
    pthread_mutex_unlock(&g_camera_lock);

    if (changed) notify_post("com.greatlove.rctl.cam.sync");
    if (!enabled) rctl_camera_record_stop();
    return generation;
}

void rctl_camera_renew_lease(void) {
    pthread_mutex_lock(&g_camera_lock);
    if (g_camera_enabled) g_camera_lease_deadline_ms = camera_now_ms() + 30000;
    pthread_mutex_unlock(&g_camera_lock);
}

bool rctl_camera_is_enabled(void) {
    pthread_mutex_lock(&g_camera_lock);
    bool enabled = g_camera_enabled;
    pthread_mutex_unlock(&g_camera_lock);
    return enabled;
}

char *rctl_camera_agent_state_json(void) {
    pthread_mutex_lock(&g_camera_lock);
    bool enabled = g_camera_enabled;
    int position = g_camera_position;
    int fps = g_camera_fps;
    int bitrate = g_camera_bitrate;
    uint64_t generation = g_camera_generation;
    pthread_mutex_unlock(&g_camera_lock);
    char *json = (char *)malloc(256);
    if (!json) return NULL;
    snprintf(json, 256,
             "{\"enabled\":%s,\"position\":\"%s\",\"generation\":%llu,\"fps\":%d,\"bitrate\":%d}",
             enabled ? "true" : "false", position == 2 ? "front" : "back",
             (unsigned long long)generation, fps, bitrate);
    return json;
}

char *rctl_camera_status_json(void) {
    pthread_mutex_lock(&g_camera_lock);
    bool enabled = g_camera_enabled;
    int position = g_camera_position;
    int fps = g_camera_fps;
    int bitrate = g_camera_bitrate;
    uint64_t generation = g_camera_generation;
    uint64_t frames = g_camera_frames;
    uint64_t bytes = g_camera_bytes;
    uint64_t last = g_camera_last_frame_ms;
    char owner[sizeof(g_camera_owner)];
    memcpy(owner, g_camera_owner, sizeof(owner));
    pthread_mutex_unlock(&g_camera_lock);

    pthread_mutex_lock(&g_record_lock);
    bool recording = g_camera_recorder != NULL;
    uint64_t record_bytes = rctl_ts_recorder_bytes(g_camera_recorder);
    uint64_t record_ms = rctl_ts_recorder_duration_ms(g_camera_recorder);
    if (!recording) {
        record_bytes = g_record_last_bytes;
        record_ms = g_record_last_ms;
    }
    pthread_mutex_unlock(&g_record_lock);
    if (!recording) {
        struct stat st;
        if (stat(RCTL_CAMERA_RECORD_PATH, &st) == 0) record_bytes = (uint64_t)st.st_size;
    }

    uint64_t age = last ? camera_now_ms() - last : 0;
    const char *state = !enabled ? "off" : (last && age < 2500 ? "live" : "waiting_for_app");
    char *json = (char *)malloc(768);
    if (!json) return NULL;
    snprintf(json, 768,
             "{\"enabled\":%s,\"state\":\"%s\",\"position\":\"%s\",\"generation\":%llu,"
             "\"fps\":%d,\"bitrate\":%d,\"owner\":\"%s\",\"frames\":%llu,\"bytes\":%llu,\"last_frame_ms\":%llu,"
             "\"recording\":%s,\"record_bytes\":%llu,\"record_ms\":%llu,\"record_path\":\"%s\"}",
             enabled ? "true" : "false", state, position == 2 ? "front" : "back",
             (unsigned long long)generation, fps, bitrate, owner,
             (unsigned long long)frames, (unsigned long long)bytes,
             (unsigned long long)(last ? age : 0), recording ? "true" : "false",
             (unsigned long long)record_bytes, (unsigned long long)record_ms,
             RCTL_CAMERA_RECORD_PATH);
    return json;
}

bool rctl_camera_record_start(void) {
    if (!rctl_camera_is_enabled()) return false;
    mkdir("/var/mobile/Library/Caches/com.greatlove.rctl", 0755);
    pthread_mutex_lock(&g_record_lock);
    if (g_camera_recorder) rctl_ts_recorder_close(g_camera_recorder);
    g_camera_recorder = rctl_ts_recorder_open(RCTL_CAMERA_RECORD_PATH);
    bool ok = g_camera_recorder != NULL;
    if (ok) {
        g_record_last_bytes = 0;
        g_record_last_ms = 0;
    }
    pthread_mutex_unlock(&g_record_lock);
    return ok;
}

void rctl_camera_record_stop(void) {
    pthread_mutex_lock(&g_record_lock);
    rctl_ts_recorder *recorder = g_camera_recorder;
    g_camera_recorder = NULL;
    if (recorder) {
        g_record_last_bytes = rctl_ts_recorder_bytes(recorder);
        g_record_last_ms = rctl_ts_recorder_duration_ms(recorder);
    }
    pthread_mutex_unlock(&g_record_lock);
    rctl_ts_recorder_close(recorder);
}

void rctl_camera_record_discard(void) {
    rctl_camera_record_stop();
    unlink(RCTL_CAMERA_RECORD_PATH);
    pthread_mutex_lock(&g_record_lock);
    g_record_last_bytes = 0;
    g_record_last_ms = 0;
    pthread_mutex_unlock(&g_record_lock);
}
