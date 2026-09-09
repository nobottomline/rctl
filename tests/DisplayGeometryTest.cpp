#include "capture/DisplayGeometry.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void require(bool condition, const char *message) {
    if (condition) return;
    fprintf(stderr, "display geometry test failed: %s\n", message);
    exit(1);
}

static void pixels(unsigned char rotation) {
    // Different bytes in every channel expose accidental swizzles/alpha loss.
    uint32_t source[4][8], output[6][8];
    memset(source, 0xA5, sizeof(source));
    memset(output, 0xA5, sizeof(output));
    for (size_t y = 0; y < 4; ++y)
        for (size_t x = 0; x < 6; ++x)
            source[y][x] = 0x40102000 + (uint32_t)(y * 6 + x + 1);
    uint32_t original[4][8];
    memcpy(original, source, sizeof(source));
    vImage_Buffer src = {source, 4, 6, sizeof(source[0])};
    vImage_Buffer dst = {output, rotation & 1 ? 6UL : 4UL,
                        rotation & 1 ? 4UL : 6UL, sizeof(output[0])};
    require(rctl_display_normalize(&src, &dst, rotation), "normalize padded buffer");
    for (size_t y = 0; y < 4; ++y) {
        for (size_t x = 0; x < 6; ++x) {
            size_t dx = x, dy = y;
            if (rotation == 1) { dx = y; dy = 5 - x; }
            if (rotation == 2) { dx = 5 - x; dy = 3 - y; }
            if (rotation == 3) { dx = 3 - y; dy = x; }
            require(output[dy][dx] == source[y][x], "every pixel reaches expected coordinates");
        }
    }
    require(!memcmp(original, source, sizeof(source)), "source remains unchanged");
    for (size_t y = 0; y < 6; ++y)
        for (size_t x = 0; x < 8; ++x)
            if (y >= dst.height || x >= dst.width)
                require(output[y][x] == 0xA5A5A5A5, "padding and guard rows remain untouched");
    require(!rctl_display_normalize(&src, &dst, 4), "reject unknown quadrant");
    dst.width++;
    require(!rctl_display_normalize(&src, &dst, rotation), "reject incompatible dimensions");
    dst.width--;
    dst.rowBytes = dst.width * 4 - 1;
    require(!rctl_display_normalize(&src, &dst, rotation), "reject short row stride");
    require(!rctl_display_normalize(&src, &src, 0), "reject in-place operation");
}

int main() {
    rctl_display_geometry geometry;
    require(rctl_display_geometry_resolve(1668, 2224, 1668, 2224, "rot0", &geometry),
            "original iPad portrait-native geometry");
    require(geometry.rotation == 0 && geometry.width == 1668 && geometry.height == 2224,
            "original device requires no normalization surface");
    require(rctl_display_geometry_resolve(2048, 2732, 2732, 2048, "rot270", &geometry),
            "observed iPad Pro panel geometry");
    require(geometry.rotation == 3 && geometry.render_width == 2732 && geometry.width == 2048,
            "rot270 restores canonical portrait with clockwise quarter turn");
    require(rctl_display_geometry_resolve(2048, 2732, 2732, 2048, "rot90", &geometry), "rot90");
    require(rctl_display_geometry_resolve(2048, 2732, 2048, 2732, "rot180", &geometry), "rot180");
    require(!rctl_display_geometry_resolve(2048, 2732, 2048, 2732, "rot270", &geometry),
            "reject clipped geometry instead of guessing");
    require(!rctl_display_geometry_resolve(2048, 2732, 2732, 2048, "unknown", &geometry),
            "unknown private API value does not silently rotate");
    require(!rctl_display_geometry_resolve(2048, 2732, 2732, 2048, NULL, &geometry), "missing orientation");
    require(!rctl_display_geometry_resolve(0, 2732, 0, 2732, "rot0", &geometry), "zero dimensions");
    require(!rctl_display_geometry_resolve(NAN, 2732, NAN, 2732, "rot0", &geometry), "NaN dimensions");
    require(!rctl_display_geometry_resolve(INFINITY, 2732, INFINITY, 2732, "rot0", &geometry), "infinity");
    require(!rctl_display_geometry_resolve(2.5, 4, 2.5, 4, "rot0", &geometry), "fractional dimensions");
    require(!rctl_display_geometry_resolve(20000, 4, 20000, 4, "rot0", &geometry), "bounded allocation");
    for (unsigned char rotation = 0; rotation < 4; ++rotation) pixels(rotation);
    puts("display geometry and lossless pixel rotation tests passed");
}
