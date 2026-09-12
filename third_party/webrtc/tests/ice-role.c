#include "agent.h"
#include "stun.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static const char *password = "fixturePasswordNotASecret1234";

static void roundtrip(bool controlling, bool controlled, uint64_t a, uint64_t b) {
    stun_message_t sent = {0}, received;
    sent.msg_method = STUN_METHOD_BINDING;
    sent.msg_class = STUN_CLASS_REQUEST;
    sent.has_ice_controlling = controlling;
    sent.has_ice_controlled = controlled;
    sent.ice_controlling = a;
    sent.ice_controlled = b;
    strcpy(sent.credentials.username, "local:peer");
    char buffer[1024];
    int size = _juice_stun_write(buffer, sizeof(buffer), &sent, password);
    assert(size > 0);
    assert(_juice_stun_read(buffer, size, &received) > 0);
    assert(received.has_ice_controlling == controlling);
    assert(received.has_ice_controlled == controlled);
    assert(received.ice_controlling == a && received.ice_controlled == b);
    assert(_juice_stun_check_integrity(buffer, size, &received, password));
    assert(!_juice_stun_check_integrity(buffer, size, &received, "wrong-password"));
}

// Exercise the actual authenticated agent receive path, not just serialization.
static void binding_mode(bool controlling, bool controlled, uint64_t value,
                         bool nominate, bool valid_password, unsigned expected,
                         agent_mode_t mode) {
    juice_config_t config = {0};
    config.bind_address = "127.0.0.1";
    juice_agent_t *agent = juice_create(&config);
    assert(agent);
    assert(juice_set_local_ice_attributes(agent, "local", password) == 0);
    char sdp[4096];
    assert(juice_get_local_description(agent, sdp, sizeof(sdp)) == 0);
    assert(juice_set_remote_description(agent,
        "a=ice-ufrag:peer\r\na=ice-pwd:fixturePeerPasswordNotASecret1234\r\n") == 0);
    agent->mode = mode;
    agent->ice_tiebreaker = 10;
    assert(juice_gather_candidates(agent) == 0);
    assert(juice_get_local_description(agent, sdp, sizeof(sdp)) == 0);
    char *candidate = strstr(sdp, "a=candidate:");
    unsigned port = 0;
    assert(candidate && sscanf(candidate, "a=candidate:%*s %*u %*s %*u %*s %u", &port) == 1);

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    assert(fd >= 0);
    struct timeval timeout = {.tv_sec = 1};
    assert(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    struct sockaddr_in destination = {0};
    destination.sin_family = AF_INET;
    destination.sin_port = htons(port);
    destination.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    stun_message_t message = {0};
    message.msg_class = STUN_CLASS_REQUEST;
    message.msg_method = STUN_METHOD_BINDING;
    message.priority = 100;
    message.has_ice_controlling = controlling;
    message.has_ice_controlled = controlled;
    message.ice_controlling = controlling ? value : 0;
    message.ice_controlled = controlled ? value + (controlling && value != 0) : 0;
    message.use_candidate = nominate;
    memset(message.transaction_id, 0x41, sizeof(message.transaction_id));
    strcpy(message.credentials.username, "local:peer");
    char packet[1024];
    int size = _juice_stun_write(packet, sizeof(packet), &message,
                                 valid_password ? password : "wrong-password");
    assert(size > 0);
    assert(sendto(fd, packet, size, 0, (struct sockaddr *)&destination,
                  sizeof(destination)) == size);
    bool found = false;
    ssize_t count;
    while ((count = recv(fd, packet, sizeof(packet), 0)) > 0) {
        stun_message_t reply;
        if (_juice_stun_read(packet, count, &reply) <= 0 ||
            !STUN_IS_RESPONSE(reply.msg_class) ||
            memcmp(reply.transaction_id, message.transaction_id, sizeof(message.transaction_id)))
            continue;
        assert(valid_password);
        assert(_juice_stun_check_integrity(packet, count, &reply, password));
        assert(reply.error_code == expected);
        found = true;
        break;
    }
    assert(found == valid_password);
    close(fd);
    juice_destroy(agent);
}

static void binding(bool controlling, bool controlled, uint64_t value,
                    bool nominate, bool valid_password, unsigned expected) {
    binding_mode(controlling, controlled, value, nominate, valid_password,
                 expected, AGENT_MODE_CONTROLLING);
}

int main(void) {
    juice_set_log_level(JUICE_LOG_LEVEL_NONE);
    roundtrip(false, false, 0, 0);
    roundtrip(true, false, 0, 0);
    roundtrip(false, true, 0, 0);
    roundtrip(true, true, 1, 2);
    binding(false, true, 0, false, true, 0);
    binding(false, true, 42, false, true, 0);
    binding(false, false, 0, false, true, 400);
    binding(true, true, 0, false, true, 400);
    binding(true, true, 42, false, true, 400);
    binding(false, true, 0, true, true, 400);
    binding(false, true, 0, false, false, 0);
    binding(true, false, 0, false, true, 487);
    binding_mode(false, true, 20, false, true, 487, AGENT_MODE_CONTROLLED);
    puts("ICE role presence, zero tiebreaker, malformed roles and authentication: passed");
    return 0;
}
