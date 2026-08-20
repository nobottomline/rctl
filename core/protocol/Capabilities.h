#pragma once

#import <Foundation/Foundation.h>

#ifndef RCTL_VERSION
#define RCTL_VERSION "dev"
#endif

#define RCTL_PROTOCOL_MAJOR 1
#define RCTL_PROTOCOL_MINOR 0

NSDictionary *rctl_device_capabilities(void);
NSArray<NSString *> *rctl_device_feature_names(void);
