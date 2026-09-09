#pragma once
#import <Foundation/Foundation.h>

// SpringBoard main queue only. No HID service exists until explicitly acquired.
NSString *rctl_game_pointer_request(NSData *request);
void rctl_game_pointer_stop(void);
