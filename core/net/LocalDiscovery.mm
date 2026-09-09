#include "LocalDiscovery.h"
#include "protocol/ProtocolVersion.generated.h"
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <dns_sd.h>
#include <atomic>
#include <cstdio>
#include <cstring>

namespace {
enum Status { Off, Pending, Advertising, Error };
std::atomic<Status> status{Off};
DNSServiceRef service = nullptr;
uint16_t port = 0;
uint64_t generation = 0;
unsigned retrySeconds = 1;

dispatch_queue_t queue() {
    static dispatch_queue_t value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ value = dispatch_queue_create("com.greatlove.rctl.discovery", DISPATCH_QUEUE_SERIAL); });
    return value;
}

void clearService() {
    if (service) { DNSServiceRefDeallocate(service); service = nullptr; }
}

void registerService();

void failed(DNSServiceErrorType error) {
    clearService();
    status.store(Error);
    // Do not log responder names/hostnames or any device identity.
    fprintf(stderr, "rctld: local discovery error %d; retry in %us\n", error, retrySeconds);
    const uint64_t attempt = ++generation;
    const unsigned delay = retrySeconds;
    retrySeconds = retrySeconds < 30 ? retrySeconds * 2 : 60;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), queue(), ^{
        if (attempt == generation && port) registerService();
    });
}

void registered(DNSServiceRef ref, DNSServiceFlags, DNSServiceErrorType error,
                const char *, const char *, const char *, void *) {
    if (ref != service) return;
    if (error) { failed(error); return; }
    status.store(Advertising);
    retrySeconds = 1;
}

void registerService() {
    clearService();
    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, nullptr);
    char version[32];
    snprintf(version, sizeof(version), "%u.%u", RCTL_PROTOCOL_MAJOR, RCTL_PROTOCOL_MINOR);
    auto error = TXTRecordSetValue(&txt, "txtvers", 1, "1");
    if (!error) error = TXTRecordSetValue(&txt, "pv", (uint8_t)strlen(version), version);
    if (!error) {
        error = DNSServiceRegister(&service, 0, kDNSServiceInterfaceIndexAny, "rctl",
                                   "_rctl._tcp", "local.", nullptr, htons(port),
                                   TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
                                   registered, nullptr);
    }
    TXTRecordDeallocate(&txt);
    if (!error) error = DNSServiceSetDispatchQueue(service, queue());
    if (error) failed(error);
}
}

void rctl_discovery_start(uint16_t value) {
    dispatch_sync(queue(), ^{
        ++generation;
        clearService();
        port = value;
        retrySeconds = 1;
        status.store(value ? Pending : Off);
        if (port) registerService();
    });
}

void rctl_discovery_stop(void) {
    dispatch_sync(queue(), ^{
        ++generation;
        port = 0;
        clearService();
        status.store(Off);
    });
}

const char *rctl_discovery_status(void) {
    switch (status.load()) {
        case Off: return "off";
        case Advertising: return "advertising";
        case Pending: return "starting";
        case Error: return "error";
    }
    return "error";
}
