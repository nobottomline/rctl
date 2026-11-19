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
    // Authority parsing and origin agreement share the gate's rules: canonical
    // IPv4/loopback names, numeric ports, default-port omission, and the
    // http-only origin scheme.
    char host[256]; int port = 0;
    assert(rctl_http_split_authority("192.168.1.5:8080", host, sizeof(host), &port));
    assert(!strcmp(host, "192.168.1.5") && port == 8080);
    assert(rctl_http_split_authority("LocalHost", host, sizeof(host), &port));
    assert(!strcmp(host, "localhost") && port == 0);
    assert(!rctl_http_split_authority("host:", host, sizeof(host), &port));
    assert(!rctl_http_split_authority("host:99999", host, sizeof(host), &port));
    assert(!rctl_http_split_authority("[::1]:8080", host, sizeof(host), &port));
    assert(!rctl_http_split_authority("bad host", host, sizeof(host), &port));
    assert(rctl_http_authority_equal("Device:8080", "device:8080"));
    assert(rctl_http_authority_equal("device:80", "device"));
    assert(!rctl_http_authority_equal("device", "device:8080"));
    assert(!rctl_http_authority_equal("device:8080", "device2:8080"));
    assert(rctl_http_origin_matches("http://device:8080", "device:8080"));
    assert(rctl_http_origin_matches("http://localhost", "localhost"));
    assert(!rctl_http_origin_matches("https://device:8080", "device:8080"));
    assert(!rctl_http_origin_matches("http://device:8080/path", "device:8080"));
    assert(!rctl_http_origin_matches("http://device", "device:8080"));
    assert(!rctl_http_origin_matches("http://attacker:8080", "device:8080"));
    // The strict query decoder guards every path-naming consumer (download
    // tickets, pull_stream): percent-escapes must be complete and explicit,
    // and neither a decoded nor a literal NUL may reach a C-string consumer,
    // or the ticket would certify one path while the file layer opens a
    // different (longer) one.
    char value[256];
    assert(rctl_http_decode_query_value("%2Fetc%2Fmotd", 13, value, sizeof(value)));
    assert(!strcmp(value, "/etc/motd"));
    const char *nul_body = "a\0b";                        // literal NUL in a length-delimited body
    assert(!rctl_http_decode_query_value(nul_body, 3, value, sizeof(value)));
    assert(!rctl_http_decode_query_value("%00", 3, value, sizeof(value)));
    assert(!rctl_http_decode_query_value("x%00y", 4, value, sizeof(value)));
    assert(!rctl_http_decode_query_value("%0", 2, value, sizeof(value)));      // truncated escape
    assert(!rctl_http_decode_query_value("%2", 2, value, sizeof(value)));      // truncated escape
    assert(!rctl_http_decode_query_value("%2g", 3, value, sizeof(value)));     // bad hex digit
    assert(!rctl_http_decode_query_value("%2G", 3, value, sizeof(value)));     // hex digits are explicit
    assert(!rctl_http_decode_query_value("%", 1, value, sizeof(value)));
    assert(!rctl_http_decode_query_value("0x41", 4, value, 3));                // too long for the cap
    assert(rctl_http_decode_query_value("plain.tar.gz", 12, value, sizeof(value)));
    assert(!strcmp(value, "plain.tar.gz"));
    puts("HTTP header tests passed");
}
