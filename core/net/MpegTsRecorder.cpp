#include "net/MpegTsRecorder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <vector>

static const uint16_t kPmtPid = 0x100;
static const uint16_t kVideoPid = 0x101;

struct rctl_ts_recorder {
    FILE *file = nullptr;
    uint8_t pat_cc = 0;
    uint8_t pmt_cc = 0;
    uint8_t video_cc = 0;
    uint64_t first_pts_us = 0;
    uint64_t last_pts_90k = 0;
    uint64_t bytes = 0;
    bool started = false;
};

static uint32_t mpeg_crc32(const uint8_t *data, size_t length) {
    uint32_t crc = 0xffffffffU;
    for (size_t i = 0; i < length; i++) {
        crc ^= (uint32_t)data[i] << 24;
        for (int bit = 0; bit < 8; bit++)
            crc = (crc & 0x80000000U) ? (crc << 1) ^ 0x04c11db7U : crc << 1;
    }
    return crc;
}

static bool write_packet(rctl_ts_recorder *recorder, const uint8_t packet[188]) {
    if (!recorder || !recorder->file || fwrite(packet, 1, 188, recorder->file) != 188) return false;
    recorder->bytes += 188;
    return true;
}

static bool write_psi(rctl_ts_recorder *recorder, uint16_t pid, uint8_t *cc,
                      const uint8_t *section, size_t section_length) {
    if (section_length + 5 > 188) return false;
    uint8_t packet[188];
    memset(packet, 0xff, sizeof(packet));
    packet[0] = 0x47;
    packet[1] = 0x40 | (uint8_t)(pid >> 8);
    packet[2] = (uint8_t)pid;
    packet[3] = 0x10 | ((*cc)++ & 0x0f);
    packet[4] = 0;
    memcpy(packet + 5, section, section_length);
    return write_packet(recorder, packet);
}

static bool write_tables(rctl_ts_recorder *recorder) {
    uint8_t pat[16] = {
        0x00, 0xb0, 0x0d, 0x00, 0x01, 0xc1, 0x00, 0x00,
        0x00, 0x01, (uint8_t)(0xe0 | (kPmtPid >> 8)), (uint8_t)kPmtPid,
        0, 0, 0, 0
    };
    uint32_t pat_crc = mpeg_crc32(pat, 12);
    pat[12] = (uint8_t)(pat_crc >> 24); pat[13] = (uint8_t)(pat_crc >> 16);
    pat[14] = (uint8_t)(pat_crc >> 8);  pat[15] = (uint8_t)pat_crc;

    uint8_t pmt[21] = {
        0x02, 0xb0, 0x12, 0x00, 0x01, 0xc1, 0x00, 0x00,
        (uint8_t)(0xe0 | (kVideoPid >> 8)), (uint8_t)kVideoPid,
        0xf0, 0x00,
        0x1b, (uint8_t)(0xe0 | (kVideoPid >> 8)), (uint8_t)kVideoPid, 0xf0, 0x00,
        0, 0, 0, 0
    };
    uint32_t pmt_crc = mpeg_crc32(pmt, 17);
    pmt[17] = (uint8_t)(pmt_crc >> 24); pmt[18] = (uint8_t)(pmt_crc >> 16);
    pmt[19] = (uint8_t)(pmt_crc >> 8);  pmt[20] = (uint8_t)pmt_crc;
    return write_psi(recorder, 0, &recorder->pat_cc, pat, sizeof(pat)) &&
           write_psi(recorder, kPmtPid, &recorder->pmt_cc, pmt, sizeof(pmt));
}

static void encode_pts(uint8_t out[5], uint64_t pts) {
    pts &= ((1ULL << 33) - 1);
    out[0] = (uint8_t)(0x20 | (((pts >> 30) & 7) << 1) | 1);
    out[1] = (uint8_t)(pts >> 22);
    out[2] = (uint8_t)((((pts >> 15) & 0x7f) << 1) | 1);
    out[3] = (uint8_t)(pts >> 7);
    out[4] = (uint8_t)(((pts & 0x7f) << 1) | 1);
}

