#include "net/VirtualMicServer.h"

#include <arpa/inet.h>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

static bool read_all(int fd, void *buffer, size_t length) {
    auto *bytes = static_cast<uint8_t *>(buffer);
    while (length) {
        ssize_t count = recv(fd, bytes, length, 0);
        if (count <= 0) return false;
        bytes += count;
        length -= static_cast<size_t>(count);
    }
    return true;
}

int main() {
    assert(rctl_vmic_server_start() == 1);
    assert(rctl_vmic_server_start() == 1);
    assert(rctl_vmic_route() == RCTL_TALK_SPEAKER);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    assert(fd >= 0);
    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(RCTL_VIRTUAL_MIC_PORT);
    assert(connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0);
    timeval timeout = {.tv_sec = 0, .tv_usec = 200000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    usleep(50000);

    const int16_t samples[] = {-32768, -1234, 0, 1234, 32767};
    rctl_vmic_push(samples, 5);
    uint32_t ignored = 0;
    assert(recv(fd, &ignored, sizeof(ignored), 0) < 0 && (errno == EAGAIN || errno == EWOULDBLOCK));

    rctl_vmic_set_route(RCTL_TALK_VIRTUAL_MIC);
    rctl_vmic_push(samples, 5);
    uint32_t networkLength = 0;
    assert(read_all(fd, &networkLength, sizeof(networkLength)));
    assert(ntohl(networkLength) == sizeof(samples));
    int16_t received[5] = {};
    assert(read_all(fd, received, sizeof(received)));
    assert(memcmp(received, samples, sizeof(samples)) == 0);

    rctl_vmic_set_route(RCTL_TALK_BOTH);
    assert(rctl_vmic_route() == RCTL_TALK_BOTH);
    rctl_vmic_set_route(99);
    assert(rctl_vmic_route() == RCTL_TALK_SPEAKER);

    close(fd);
    printf("virtual mic server test passed\n");
    return 0;
}
