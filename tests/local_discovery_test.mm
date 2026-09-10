#include <dns_sd.h>
#include <dispatch/dispatch.h>
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <arpa/inet.h>
#include "net/LocalDiscovery.h"

static DNSServiceRegisterReply reply;
static dispatch_queue_t callbackQueue;
static DNSServiceErrorType registrationError;
static std::atomic<unsigned> registrations{0}, releases{0};
static DNSServiceRef fakeRef = reinterpret_cast<DNSServiceRef>(1);

extern "C" DNSServiceErrorType DNSServiceRegister(DNSServiceRef *ref, DNSServiceFlags,
    uint32_t interface, const char *name, const char *type, const char *domain,
    const char *host, uint16_t port, uint16_t length, const void *txt,
    DNSServiceRegisterReply callback, void *) {
    ++registrations;
    assert(interface == kDNSServiceInterfaceIndexAny);
    assert(!strcmp(name, "rctl") && !strcmp(type, "_rctl._tcp") && !strcmp(domain, "local."));
    assert(host == nullptr && ntohs(port) == 8080 && length <= 400);
    assert(TXTRecordGetCount(length, txt) == 2);
    uint8_t size = 0;
    auto version = static_cast<const char *>(TXTRecordGetValuePtr(length, txt, "txtvers", &size));
    assert(size == 1 && version[0] == '1');
    assert(TXTRecordContainsKey(length, txt, "pv"));
    if (registrationError) return registrationError;
    *ref = fakeRef; reply = callback;
    return kDNSServiceErr_NoError;
}

extern "C" DNSServiceErrorType DNSServiceSetDispatchQueue(DNSServiceRef ref, dispatch_queue_t queue) {
    assert(ref == fakeRef); callbackQueue = queue;
    return kDNSServiceErr_NoError;
}

extern "C" void DNSServiceRefDeallocate(DNSServiceRef ref) { assert(ref == fakeRef); ++releases; }

int main() {
    assert(!strcmp(rctl_discovery_status(), "off"));
    rctl_discovery_start(8080);
    assert(!strcmp(rctl_discovery_status(), "starting"));
    dispatch_sync(callbackQueue, ^{ reply(fakeRef, 0, 0, "rctl", "_rctl._tcp", "local.", nullptr); });
    assert(!strcmp(rctl_discovery_status(), "advertising"));
    rctl_discovery_stop();
    rctl_discovery_stop();
    assert(releases == 1 && !strcmp(rctl_discovery_status(), "off"));
    // A policy change can arrive while the responder is still registering.
    rctl_discovery_start(8080);
    rctl_discovery_stop();
    dispatch_sync(callbackQueue, ^{ reply(fakeRef, 0, 0, "rctl", "_rctl._tcp", "local.", nullptr); });
    assert(releases == 2 && !strcmp(rctl_discovery_status(), "off"));
    const unsigned stoppedAttempts = registrations;
    rctl_discovery_start(0);
    assert(registrations == stoppedAttempts && !strcmp(rctl_discovery_status(), "off"));
    registrationError = kDNSServiceErr_ServiceNotRunning;
    rctl_discovery_start(8080);
    assert(!strcmp(rctl_discovery_status(), "error"));
    const unsigned attempts = registrations;
    rctl_discovery_stop();
    usleep(1200000);
    assert(registrations == attempts); // stale retry cannot resurrect a disabled advertisement
    registrationError = 0;
    rctl_discovery_start(8080);
    dispatch_sync(callbackQueue, ^{ reply(fakeRef, 0, kDNSServiceErr_ServiceNotRunning, nullptr, nullptr, nullptr, nullptr); });
    assert(!strcmp(rctl_discovery_status(), "error"));
    usleep(1200000);
    assert(registrations == attempts + 2);
    rctl_discovery_stop();
    puts("local discovery lifecycle tests passed");
}
