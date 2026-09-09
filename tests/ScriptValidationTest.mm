#import "input/ScriptValidation.h"
#include <cassert>
#include <cstdio>
int main() { @autoreleasepool {
    assert(rctl_script_valid(@[@{@"type":@"input", @"phase":@0, @"id":@0, @"x":@.5, @"y":@.5},
                               @{@"type":@"wait", @"ms":@20}, @{@"type":@"input_key", @"u":@4, @"d":@2}]));
    assert(!rctl_script_valid(@[@{@"type":@"input", @"phase":@3, @"id":@0, @"x":@.5, @"y":@.5}]));
    assert(!rctl_script_valid(@[@{@"type":@"wait", @"ms":@-1}]));
    assert(!rctl_script_valid(@[@{@"type":@"tap", @"x":@YES, @"y":@.5}]));
    assert(!rctl_script_valid(@[@{@"type":@"type", @"text":@{}}]));
    assert(!rctl_script_valid(@[@{@"type":@"unknown"}]));
    assert(!rctl_script_valid(@[@{@"type":@{}}]));
    puts("script preflight tests passed");
} }
