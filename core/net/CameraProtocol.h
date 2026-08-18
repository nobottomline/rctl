#pragma once

#include <stdint.h>

#define RCTL_CAMERA_INGEST_PORT 8081
#define RCTL_CAMERA_MAGIC 0x5243414dU /* RCAM */
#define RCTL_CAMERA_VERSION 1
#define RCTL_CAMERA_MAX_PAYLOAD (2U * 1024U * 1024U)

enum {
    RCTL_CAMERA_MSG_HELLO = 1,
    RCTL_CAMERA_MSG_VIDEO = 2,
};

enum {
    RCTL_CAMERA_FLAG_KEYFRAME = 1,
};

#pragma pack(push, 1)
typedef struct {
    uint32_t magic_be;
    uint8_t version;
    uint8_t type;
    uint16_t flags_be;
    uint32_t length_be;
    uint64_t pts_us_be;
    uint64_t generation_be;
} rctl_camera_header;
#pragma pack(pop)
