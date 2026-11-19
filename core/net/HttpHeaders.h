#pragma once
#include <stddef.h>
#include <string.h>
#include <strings.h>

static inline int rctl_http_hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Decode one URL-encoded parameter value with explicit bounds. Strict by
// design, because every consumer treats the result as a C string that names a
// filesystem object: percent-escapes must be complete with both digits
// explicit (strtol would accept signs and prefixes), a decoded NUL would
// embed a terminator that makes later consumers see a different object, and a
// literal NUL byte in a length-delimited body is exactly as dangerous.
static inline bool rctl_http_decode_query_value(const char *source, size_t source_len,
                                                char *out, size_t out_cap) {
    if (!out_cap) return false;
    size_t oi = 0;
    for (size_t i = 0; i < source_len; i++) {
        unsigned char value = (unsigned char)source[i];
        if (value == '%') {
            if (i + 2 >= source_len) return false;
            int hi = rctl_http_hex_digit(source[i + 1]), lo = rctl_http_hex_digit(source[i + 2]);
            if (hi < 0 || lo < 0) return false;
            value = (unsigned char)((hi << 4) | lo);
            if (value == 0) return false;
            i += 2;
        } else if (value == 0) {
            return false;
        }
        if (oi + 1 >= out_cap) return false;
        out[oi++] = (char)value;
    }
    out[oi] = 0;
    return oi > 0;
}

// Return a value only from complete header lines, never the request target or
// body. Duplicate fields fail closed; callers must not guess a body length.
static inline const char *rctl_http_header(const char *request, const char *end, const char *name) {
    if (!request || !end || end < request) return NULL;
    const size_t length = strlen(name);
    const char *found = NULL;
    const char *line = strstr(request, "\r\n");
    while (line && line < end) {
        line += 2;
        const char *next = strstr(line, "\r\n");
        if (!next || next > end) return NULL;
        if ((size_t)(next - line) > length && line[length] == ':' && !strncasecmp(line, name, length)) {
            if (found) return NULL;
            found = line + length + 1;
            while (found < next && (*found == ' ' || *found == '\t')) ++found;
        }
        line = next;
    }
    return found;
}

// Count complete header lines with the given field name, so callers can
// distinguish "absent" (0) from "duplicated" (>1) — rctl_http_header returns
// NULL for both and fails closed on duplicates.
static inline int rctl_http_header_count(const char *request, const char *end, const char *name) {
    if (!request || !end || end < request) return 0;
    const size_t length = strlen(name);
    int count = 0;
    const char *line = strstr(request, "\r\n");
    while (line && line < end) {
        line += 2;
        const char *next = strstr(line, "\r\n");
        if (!next || next > end) return count;
        if ((size_t)(next - line) > length && line[length] == ':' && !strncasecmp(line, name, length)) count++;
        line = next;
    }
    return count;
}

// Validate field syntax over the complete header block (RFC 9112 §5.1): every
// field line must contain a colon with no whitespace before it, and bare CR
// or LF anywhere in the block (the RFC lets recipients tolerate a lone LF as
// a line terminator, but rctl deliberately requires CRLF so a mangled field
// can never split into something the CRLF-based lookup below would read
// differently). The last field line is terminated by the block terminator's
// own first CRLF.
static inline int rctl_http_fields_valid(const char *request, const char *end) {
    if (!request || !end || end < request) return 0;
    for (const char *p = request; p < end; p++) {
        if (*p == '\r' || *p == '\n') {
            // A legitimate CRLF is a line boundary; a bare CR or LF (not
            // followed/preceded by its pair) is malformed. Check pairs.
            if (*p == '\r') {
                if (p[1] != '\n') return 0;
                p++; // skip the pair
            } else {
                if (p == request || p[-1] != '\r') return 0;
            }
        }
    }
    const char *line = strstr(request, "\r\n"); // skip the request line
    if (!line || line >= end) return 1;         // no field lines
    for (;;) {
        line += 2;
        if (line >= end) return 1;              // reached the blank terminator
        const char *next = strstr(line, "\r\n");
        if (!next || next > end) return 0;      // unterminated field line
        const void *raw_colon = memchr(line, ':', (size_t)(next - line));
        const char *colon = (const char *)raw_colon;
        if (!colon || (colon > line && (colon[-1] == ' ' || colon[-1] == '\t'))) return 0;
        line = next;
    }
}

// Parse "host[:port]" (RFC 9110 authority form, IPv4 only — this listener is
// AF_INET). Lowercases the host, rejects empty hosts, non-digit or out-of-range
// ports, and IPv6 bracket forms. An omitted port yields 0.
static inline bool rctl_http_split_authority(const char *authority, char *host, size_t host_cap, int *port) {
    if (!authority || !host || host_cap == 0 || !port) return false;
    size_t len = strlen(authority);
    if (len == 0 || authority[0] == '[') return false;   // IPv6 not served here
    const char *colon = strrchr(authority, ':');
    const char *h_end = colon ? colon : authority + len;
    size_t host_len = (size_t)(h_end - authority);
    if (host_len == 0 || host_len >= host_cap) return false;
    for (size_t i = 0; i < host_len; i++) {
        char c = authority[i];
        bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  c == '.' || c == '-';
        if (!ok) return false;
        host[i] = (char)(c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c);
    }
    host[host_len] = 0;
    *port = 0;
    if (colon) {
        const char *p = colon + 1;
        if (!*p) return false;               // "host:" with an empty port
        int value = 0;
        for (; *p; p++) {
            if (*p < '0' || *p > '9') return false;
            value = value * 10 + (*p - '0');
            if (value > 65535) return false;
        }
        *port = value;
    }
    return true;
}

// Same host (case-insensitive) and same effective port, where 0 means the
// scheme default. Used to require that a browser Origin belongs to the very
// authority the request was addressed to.
static inline bool rctl_http_authority_equal(const char *a, const char *b) {
    char host_a[256], host_b[256];
    int port_a = 0, port_b = 0;
    if (!rctl_http_split_authority(a, host_a, sizeof(host_a), &port_a)) return false;
    if (!rctl_http_split_authority(b, host_b, sizeof(host_b), &port_b)) return false;
    if (strcmp(host_a, host_b) != 0) return false;
    if (port_a != port_b) {
        // One side may omit the default port; only "80 or omitted" can agree.
        if (!((port_a == 0 && port_b == 80) || (port_b == 0 && port_a == 80))) return false;
    }
    return true;
}

// A browser Origin matches the validated request authority only when it is a
// plain http origin for exactly that authority — no path, no userinfo, no
// other scheme. The device page is served over http; https belongs to the
// relay and is authorized there, never here.
static inline bool rctl_http_origin_matches(const char *origin, const char *host_authority) {
    if (!origin) return false;
    static const char scheme[] = "http://";
    if (strncmp(origin, scheme, sizeof(scheme) - 1) != 0) return false;
    const char *authority = origin + sizeof(scheme) - 1;
    if (strchr(authority, '/')) return false;   // path or "//" — not a bare origin
    if (strchr(authority, '@')) return false;   // userinfo
    return rctl_http_authority_equal(authority, host_authority);
}
