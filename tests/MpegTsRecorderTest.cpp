#include "net/MpegTsRecorder.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void require(bool condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "mpeg-ts recorder test failed: %s\n", message);
        exit(1);
    }
}

int main() {
    char path[] = "/tmp/rctl-camera-recorder.XXXXXX";
    int placeholder = mkstemp(path);
    require(placeholder >= 0, "mkstemp");
    close(placeholder);

    const uint8_t keyframe[] = {
        0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1f,
        0, 0, 0, 1, 0x68, 0xee, 0x3c, 0x80,
        0, 0, 0, 1, 0x65, 0x88, 0x84,
    };
    const uint8_t delta[] = {0, 0, 0, 1, 0x41, 0x9a, 0x20};

    rctl_ts_recorder *recorder = rctl_ts_recorder_open(path);
    require(recorder != nullptr, "open");
    require(rctl_ts_recorder_write(recorder, keyframe, sizeof(keyframe), true, 1000000), "keyframe");
    require(rctl_ts_recorder_write(recorder, delta, sizeof(delta), false, 1100000), "delta frame");
    require(rctl_ts_recorder_duration_ms(recorder) == 100, "duration");
    uint64_t expected_bytes = rctl_ts_recorder_bytes(recorder);
    rctl_ts_recorder_close(recorder);

    FILE *file = fopen(path, "rb");
    require(file != nullptr, "read output");
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    require(size > 0 && size % 188 == 0, "188-byte packet alignment");
    require((uint64_t)size == expected_bytes, "reported byte count");

    bool pat = false, pmt = false, video = false;
    uint8_t packet[188];
    while (fread(packet, 1, sizeof(packet), file) == sizeof(packet)) {
        require(packet[0] == 0x47, "sync byte");
        uint16_t pid = (uint16_t)(((packet[1] & 0x1f) << 8) | packet[2]);
        pat |= pid == 0;
        pmt |= pid == 0x100;
        video |= pid == 0x101;
    }
    fclose(file);
    unlink(path);
    require(pat && pmt && video, "PAT/PMT/H.264 PIDs");
    puts("mpeg-ts recorder test passed");
    return 0;
}
