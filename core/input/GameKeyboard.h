#pragma once
#import <Foundation/Foundation.h>

// Call on the main queue. The service is absent until an explicit acquisition.
NSString *rctl_game_keyboard_request(NSData *request);
void rctl_game_keyboard_stop(void);
