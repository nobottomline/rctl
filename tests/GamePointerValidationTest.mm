#import "input/GamePointer.h"
#include <cassert>
static NSString *call(NSString *body) { return rctl_game_pointer_request([body dataUsingEncoding:NSUTF8StringEncoding]); }
int main() {
    @autoreleasepool {
        for (NSString *body in @[@"[]", @"null", @"{}", @"{\"action\":123,\"owner\":true}"])
            assert([call(body) containsString:@"invalid_pointer_request"]);
        NSMutableDictionary *value = [@{@"action": @"state", @"owner": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            @"sequence": @1, @"buttons": @0, @"dx": @0, @"dy": @0, @"wheel": @0} mutableCopy];
        for (NSString *key in @[@"sequence", @"buttons", @"dx", @"dy", @"wheel"]) {
            id previous = value[key];
            for (id invalid in @[@YES, [NSNull null], @"0", @1e20]) {
                value[key] = invalid;
                NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
                assert([rctl_game_pointer_request(data) containsString:@"invalid_pointer_state"]);
            }
            value[key] = previous;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        assert([rctl_game_pointer_request(data) containsString:@"pointer_not_owned"]);
        value[@"action"] = @"move";
        [value removeObjectForKey:@"buttons"];
        data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        assert([rctl_game_pointer_request(data) containsString:@"pointer_not_owned"]);
        value[@"dx"] = @YES;
        data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        assert([rctl_game_pointer_request(data) containsString:@"invalid_pointer_state"]);
        value[@"action"] = @"release";
        data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        assert([rctl_game_pointer_request(data) containsString:@"\"pointer_version\":1"]);
        rctl_game_pointer_stop();
        puts("Pointer validation tests passed (no HID service created)");
    }
}
