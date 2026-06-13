#import "net/RelayClient.h"
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <time.h>

#define RCTL_RELAY_CONFIG_PLIST @"/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist"

static void relay_log(NSString *line) {
    FILE *f = fopen("/tmp/rctld.log", "a");
    if (!f) return;
    fprintf(f, "[%ld pid=%d] [relay] %s\n", (long)time(NULL), getpid(), [line UTF8String]);
    fclose(f);
}

static NSString *relay_random_hex(NSUInteger bytes) {
    NSMutableString *out = [NSMutableString stringWithCapacity:bytes * 2];
    for (NSUInteger i = 0; i < bytes; i++) {
        uint8_t b = (uint8_t)arc4random_uniform(256);
        [out appendFormat:@"%02x", b];
    }
    return out;
}

@interface RCTLRelayClient : NSObject
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionWebSocketTask *task;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSMutableDictionary *config;
@property(nonatomic, copy) NSString *deviceID;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, assign) NSInteger reconnectDelay;
@end

@implementation RCTLRelayClient

+ (instancetype)shared {
    static RCTLRelayClient *client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        client = [[RCTLRelayClient alloc] init];
    });
    return client;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("com.greatlove.rctl.relay", DISPATCH_QUEUE_SERIAL);
    _reconnectDelay = 2;
    return self;
}

- (void)start {
    dispatch_async(self.queue, ^{
        if (self.running) return;
        self.running = YES;
        [self connect];
    });
}

- (NSMutableDictionary *)loadConfig {
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:RCTL_RELAY_CONFIG_PLIST];
    if (![raw isKindOfClass:[NSDictionary class]]) {
        relay_log(@"disabled: config plist missing");
        return nil;
    }
    NSMutableDictionary *dict = [raw mutableCopy];
    if (![dict[@"Enabled"] respondsToSelector:@selector(boolValue)] || ![dict[@"Enabled"] boolValue]) {
        relay_log(@"disabled: Enabled=false");
        return nil;
    }
    NSString *url = [dict[@"RelayURL"] isKindOfClass:[NSString class]] ? dict[@"RelayURL"] : nil;
    if (![url hasPrefix:@"wss://"]) {
        relay_log(@"disabled: RelayURL must start with wss://");
        return nil;
    }
    NSString *token = [self tokenFromConfig:dict];
    if (token.length < 32) {
        relay_log(@"disabled: no usable DeviceSecret or EnrollToken");
        return nil;
    }
    NSString *deviceID = [dict[@"DeviceID"] isKindOfClass:[NSString class]] ? dict[@"DeviceID"] : nil;
    if (deviceID.length < 16) {
        deviceID = relay_random_hex(16);
        dict[@"DeviceID"] = deviceID;
        [self saveConfig:dict];
    }
    self.deviceID = deviceID;
    return dict;
}

- (NSString *)tokenFromConfig:(NSDictionary *)dict {
    NSString *deviceSecret = [dict[@"DeviceSecret"] isKindOfClass:[NSString class]] ? dict[@"DeviceSecret"] : nil;
    if (deviceSecret.length >= 32) return deviceSecret;
    NSString *enrollToken = [dict[@"EnrollToken"] isKindOfClass:[NSString class]] ? dict[@"EnrollToken"] : nil;
    return enrollToken ?: @"";
}

- (void)saveConfig:(NSDictionary *)dict {
    NSString *dir = [RCTL_RELAY_CONFIG_PLIST stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![dict writeToFile:RCTL_RELAY_CONFIG_PLIST atomically:YES]) {
        relay_log(@"failed to save relay config");
    }
}

- (void)connect {
    self.config = [self loadConfig];
    if (!self.config) {
        self.running = NO;
        return;
    }
    if (@available(iOS 13.0, *)) {
        NSString *urlString = self.config[@"RelayURL"];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        NSString *token = [self tokenFromConfig:self.config];
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        request.timeoutInterval = 20;

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        self.session = [NSURLSession sessionWithConfiguration:configuration];
        self.task = [self.session webSocketTaskWithRequest:request];
        [self.task resume];
        relay_log(@"connecting");
        [self sendHello];
        [self receiveLoop];
    } else {
        relay_log(@"disabled: NSURLSessionWebSocketTask requires iOS 13+");
        self.running = NO;
    }
}

- (void)sendHello API_AVAILABLE(ios(13.0)) {
    NSString *name = [self.config[@"DeviceName"] isKindOfClass:[NSString class]] ? self.config[@"DeviceName"] : @"rctl device";
    NSDictionary *hello = @{@"type": @"hello", @"device_id": self.deviceID ?: @"", @"device_name": name};
    NSData *data = [NSJSONSerialization dataWithJSONObject:hello options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:json ?: @"{}"];
    [self.task sendMessage:message completionHandler:^(NSError *error) {
        if (error) {
            relay_log([NSString stringWithFormat:@"hello send failed: %@", error.localizedDescription]);
            [self scheduleReconnect];
        }
    }];
}

- (void)receiveLoop API_AVAILABLE(ios(13.0)) {
    [self.task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        dispatch_async(self.queue, ^{
            if (error) {
                relay_log([NSString stringWithFormat:@"receive failed: %@", error.localizedDescription]);
                [self scheduleReconnect];
                return;
            }
            [self handleMessage:message];
            [self receiveLoop];
        });
    }];
}

- (void)handleMessage:(NSURLSessionWebSocketMessage *)message API_AVAILABLE(ios(13.0)) {
    NSData *data = nil;
    if (message.type == NSURLSessionWebSocketMessageTypeString) {
        data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        data = message.data;
    }
    if (!data.length) return;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) return;
    NSString *type = [dict[@"type"] isKindOfClass:[NSString class]] ? dict[@"type"] : @"";

    if ([type isEqualToString:@"hello_ack"]) {
        NSString *status = [dict[@"status"] isKindOfClass:[NSString class]] ? dict[@"status"] : @"unknown";
        self.reconnectDelay = 2;
        relay_log([NSString stringWithFormat:@"connected status=%@", status]);
    } else if ([type isEqualToString:@"approved"]) {
        NSString *secret = [dict[@"device_secret"] isKindOfClass:[NSString class]] ? dict[@"device_secret"] : nil;
        if (secret.length >= 32) {
            NSMutableDictionary *updated = [self.config mutableCopy];
            updated[@"DeviceSecret"] = secret;
            [updated removeObjectForKey:@"EnrollToken"];
            [self saveConfig:updated];
            self.config = updated;
            relay_log(@"stored device secret");
        }
    } else if ([type isEqualToString:@"ping"]) {
        [self sendJSON:@{@"type": @"pong"}];
    }
}

- (void)sendJSON:(NSDictionary *)dict API_AVAILABLE(ios(13.0)) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:json ?: @"{}"];
    [self.task sendMessage:message completionHandler:^(NSError *error) {
        if (error) relay_log([NSString stringWithFormat:@"send failed: %@", error.localizedDescription]);
    }];
}

- (void)scheduleReconnect {
    if (!self.running) return;
    [self.task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    [self.session invalidateAndCancel];
    NSInteger delay = self.reconnectDelay;
    self.reconnectDelay = MIN(self.reconnectDelay * 2, 60);
    relay_log([NSString stringWithFormat:@"reconnect in %lds", (long)delay]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), self.queue, ^{
        [self connect];
    });
}

@end

void rctl_relay_start(void) {
    [[RCTLRelayClient shared] start];
}
