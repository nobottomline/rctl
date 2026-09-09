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
    puts("HTTP header tests passed");
}
