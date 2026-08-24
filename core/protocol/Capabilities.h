#pragma once

#import <Foundation/Foundation.h>
#import "ProtocolVersion.generated.h"

#ifndef RCTL_VERSION
#define RCTL_VERSION "dev"
#endif

NSDictionary *rctl_device_capabilities(void);
NSArray<NSString *> *rctl_device_feature_names(void);
