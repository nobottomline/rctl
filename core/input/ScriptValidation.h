#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

static inline bool rctl_script_number(id value, double min, double max, bool integral = false) {
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return false;
    double n = [value doubleValue];
    return isfinite(n) && n >= min && n <= max && (!integral || trunc(n) == n);
}

static inline bool rctl_script_string(id value, NSUInteger limit) {
    return [value isKindOfClass:[NSString class]] && [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= limit;
}

// Validate the entire plan before scheduling anything. Limits bound dispatch
// allocations and prevent malformed JSON from invoking arbitrary ObjC selectors.
static inline bool rctl_script_valid(NSArray *actions) {
    if (![actions isKindOfClass:[NSArray class]] || actions.count > 10000) return false;
    double seconds = 0;
    for (id item in actions) {
        if (![item isKindOfClass:[NSDictionary class]]) return false;
        NSDictionary *a = item;
        NSString *type = a[@"type"];
        if (!rctl_script_string(type, 32)) return false;
        if ([type isEqual:@"wait"]) {
            if (!rctl_script_number(a[@"ms"], 0, 600000)) return false;
            seconds += [a[@"ms"] doubleValue] / 1000;
        } else if ([type isEqual:@"tap"] || [type isEqual:@"input"]) {
            if (!rctl_script_number(a[@"x"], 0, 1) || !rctl_script_number(a[@"y"], 0, 1)) return false;
            if ([type isEqual:@"input"]) {
                if (!rctl_script_number(a[@"phase"], 0, 2, true) || !rctl_script_number(a[@"id"], 0, 9, true)) return false;
            } else seconds += .12;
        } else if ([type isEqual:@"swipe"]) {
            for (NSString *key in @[@"x1", @"y1", @"x2", @"y2"])
                if (!rctl_script_number(a[key], 0, 1)) return false;
            if (a[@"ms"] && !rctl_script_number(a[@"ms"], 0, 60000)) return false;
            seconds += ([a[@"ms"] doubleValue] > 0 ? [a[@"ms"] doubleValue] : 300) / 1000 + .05;
        } else if ([type isEqual:@"key"] || [type isEqual:@"input_key"]) {
            if (!rctl_script_number(a[@"u"], 0, 65535, true) ||
                (a[@"p"] && !rctl_script_number(a[@"p"], 0, 65535, true)) ||
                (a[@"d"] && !rctl_script_number(a[@"d"], 0, 2, true))) return false;
            if ([type isEqual:@"key"]) seconds += .05;
        } else if ([type isEqual:@"type"]) {
            if (!rctl_script_string(a[@"text"], 4096)) return false;
            seconds += [a[@"text"] length] * .1 + .05; // conservative preflight bound
        } else if ([type isEqual:@"launch"]) {
            if (!rctl_script_string(a[@"bundle"], 255) || ![a[@"bundle"] length]) return false;
            seconds += .8;
        } else if ([type isEqual:@"button"]) {
            if (!rctl_script_string(a[@"name"], 32) || ![@[@"home", @"lock", @"volup", @"voldn", @"cc", @"shade"] containsObject:a[@"name"]]) return false;
            seconds += .2;
        } else return false;
        if (seconds > 3600) return false;
    }
    return true;
}