static void encode_pcr(uint8_t out[6], uint64_t base) {
    base &= ((1ULL << 33) - 1);
    out[0] = (uint8_t)(base >> 25);
    out[1] = (uint8_t)(base >> 17);
    out[2] = (uint8_t)(base >> 9);
    out[3] = (uint8_t)(base >> 1);
    out[4] = (uint8_t)(((base & 1) << 7) | 0x7e);
    out[5] = 0;
}

static bool write_pes(rctl_ts_recorder *recorder, const uint8_t *payload,
                      size_t payload_length, bool keyframe, uint64_t pts_90k) {
    std::vector<uint8_t> pes(14 + payload_length);
    uint8_t header[14] = {0x00, 0x00, 0x01, 0xe0, 0x00, 0x00, 0x80, 0x80, 0x05};
    encode_pts(header + 9, pts_90k);
    memcpy(pes.data(), header, sizeof(header));
    memcpy(pes.data() + sizeof(header), payload, payload_length);

    size_t offset = 0;
    bool first = true;
    while (offset < pes.size()) {
        uint8_t packet[188];
        memset(packet, 0xff, sizeof(packet));
        packet[0] = 0x47;
        packet[1] = (first ? 0x40 : 0x00) | (uint8_t)(kVideoPid >> 8);
        packet[2] = (uint8_t)kVideoPid;

        size_t remaining = pes.size() - offset;
        bool include_pcr = first;
        size_t max_payload = include_pcr ? 176 : 184;
        size_t count = std::min(remaining, max_payload);
        bool adaptation = include_pcr || count < 184;
        packet[3] = (adaptation ? 0x30 : 0x10) | (recorder->video_cc++ & 0x0f);
        size_t payload_offset = 4;
        if (adaptation) {
            size_t adaptation_total = 188 - 4 - count;
            packet[4] = (uint8_t)(adaptation_total - 1);
            payload_offset = 4 + adaptation_total;
            if (adaptation_total > 1) {
                packet[5] = include_pcr ? (uint8_t)(0x10 | (keyframe ? 0x40 : 0)) : 0;
                if (include_pcr) encode_pcr(packet + 6, pts_90k);
            }
        }
        memcpy(packet + payload_offset, pes.data() + offset, count);
        if (!write_packet(recorder, packet)) return false;
        offset += count;
        first = false;
    }
    return true;
}

rctl_ts_recorder *rctl_ts_recorder_open(const char *path) {
    if (!path || !path[0]) return nullptr;
    FILE *file = fopen(path, "wb");
    if (!file) return nullptr;
    rctl_ts_recorder *recorder = new rctl_ts_recorder();
    recorder->file = file;
    if (!write_tables(recorder)) {
        rctl_ts_recorder_close(recorder);
        return nullptr;
    }
    return recorder;
}

bool rctl_ts_recorder_write(rctl_ts_recorder *recorder, const uint8_t *annex_b,
                            size_t length, bool keyframe, uint64_t pts_us) {
    if (!recorder || !annex_b || !length) return false;
    // A standalone recording must begin with SPS/PPS + IDR. Ignore the tail of
    // the current GOP while the app-side encoder handles our keyframe request.
    if (!recorder->started && !keyframe) return true;
    recorder->started = true;
    if (!recorder->first_pts_us) recorder->first_pts_us = pts_us ? pts_us : 1;
    uint64_t relative_us = pts_us >= recorder->first_pts_us ? pts_us - recorder->first_pts_us : 0;
    uint64_t pts_90k = relative_us * 90ULL / 1000ULL;
    if (pts_90k <= recorder->last_pts_90k && recorder->last_pts_90k)
        pts_90k = recorder->last_pts_90k + 1;
    recorder->last_pts_90k = pts_90k;
    if (keyframe && !write_tables(recorder)) return false;
    return write_pes(recorder, annex_b, length, keyframe, pts_90k);
}

void rctl_ts_recorder_close(rctl_ts_recorder *recorder) {
    if (!recorder) return;
    if (recorder->file) {
        fflush(recorder->file);
        fclose(recorder->file);
    }
    delete recorder;
}

uint64_t rctl_ts_recorder_bytes(const rctl_ts_recorder *recorder) {
    return recorder ? recorder->bytes : 0;
}

uint64_t rctl_ts_recorder_duration_ms(const rctl_ts_recorder *recorder) {
    return recorder ? recorder->last_pts_90k / 90ULL : 0;
}
