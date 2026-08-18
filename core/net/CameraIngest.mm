#include "net/CameraIngest.h"
#include "net/CameraProtocol.h"
#include "net/WebRTCBridge.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <notify.h>
#include <pthread.h>
#include <sys/socket.h>
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
static char g_camera_owner[128] = {0};

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
    return true;
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
    if (changed) {
        g_camera_generation++;
        g_camera_owner_epoch++;
        g_camera_last_frame_ms = 0;
        g_camera_owner[0] = 0;
    }
    uint64_t generation = g_camera_generation;
    pthread_mutex_unlock(&g_camera_lock);

    if (changed) notify_post("com.greatlove.rctl.cam.sync");
    return generation;
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

    uint64_t age = last ? camera_now_ms() - last : 0;
    const char *state = !enabled ? "off" : (last && age < 2500 ? "live" : "waiting_for_app");
    char *json = (char *)malloc(512);
    if (!json) return NULL;
    snprintf(json, 512,
             "{\"enabled\":%s,\"state\":\"%s\",\"position\":\"%s\",\"generation\":%llu,"
             "\"fps\":%d,\"bitrate\":%d,\"owner\":\"%s\",\"frames\":%llu,\"bytes\":%llu,\"last_frame_ms\":%llu}",
             enabled ? "true" : "false", state, position == 2 ? "front" : "back",
             (unsigned long long)generation, fps, bitrate, owner,
             (unsigned long long)frames, (unsigned long long)bytes,
             (unsigned long long)(last ? age : 0));
    return json;
}
