#import "update/UpdatePolicy.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        assert(rctl_update_catalog_matches(@{@"schema": @1}, @"iphoneos-arm"));
        assert(!rctl_update_catalog_matches(@{@"schema": @1}, @"iphoneos-arm64"));
        NSDictionary *rootless = @{@"schema": @2, @"architecture": @"iphoneos-arm64"};
        assert(rctl_update_catalog_matches(rootless, @"iphoneos-arm64"));
        assert(!rctl_update_catalog_matches(rootless, @"iphoneos-arm"));
        assert(!rctl_update_catalog_matches(@{@"schema": @1, @"architecture": @"iphoneos-arm64"}, @"iphoneos-arm"));
        assert(!rctl_update_catalog_matches(@{@"schema": @2}, @"iphoneos-arm64"));
        assert(!rctl_update_catalog_matches(@{@"schema": @"2"}, @"iphoneos-arm64"));
        assert(!rctl_update_catalog_matches(@{@"schema": @YES}, @"iphoneos-arm"));
        NSDictionary *catalog = @{@"artifacts": @[@{@"version": @"0.4.0~rc.1"}, @{@"version": @"0.4.0~rc.2"}]};
        assert(rctl_update_artifact(catalog, @"0.4.0~rc.1") != nil);
        assert(rctl_update_artifact(catalog, @"missing") == nil);
        assert(rctl_update_artifact(@{@"artifacts": @[@{@"version": @"v"}, @{@"version": @"v"}]}, @"v") == nil);
        assert(rctl_update_artifact(@{@"artifacts": @[@{@"version": @"v"}, @"invalid"]}, @"v") == nil);
        NSString *metadata = @"Package: com.greatlove.rctl\nVersion: 0.4.0~rc.1\nArchitecture: iphoneos-arm64\n";
        assert(rctl_update_package_matches(metadata, @"0.4.0~rc.1", @"iphoneos-arm64"));
        assert(!rctl_update_package_matches(metadata, @"0.4.0~rc.1", @"iphoneos-arm"));
        assert(!rctl_update_package_matches(metadata, @"0.4.0~rc.2", @"iphoneos-arm64"));
        assert(!rctl_update_package_matches([metadata stringByAppendingString:@"Architecture: iphoneos-arm\n"], @"0.4.0~rc.1", @"iphoneos-arm64"));
        assert(!rctl_update_package_matches(nil, @"0.4.0~rc.1", @"iphoneos-arm64"));
    }
    puts("UpdatePolicyTest passed");
}
