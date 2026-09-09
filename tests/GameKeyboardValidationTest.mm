#import <Foundation/Foundation.h>
#import "input/GameKeyboard.h"
#include <cassert>

static NSString *call(NSString *body) {
    return rctl_game_keyboard_request([body dataUsingEncoding:NSUTF8StringEncoding]);
}
int main() {
    @autoreleasepool {
        assert([call(@"[]") containsString:@"invalid_keyboard_request"]);
        assert([call(@"{\"action\":\"acquire\",\"owner\":123}") containsString:@"invalid_keyboard_request"]);
        assert([call(@"{\"action\":null,\"owner\":null}") containsString:@"invalid_keyboard_request"]);
        assert([call(@"{\"action\":\"acquire\",\"owner\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaz\"}") containsString:@"invalid_keyboard_request"]);
        NSString *prefix = @"{\"action\":\"state\",\"owner\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"sequence\":";
        for (NSString *suffix in @[@"true,\"keys\":[]}", @"0,\"keys\":[]}", @"1.5,\"keys\":[]}",
                                   @"4294967296,\"keys\":[]}", @"1,\"keys\":null}"])
            assert([call([prefix stringByAppendingString:suffix]) containsString:@"invalid_keyboard_state"]);
        for (NSString *suffix in @[@"1,\"keys\":[true]}", @"1,\"keys\":[0]}", @"1,\"keys\":[200]}", @"1,\"keys\":[232]}"])
            assert([call([prefix stringByAppendingString:suffix]) containsString:@"invalid_keyboard_usage"]);
        assert([call([prefix stringByAppendingString:@"1,\"keys\":[26,26]}"]) containsString:@"duplicate_keyboard_usage"]);
        assert([call([prefix stringByAppendingString:@"1,\"keys\":[26,225]}"]) containsString:@"keyboard_not_owned"]);
        assert([call(@"{\"action\":\"release\",\"owner\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}") containsString:@"\"ok\":true"]);
        rctl_game_keyboard_stop();
        puts("Game keyboard validation tests passed (no HID service created)");
    }
}
