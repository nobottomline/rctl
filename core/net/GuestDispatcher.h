#pragma once
#include "GuestOperations.h"
// Internal device adapter: no HTTP route accepts this authority.
typedef char *(*rctl_guest_device_action)(const char *owner, double deadline,
    const char *operation, const char *arguments, int *status, int *len, const char **contentType);
void rctl_guest_dispatcher_init(rctl_guest_device_action action);
