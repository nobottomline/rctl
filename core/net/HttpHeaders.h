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
