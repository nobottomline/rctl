#pragma once
#include <stddef.h>
#include <string.h>
#include <strings.h>

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
