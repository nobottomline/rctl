#pragma once
#import <Foundation/Foundation.h>

#if defined(RCTL_ROOTLESS) && RCTL_ROOTLESS
#define RCTL_UPDATE_ARCHITECTURE @"iphoneos-arm64"
#else
#define RCTL_UPDATE_ARCHITECTURE @"iphoneos-arm"
#endif

// A schema-1 catalog has no architecture field and belongs only to rootful.
static inline BOOL rctl_update_catalog_matches(NSDictionary *payload, NSString *architecture) {
    id schema = payload[@"schema"];
    if (![schema isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)schema) == CFBooleanGetTypeID()) return NO;
    if ([schema isEqual:@1]) {
        return [architecture isEqualToString:@"iphoneos-arm"] && !payload[@"architecture"];
    }
    return [schema isEqual:@2] && [payload[@"architecture"] isKindOfClass:NSString.class] &&
           [payload[@"architecture"] isEqualToString:architecture];
}

static inline NSDictionary *rctl_update_artifact(NSDictionary *payload, NSString *version) {
    id artifacts = payload[@"artifacts"];
    if (![version isKindOfClass:NSString.class] || !version.length ||
        ![artifacts isKindOfClass:NSArray.class] || [artifacts count] < 2 || [artifacts count] > 128) return nil;
    NSMutableSet *seen = [NSMutableSet set];
    NSDictionary *result = nil;
    for (id artifact in artifacts) {
        if (![artifact isKindOfClass:NSDictionary.class]) return nil;
        id candidate = artifact[@"version"];
        if (![candidate isKindOfClass:NSString.class] || ![candidate length] || [seen containsObject:candidate]) return nil;
        [seen addObject:candidate];
        if ([candidate isEqualToString:version]) result = artifact;
    }
    return result;
}

static inline BOOL rctl_update_package_matches(NSString *metadata, NSString *version, NSString *architecture) {
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    for (NSString *line in [metadata componentsSeparatedByString:@"\n"]) {
        NSRange delimiter = [line rangeOfString:@": "];
        if (delimiter.location == NSNotFound) continue;
        NSString *key = [line substringToIndex:delimiter.location];
        if (fields[key]) return NO;
        fields[key] = [line substringFromIndex:NSMaxRange(delimiter)];
    }
    return [fields[@"Package"] isEqualToString:@"com.greatlove.rctl"] &&
           [fields[@"Version"] isEqualToString:version] &&
           [fields[@"Architecture"] isEqualToString:architecture];
}
