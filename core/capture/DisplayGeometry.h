#pragma once

#include <math.h>
#include <stddef.h>
#include <string.h>
#include <Accelerate/Accelerate.h>

// Render-server pixels are not necessarily in UIKit's fixed portrait space.
// CADisplay rotN describes the panel offset; vImage's counterclockwise quadrant
// convention normalizes it (rot270, for example, needs a clockwise quarter turn).
struct rctl_display_geometry {
    size_t render_width, render_height;
    size_t width, height;
    unsigned char rotation;
};

static inline bool rctl_display_dimension(double value) {
    return isfinite(value) && value >= 2 && value <= 16384 && floor(value) == value;
}

static inline bool rctl_display_geometry_resolve(double width, double height,
                                                double renderWidth, double renderHeight,
                                                const char *orientation,
                                                rctl_display_geometry *out) {
    if (!out || !rctl_display_dimension(width) || !rctl_display_dimension(height) ||
        !rctl_display_dimension(renderWidth) || !rctl_display_dimension(renderHeight) ||
        !orientation) return false;
    unsigned char rotation;
    if (!strcmp(orientation, "rot0")) rotation = 0;
    else if (!strcmp(orientation, "rot90")) rotation = 1;
    else if (!strcmp(orientation, "rot180")) rotation = 2;
    else if (!strcmp(orientation, "rot270")) rotation = 3;
    else return false;
    if (width != (rotation & 1 ? renderHeight : renderWidth) ||
        height != (rotation & 1 ? renderWidth : renderHeight)) return false;
    *out = {(size_t)renderWidth, (size_t)renderHeight,
            (size_t)width, (size_t)height, rotation};
    return true;
}

// Separate, non-overlapping buffers, exact dimensions and padded row strides.
// No scaling or interpolation: preserve every BGRA pixel, including alpha.
static inline bool rctl_display_normalize(const vImage_Buffer *src, vImage_Buffer *dst,
                                          unsigned char rotation) {
    if (!src || !dst || !src->data || !dst->data || src->data == dst->data || rotation > 3 ||
        !src->width || !src->height || src->width > 16384 || src->height > 16384 ||
        dst->width != (rotation & 1 ? src->height : src->width) ||
        dst->height != (rotation & 1 ? src->width : src->height) ||
        src->rowBytes < src->width * 4 || dst->rowBytes < dst->width * 4) return false;
    const Pixel_8888 background = {0, 0, 0, 0};
    return vImageRotate90_ARGB8888(src, dst, rotation, background, kvImageNoFlags) == kvImageNoError;
}
