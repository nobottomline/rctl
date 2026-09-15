#pragma once
#import <Foundation/Foundation.h>
#include <sys/types.h>

// Pure merge; neither input is modified. Installed policy/identity always wins.
NSDictionary *rctl_relay_install_merge(NSDictionary *installed, NSDictionary *incoming, NSError **error);
BOOL rctl_relay_install_preserve(NSString *config, NSString *backup, NSError **error);
BOOL rctl_relay_install_apply(NSString *config, NSString *backup, uid_t owner, gid_t group, NSError **error);
