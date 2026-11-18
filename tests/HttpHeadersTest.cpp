#include "net/HttpHeaders.h"
#include <cassert>
#include <cstdio>

int main() {
    const char *request = "POST /v1/script HTTP/1.1\r\ncontent-type: application/json\r\nCONTENT-LENGTH:\t12\r\n\r\nContent-Length: 999";
    const char *end = strstr(request, "\r\n\r\n");
    assert(!strncmp(rctl_http_header(request, end, "Content-Type"), "application/json", 16));
    assert(!strncmp(rctl_http_header(request, end, "Content-Length"), "12", 2));
    assert(!rctl_http_header(request, end, "Length"));
    assert(!rctl_http_header(request, NULL, "Content-Length"));
    const char *bodyOnly = "POST /Content-Length:23 HTTP/1.1\r\nX-Content-Length: 8\r\n\r\nContent-Length: 9";
    assert(!rctl_http_header(bodyOnly, strstr(bodyOnly, "\r\n\r\n"), "Content-Length"));
    const char *duplicate = "POST / HTTP/1.1\r\nContent-Length: 4\r\ncontent-length: 9\r\n\r\n";
    assert(!rctl_http_header(duplicate, strstr(duplicate, "\r\n\r\n"), "Content-Length"));
    // Field-syntax validation shares the lookup's CRLF boundaries: the last
    // field line ends at the block terminator's own CRLF, and a bare-LF line
    // is not a field boundary.
    assert(rctl_http_fields_valid(request, end));
    const char *lastBad = "POST / HTTP/1.1\r\nX-Ok: 1\r\nContent-Length : 5\r\n\r\n";
    assert(!rctl_http_fields_valid(lastBad, strstr(lastBad, "\r\n\r\n")));
    const char *loneBad = "POST / HTTP/1.1\r\nContent-Length : 5\r\n\r\n";
    assert(!rctl_http_fields_valid(loneBad, strstr(loneBad, "\r\n\r\n")));
    const char *noFields = "POST / HTTP/1.1\r\n\r\n";
    assert(rctl_http_fields_valid(noFields, strstr(noFields, "\r\n\r\n")));
    // Bare CR or LF anywhere in the block (including the request line) is
    // rejected: a mangled line must never change what the CRLF-based lookup
    // reads as a Content-Length.
    const char *mixedLF = "POST / HTTP/1.1\r\nX-Ok: 1\nContent-Length: 5\r\n\r\n";
    assert(!rctl_http_fields_valid(mixedLF, strstr(mixedLF, "\r\n\r\n")));
    const char *loneLF = "POST / HTTP/1.1\nContent-Length: 5\r\n\r\n";
    assert(!rctl_http_fields_valid(loneLF, strstr(loneLF, "\r\n\r\n")));
    const char *bareCR = "POST / HTTP/1.1\r\nX-Ok: 1\rContent-Length: 5\r\n\r\n";
    assert(!rctl_http_fields_valid(bareCR, strstr(bareCR, "\r\n\r\n")));
    const char *leadingLF = "\nPOST / HTTP/1.1\r\n\r\n";
    assert(!rctl_http_fields_valid(leadingLF, strstr(leadingLF, "\r\n\r\n")));
    assert(rctl_http_header_count(request, end, "Content-Length") == 1);
    assert(rctl_http_header_count(duplicate, strstr(duplicate, "\r\n\r\n"), "Content-Length") == 2);
    assert(rctl_http_header_count(bodyOnly, strstr(bodyOnly, "\r\n\r\n"), "Content-Length") == 0);
    assert(rctl_http_header_count(request, end, "Missing") == 0);
    puts("HTTP header tests passed");
}
