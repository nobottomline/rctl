#import "net/RelayClient.h"
#import "net/WebRTCBridge.h"
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <time.h>
#import <pthread.h>

// IOPMAssertion (IOKit power management) — declared locally with C linkage; the
// header isn't in the iOS SDK. Used to keep the device awake ONLY while
// reconnecting.
extern "C" {
typedef uint32_t RCTLPMAssertionID;
int IOPMAssertionCreateWithName(CFStringRef type, uint32_t level, CFStringRef name, RCTLPMAssertionID *assertionID);
int IOPMAssertionRelease(RCTLPMAssertionID assertionID);
}

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

// The relay connection is supervised by a dedicated pthread rather than GCD
// dispatch_after timers: iOS defers background GCD timers by minutes when the
// device is idle, which is what left the relay link dead until the device was
// poked. A plain pthread waking on a kernel timer escapes that deferral.
static pthread_t g_supervisor_thread;
static pthread_mutex_t g_supervisor_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_supervisor_cond = PTHREAD_COND_INITIALIZER;
static BOOL g_supervisor_started = NO;
static BOOL g_supervisor_stop = NO;
static void *relay_supervisor_main(void *arg);
static void relay_webrtc_send_routed(void *ctx, const char *json);
static NSMutableArray *g_relay_clients;

@interface RCTLRelayClient : NSObject
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) id task;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSMutableDictionary *config;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *streamIDs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSURLSessionDataTask *> *streamTasks;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *streamSocketTasks;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *termTasks;
@property(nonatomic, copy) NSString *deviceID;
@property(nonatomic, copy) NSString *relayURL;
@property(nonatomic, copy) NSString *routePrefix;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, assign) BOOL reconnectScheduled;
@property(nonatomic, assign) NSInteger reconnectDelay;
@property(nonatomic, assign) NSInteger connGen;
@property(nonatomic, assign) NSTimeInterval lastActivityAt;
@property(nonatomic, assign) NSTimeInterval reconnectAt;
@property(nonatomic, assign) uint32_t wakeAssertion;
@property(nonatomic, assign) NSTimeInterval wakeAssertionAt;
- (void)sendRawJSON:(NSString *)json;
- (void)sendRoutedSignal:(NSString *)json;
- (instancetype)initWithConfig:(NSDictionary *)config deviceID:(NSString *)deviceID;
@end

@implementation RCTLRelayClient

- (instancetype)initWithConfig:(NSDictionary *)config deviceID:(NSString *)deviceID {
    self = [super init];
    if (!self) return nil;
    NSString *url = [config[@"RelayURL"] isKindOfClass:[NSString class]] ? config[@"RelayURL"] : @"";
    NSString *label = [NSString stringWithFormat:@"com.greatlove.rctl.relay.%@", relay_random_hex(4)];
    _queue = dispatch_queue_create(label.UTF8String, DISPATCH_QUEUE_SERIAL);
    _streamIDs = [NSMutableDictionary dictionary];
    _streamTasks = [NSMutableDictionary dictionary];
    _streamSocketTasks = [NSMutableDictionary dictionary];
    _termTasks = [NSMutableDictionary dictionary];
    _reconnectDelay = 2;
    _reconnectScheduled = NO;
    _config = [config mutableCopy];
    _relayURL = [url copy];
    _deviceID = [deviceID copy];
    _routePrefix = [NSString stringWithFormat:@"%@:", relay_random_hex(8)];
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
    if (![raw[@"Enabled"] respondsToSelector:@selector(boolValue)] || ![raw[@"Enabled"] boolValue]) {
        relay_log(@"disabled: Enabled=false");
        return nil;
    }
    NSDictionary *selected = nil;
    NSArray *relays = [raw[@"Relays"] isKindOfClass:[NSArray class]] ? raw[@"Relays"] : nil;
    if (relays) {
        for (id item in relays) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *url = [item[@"RelayURL"] isKindOfClass:[NSString class]] ? item[@"RelayURL"] : nil;
            if ([url isEqualToString:self.relayURL]) { selected = item; break; }
        }
    } else if ([raw[@"RelayURL"] isEqualToString:self.relayURL]) {
        selected = raw;
    }
    if (!selected) {
        relay_log(@"disabled: relay entry removed from config");
        return nil;
    }
    NSMutableDictionary *dict = [selected mutableCopy];
    if (![dict[@"DeviceName"] isKindOfClass:[NSString class]] &&
        [raw[@"DeviceName"] isKindOfClass:[NSString class]]) {
        dict[@"DeviceName"] = raw[@"DeviceName"];
    }
    if ([dict[@"Enabled"] respondsToSelector:@selector(boolValue)] && ![dict[@"Enabled"] boolValue]) {
        relay_log(@"disabled: relay entry Enabled=false");
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
    return dict;
}

- (NSString *)tokenFromConfig:(NSDictionary *)dict {
    NSString *deviceSecret = [dict[@"DeviceSecret"] isKindOfClass:[NSString class]] ? dict[@"DeviceSecret"] : nil;
    if (deviceSecret.length >= 32) return deviceSecret;
    NSString *enrollToken = [dict[@"EnrollToken"] isKindOfClass:[NSString class]] ? dict[@"EnrollToken"] : nil;
    return enrollToken ?: @"";
}

- (void)saveConfig:(NSDictionary *)dict {
    @synchronized ([RCTLRelayClient class]) {
        NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:RCTL_RELAY_CONFIG_PLIST];
        NSMutableDictionary *root = [existing isKindOfClass:[NSDictionary class]] ? [existing mutableCopy] : [NSMutableDictionary dictionary];
        NSArray *relays = [root[@"Relays"] isKindOfClass:[NSArray class]] ? root[@"Relays"] : nil;
        if (relays) {
            NSMutableArray *updated = [relays mutableCopy];
            for (NSUInteger i = 0; i < updated.count; i++) {
                NSDictionary *item = [updated[i] isKindOfClass:[NSDictionary class]] ? updated[i] : nil;
                if ([item[@"RelayURL"] isEqualToString:self.relayURL]) {
                    updated[i] = dict;
                    break;
                }
            }
            root[@"Relays"] = updated;
        } else {
            [root addEntriesFromDictionary:dict];
        }
        root[@"DeviceID"] = self.deviceID ?: @"";
        NSString *dir = [RCTL_RELAY_CONFIG_PLIST stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (![root writeToFile:RCTL_RELAY_CONFIG_PLIST atomically:YES]) {
            relay_log(@"failed to save relay config");
        }
    }
}

- (void)connect {
    self.reconnectScheduled = NO;
    [self resetTransport];
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
        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        self.session = [NSURLSession sessionWithConfiguration:configuration delegate:(id<NSURLSessionDelegate>)self delegateQueue:delegateQueue];
        self.task = [self.session webSocketTaskWithRequest:request];
        [self.task resume];
        relay_log(@"connecting");
        self.lastActivityAt = [NSDate timeIntervalSinceReferenceDate];
        [self sendHello];
        [self receiveLoop];
        [self ensureSupervisor];
    } else {
        relay_log(@"disabled: NSURLSessionWebSocketTask requires iOS 13+");
        self.running = NO;
    }
}

- (void)resetTransport {
    self.connGen++;
    if (@available(iOS 13.0, *)) {
        [self.task cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)1001 reason:nil];
    } else {
        [self.task cancel];
    }
    self.task = nil;

    NSArray<NSURLSessionDataTask *> *tasks = nil;
    NSArray *socketTasks = nil;
    NSArray *termTasks = nil;
    @synchronized (self.streamIDs) {
        tasks = [self.streamTasks.allValues copy];
        socketTasks = [self.streamSocketTasks.allValues copy];
        termTasks = [self.termTasks.allValues copy];
        [self.streamIDs removeAllObjects];
        [self.streamTasks removeAllObjects];
        [self.streamSocketTasks removeAllObjects];
        [self.termTasks removeAllObjects];
    }
    for (NSURLSessionDataTask *task in tasks) {
        [task cancel];
    }
    for (id task in socketTasks) {
        if ([task respondsToSelector:@selector(cancelWithCloseCode:reason:)]) {
            [task cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)1001 reason:nil];
        } else if ([task respondsToSelector:@selector(cancel)]) {
            [task cancel];
        }
    }
    for (id task in termTasks) {
        if ([task respondsToSelector:@selector(cancelWithCloseCode:reason:)]) {
            [task cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)1001 reason:nil];
        } else if ([task respondsToSelector:@selector(cancel)]) {
            [task cancel];
        }
    }

    [self.session invalidateAndCancel];
    self.session = nil;
}

- (id)webSocketMessageWithString:(NSString *)text API_AVAILABLE(ios(13.0)) {
    Class cls = NSClassFromString(@"NSURLSessionWebSocketMessage");
    if (!cls) return nil;
    return [[cls alloc] initWithString:text ?: @"{}"];
}

- (id)webSocketMessageWithData:(NSData *)data API_AVAILABLE(ios(13.0)) {
    Class cls = NSClassFromString(@"NSURLSessionWebSocketMessage");
    if (!cls) return nil;
    return [[cls alloc] initWithData:data ?: [NSData data]];
}

- (void)sendHello API_AVAILABLE(ios(13.0)) {
    NSString *name = [self.config[@"DeviceName"] isKindOfClass:[NSString class]] ? self.config[@"DeviceName"] : @"rctl device";
    NSDictionary *hello = @{@"type": @"hello", @"device_id": self.deviceID ?: @"", @"device_name": name};
    NSData *data = [NSJSONSerialization dataWithJSONObject:hello options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    id message = [self webSocketMessageWithString:json];
    if (!message) {
        relay_log(@"disabled: NSURLSessionWebSocketMessage unavailable");
        self.running = NO;
        [self resetTransport];
        return;
    }
    [self.task sendMessage:message completionHandler:^(NSError *error) {
        if (error) {
            relay_log([NSString stringWithFormat:@"hello send failed: %@", error.localizedDescription]);
            dispatch_async(self.queue, ^{
                [self scheduleReconnect];
            });
        }
    }];
}

- (void)receiveLoop API_AVAILABLE(ios(13.0)) {
    [self.task receiveMessageWithCompletionHandler:^(id message, NSError *error) {
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

- (void)handleMessage:(id)message API_AVAILABLE(ios(13.0)) {
    NSData *data = nil;
    NSString *string = [message respondsToSelector:@selector(string)] ? [message string] : nil;
    if ([string isKindOfClass:[NSString class]]) {
        data = [string dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (!data.length && [message respondsToSelector:@selector(data)]) {
        NSData *messageData = [message data];
        if ([messageData isKindOfClass:[NSData class]]) data = messageData;
    }
    if (!data.length) return;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) return;
    NSString *type = [dict[@"type"] isKindOfClass:[NSString class]] ? dict[@"type"] : @"";
    self.lastActivityAt = [NSDate timeIntervalSinceReferenceDate];

    if ([type isEqualToString:@"hello_ack"]) {
        NSString *status = [dict[@"status"] isKindOfClass:[NSString class]] ? dict[@"status"] : @"unknown";
        self.reconnectDelay = 2;
        [self releaseWakeAssertion];
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
    } else if ([type isEqualToString:@"webrtc_signal"]) {
        NSString *remoteID = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : nil;
        if (!remoteID.length) return;
        NSString *internalID = [self.routePrefix stringByAppendingString:remoteID];
        NSMutableDictionary *routed = [dict mutableCopy];
        routed[@"id"] = internalID;
        NSData *routedData = [NSJSONSerialization dataWithJSONObject:routed options:0 error:nil];
        NSString *raw = [[NSString alloc] initWithData:routedData encoding:NSUTF8StringEncoding];
        if ([dict[@"kind"] isEqualToString:@"open"]) {
            rctl_webrtc_route_session(internalID.UTF8String, relay_webrtc_send_routed,
                                      (__bridge void *)self);
        }
        if (raw) rctl_webrtc_handle_signal(raw.UTF8String);
        if ([dict[@"kind"] isEqualToString:@"close"]) {
            rctl_webrtc_unroute_session(internalID.UTF8String);
        }
    } else if ([type isEqualToString:@"http_request"]) {
        [self handleHTTPRequest:dict];
    } else if ([type isEqualToString:@"stream_open"]) {
        [self handleStreamOpen:dict];
    } else if ([type isEqualToString:@"stream_cancel"]) {
        [self handleStreamCancel:dict];
    } else if ([type isEqualToString:@"term_open"]) {
        [self handleTermOpen:dict];
    } else if ([type isEqualToString:@"term_input"]) {
        [self handleTermInput:dict];
    } else if ([type isEqualToString:@"term_cancel"]) {
        [self handleTermCancel:dict];
    }
}

- (void)handleHTTPRequest:(NSDictionary *)dict API_AVAILABLE(ios(13.0)) {
    NSString *reqid = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : @"";
    NSString *method = [dict[@"method"] isKindOfClass:[NSString class]] ? dict[@"method"] : @"GET";
    NSString *path = [dict[@"path"] isKindOfClass:[NSString class]] ? dict[@"path"] : @"/";
    if (!reqid.length || ![path hasPrefix:@"/"]) {
        return;
    }

    NSString *urlString = [@"http://127.0.0.1:8080" stringByAppendingString:path];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self sendJSON:@{@"type": @"http_response", @"id": reqid, @"status": @502, @"error": @"bad_local_url"}];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    request.timeoutInterval = 20;
    NSURLSession *session = self.session;
    if (!session) {
        [self sendJSON:@{@"type": @"http_response", @"id": reqid, @"status": @502, @"error": @"relay_not_connected"}];
        return;
    }

    NSDictionary *headers = [dict[@"headers"] isKindOfClass:[NSDictionary class]] ? dict[@"headers"] : @{};
    NSString *contentType = [headers[@"content-type"] isKindOfClass:[NSString class]] ? headers[@"content-type"] : nil;
    if (contentType.length) [request setValue:contentType forHTTPHeaderField:@"Content-Type"];
    NSString *accept = [headers[@"accept"] isKindOfClass:[NSString class]] ? headers[@"accept"] : nil;
    if (accept.length) [request setValue:accept forHTTPHeaderField:@"Accept"];

    NSString *body64 = [dict[@"body"] isKindOfClass:[NSString class]] ? dict[@"body"] : nil;
    if (body64.length) {
        NSData *body = [[NSData alloc] initWithBase64EncodedString:body64 options:0];
        request.HTTPBody = body;
    }

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(self.queue, ^{
            if (error) {
                [self sendJSON:@{@"type": @"http_response", @"id": reqid, @"status": @502, @"error": @"local_request_failed"}];
                return;
            }
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            NSInteger status = http ? http.statusCode : 502;
            NSString *ctype = http.allHeaderFields[@"Content-Type"];
            NSData *payload = data ?: [NSData data];
            NSString *encoded = [payload base64EncodedStringWithOptions:0] ?: @"";
            // A single multi-MB WebSocket message tears down the connection on iOS
            // (NSURLSessionWebSocketTask), which kills the relay link mid-response.
            // Split a large body into small ordered chunks the relay reassembles;
            // small responses keep the original single-message path.
            const NSUInteger kChunk = 256 * 1024;
            if (encoded.length > kChunk) {
                NSMutableArray<NSString *> *pieces = [NSMutableArray array];
                for (NSUInteger off = 0; off < encoded.length; off += kChunk) {
                    [pieces addObject:[encoded substringWithRange:NSMakeRange(off, MIN(kChunk, encoded.length - off))]];
                }
                NSMutableDictionary *end = [@{@"type": @"http_response_end",
                                              @"id": reqid, @"status": @(status)} mutableCopy];
                if ([ctype isKindOfClass:[NSString class]] && ctype.length) end[@"content_type"] = ctype;
                [self sendHTTPChunks:pieces at:0 end:end];   // paced: one chunk in flight at a time
            } else {
                NSMutableDictionary *reply = [@{@"type": @"http_response",
                                                @"id": reqid,
                                                @"status": @(status),
                                                @"body": encoded} mutableCopy];
                if ([ctype isKindOfClass:[NSString class]] && ctype.length) reply[@"content_type"] = ctype;
                [self sendJSON:reply];
            }
        });
    }];
    [task resume];
}

- (void)handleStreamOpen:(NSDictionary *)dict API_AVAILABLE(ios(13.0)) {
    NSString *streamID = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : @"";
    NSString *path = [dict[@"path"] isKindOfClass:[NSString class]] ? dict[@"path"] : @"/stream";
    if (!streamID.length || ![path hasPrefix:@"/"]) return;
    NSString *streamURL = [dict[@"stream_url"] isKindOfClass:[NSString class]] ? dict[@"stream_url"] : nil;
    if ([streamURL hasPrefix:@"wss://"] || [streamURL hasPrefix:@"ws://"]) {
        [self handleBinaryStreamOpen:streamID path:path streamURL:streamURL];
        return;
    }

    NSString *urlString = [@"http://127.0.0.1:8080" stringByAppendingString:path];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self sendJSON:@{@"type": @"stream_start", @"id": streamID, @"status": @502, @"error": @"bad_local_url"}];
        [self sendJSON:@{@"type": @"stream_end", @"id": streamID}];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 0;
    NSURLSession *session = self.session;
    if (!session) {
        [self sendJSON:@{@"type": @"stream_start", @"id": streamID, @"status": @502, @"error": @"relay_not_connected"}];
        [self sendJSON:@{@"type": @"stream_end", @"id": streamID}];
        return;
    }
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    @synchronized (self.streamIDs) {
        self.streamIDs[@(task.taskIdentifier)] = streamID;
        self.streamTasks[streamID] = task;
    }
    [task resume];
}

- (void)handleBinaryStreamOpen:(NSString *)streamID path:(NSString *)path streamURL:(NSString *)streamURL API_AVAILABLE(ios(13.0)) {
    NSString *urlString = [@"http://127.0.0.1:8080" stringByAppendingString:path];
    NSURL *localURL = [NSURL URLWithString:urlString];
    NSURL *remoteURL = [NSURL URLWithString:streamURL];
    if (!localURL || !remoteURL) {
        [self sendJSON:@{@"type": @"stream_start", @"id": streamID, @"status": @502, @"error": @"bad_stream_url"}];
        [self sendJSON:@{@"type": @"stream_end", @"id": streamID}];
        return;
    }

    NSURLSession *session = self.session;
    if (!session) {
        [self sendJSON:@{@"type": @"stream_start", @"id": streamID, @"status": @502, @"error": @"relay_not_connected"}];
        [self sendJSON:@{@"type": @"stream_end", @"id": streamID}];
        return;
    }

    NSMutableURLRequest *wsRequest = [NSMutableURLRequest requestWithURL:remoteURL];
    NSString *token = [self tokenFromConfig:self.config];
    [wsRequest setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    id wsTask = [session webSocketTaskWithRequest:wsRequest];

    NSMutableURLRequest *localRequest = [NSMutableURLRequest requestWithURL:localURL];
    localRequest.HTTPMethod = @"GET";
    localRequest.timeoutInterval = 0;
    NSURLSessionDataTask *localTask = [session dataTaskWithRequest:localRequest];

    @synchronized (self.streamIDs) {
        self.streamIDs[@(localTask.taskIdentifier)] = streamID;
        self.streamTasks[streamID] = localTask;
        self.streamSocketTasks[streamID] = wsTask;
    }

    [wsTask resume];
    [localTask resume];
}

- (void)handleStreamCancel:(NSDictionary *)dict API_AVAILABLE(ios(13.0)) {
    NSString *streamID = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : @"";
    if (!streamID.length) return;
    NSURLSessionDataTask *task = nil;
    id wsTask = nil;
    @synchronized (self.streamIDs) {
        task = self.streamTasks[streamID];
        wsTask = self.streamSocketTasks[streamID];
        [self.streamTasks removeObjectForKey:streamID];
        [self.streamSocketTasks removeObjectForKey:streamID];
        if (task) [self.streamIDs removeObjectForKey:@(task.taskIdentifier)];
    }
    [task cancel];
    if ([wsTask respondsToSelector:@selector(cancelWithCloseCode:reason:)]) {
        [wsTask cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)1001 reason:nil];
    } else if ([wsTask respondsToSelector:@selector(cancel)]) {
        [wsTask cancel];
    }
}

- (void)handleTermOpen:(NSDictionary *)dict API_AVAILABLE(ios(13.0)) {
    NSString *termID = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : @"";
    if (!termID.length) return;
    NSInteger cols = [dict[@"cols"] respondsToSelector:@selector(integerValue)] ? [dict[@"cols"] integerValue] : 100;
    NSInteger rows = [dict[@"rows"] respondsToSelector:@selector(integerValue)] ? [dict[@"rows"] integerValue] : 30;
    if (cols < 20) cols = 20;
    if (rows < 5) rows = 5;

    NSString *urlString = [NSString stringWithFormat:@"ws://127.0.0.1:8080/ws/term?cols=%ld&rows=%ld", (long)cols, (long)rows];
    NSURL *url = [NSURL URLWithString:urlString];
    NSURLSession *session = self.session;
    if (!url || !session) {
        [self sendJSON:@{@"type": @"term_error", @"id": termID, @"error": @"term_not_available"}];
        return;
    }

    id oldTask = nil;
    @synchronized (self.streamIDs) {
        oldTask = self.termTasks[termID];
        self.termTasks[termID] = [session webSocketTaskWithURL:url];
    }
    if ([oldTask respondsToSelector:@selector(cancelWithCloseCode:reason:)]) {
        [oldTask cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)1001 reason:nil];
    }

    id task = nil;
    @synchronized (self.streamIDs) {
        task = self.termTasks[termID];
    }
    [task resume];
    [self receiveTermLoop:termID task:task];
}

- (void)handleTermInput:(NSDictionary *)dict API_AVAILABLE(ios(13.0)) {
    NSString *termID = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : @"";
    NSString *body = [dict[@"body"] isKindOfClass:[NSString class]] ? dict[@"body"] : @"";
    if (!termID.length || !body.length) return;
    NSData *payload = [[NSData alloc] initWithBase64EncodedString:body options:0];
    if (!payload.length) return;
    id task = nil;
    @synchronized (self.streamIDs) {
        task = self.termTasks[termID];
    }
    if (!task) {
        [self sendJSON:@{@"type": @"term_error", @"id": termID, @"error": @"term_not_open"}];
        return;
    }
    [self sendData:payload toWebSocketTask:task completion:nil];
}

- (void)handleTermCancel:(NSDictionary *)dict API_AVAILABLE(ios(13.0)) {
    NSString *termID = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : @"";
    if (!termID.length) return;
    id task = nil;
    @synchronized (self.streamIDs) {
        task = self.termTasks[termID];
        [self.termTasks removeObjectForKey:termID];
    }
    if ([task respondsToSelector:@selector(cancelWithCloseCode:reason:)]) {
        [task cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)1000 reason:nil];
    } else if ([task respondsToSelector:@selector(cancel)]) {
        [task cancel];
    }
}

- (void)receiveTermLoop:(NSString *)termID task:(id)task API_AVAILABLE(ios(13.0)) {
    if (!termID.length || !task) return;
    [task receiveMessageWithCompletionHandler:^(id message, NSError *error) {
        dispatch_async(self.queue, ^{
            id current = nil;
            @synchronized (self.streamIDs) {
                current = self.termTasks[termID];
            }
            if (current != task) return;
            if (error) {
                @synchronized (self.streamIDs) {
                    if (self.termTasks[termID] == task) [self.termTasks removeObjectForKey:termID];
                }
                [self sendJSON:@{@"type": @"term_close", @"id": termID}];
                return;
            }
            NSData *data = nil;
            if ([message respondsToSelector:@selector(data)]) {
                NSData *messageData = [message data];
                if ([messageData isKindOfClass:[NSData class]]) data = messageData;
            }
            if (!data.length && [message respondsToSelector:@selector(string)]) {
                NSString *text = [message string];
                if ([text isKindOfClass:[NSString class]]) data = [text dataUsingEncoding:NSUTF8StringEncoding];
            }
            if (data.length) {
                NSString *encoded = [data base64EncodedStringWithOptions:0] ?: @"";
                [self sendJSON:@{@"type": @"term_data", @"id": termID, @"body": encoded}];
            }
            [self receiveTermLoop:termID task:task];
        });
    }];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    NSString *streamID = nil;
    @synchronized (self.streamIDs) {
        streamID = self.streamIDs[@(dataTask.taskIdentifier)];
    }
    if (!streamID) {
        completionHandler(NSURLSessionResponseAllow);
        return;
    }
    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSInteger status = http ? http.statusCode : 200;
    NSString *ctype = [http valueForHTTPHeaderField:@"Content-Type"];
    NSString *disposition = [http valueForHTTPHeaderField:@"Content-Disposition"];
    long long contentLength = response.expectedContentLength;
    dispatch_async(self.queue, ^{
        NSMutableDictionary *msg = [@{@"type": @"stream_start", @"id": streamID, @"status": @(status)} mutableCopy];
        if ([ctype isKindOfClass:[NSString class]] && ctype.length) msg[@"content_type"] = ctype;
        if ([disposition isKindOfClass:[NSString class]] && disposition.length)
            msg[@"content_disposition"] = disposition;
        if (contentLength >= 0) msg[@"content_length"] = @(contentLength);
        id wsTask = nil;
        @synchronized (self.streamIDs) {
            wsTask = self.streamSocketTasks[streamID];
        }
        if (wsTask) {
            [self sendJSON:msg toWebSocketTask:wsTask completion:nil];
        } else {
            [self sendJSON:msg];
        }
    });
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    NSString *streamID = nil;
    @synchronized (self.streamIDs) {
        streamID = self.streamIDs[@(dataTask.taskIdentifier)];
    }
    if (!streamID || !data.length) return;
    [dataTask suspend];
    dispatch_async(self.queue, ^{
        id wsTask = nil;
        @synchronized (self.streamIDs) {
            wsTask = self.streamSocketTasks[streamID];
        }
        if (wsTask) {
            [self sendData:data toWebSocketTask:wsTask completion:^{
                [dataTask resume];
            }];
        } else {
            NSString *encoded = [data base64EncodedStringWithOptions:0] ?: @"";
            [self sendJSON:@{@"type": @"stream_chunk", @"id": streamID, @"body": encoded} completion:^{
                [dataTask resume];
            }];
        }
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSString *streamID = nil;
    id wsTask = nil;
    @synchronized (self.streamIDs) {
        streamID = self.streamIDs[@(task.taskIdentifier)];
        if (streamID) {
            wsTask = self.streamSocketTasks[streamID];
            [self.streamIDs removeObjectForKey:@(task.taskIdentifier)];
            [self.streamTasks removeObjectForKey:streamID];
            [self.streamSocketTasks removeObjectForKey:streamID];
        }
    }
    if (!streamID) return;
    dispatch_async(self.queue, ^{
        NSMutableDictionary *msg = [@{@"type": @"stream_end", @"id": streamID} mutableCopy];
        if (error) msg[@"error"] = @"local_stream_failed";
        if (wsTask) {
            [self sendJSON:msg toWebSocketTask:wsTask completion:^{
                if ([wsTask respondsToSelector:@selector(cancelWithCloseCode:reason:)]) {
                    [wsTask cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)1000 reason:nil];
                }
            }];
        } else {
            [self sendJSON:msg];
        }
    });
}

- (void)sendJSON:(NSDictionary *)dict API_AVAILABLE(ios(13.0)) {
    [self sendJSON:dict completion:nil];
}

- (void)sendRawJSON:(NSString *)json API_AVAILABLE(ios(13.0)) {
    if (!json.length) return;
    dispatch_async(self.queue, ^{
        id task = self.task;
        if (!task) return;
        id message = [self webSocketMessageWithString:json];
        if (!message) return;
        [task sendMessage:message completionHandler:^(NSError *error) {
            if (error) relay_log([NSString stringWithFormat:@"webrtc send failed: %@", error.localizedDescription]);
        }];
    });
}

// WebRTC session ids are namespaced inside rctld so two independent relay
// servers cannot collide. Strip this client's private prefix before returning
// signaling to the relay that owns the browser session.
- (void)sendRoutedSignal:(NSString *)json API_AVAILABLE(ios(13.0)) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *dict = [[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    NSString *internalID = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : nil;
    if (!internalID.length || ![internalID hasPrefix:self.routePrefix]) return;
    dict[@"id"] = [internalID substringFromIndex:self.routePrefix.length];
    NSData *out = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    NSString *wire = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
    if (wire.length) [self sendRawJSON:wire];
}

- (void)sendJSON:(NSDictionary *)dict completion:(void (^)(void))completion API_AVAILABLE(ios(13.0)) {
    [self sendJSON:dict toWebSocketTask:self.task completion:completion];
}

// Send a chunked response paced one frame at a time: each next chunk goes only
// after the previous send completes, so the WS send buffer never holds more than
// one ~256KB frame. Bursting all chunks at once buffers MBs and tears down the
// NSURLSessionWebSocketTask connection (the camera/large-response EOF).
- (void)sendHTTPChunks:(NSArray<NSString *> *)pieces at:(NSUInteger)idx end:(NSDictionary *)endMsg API_AVAILABLE(ios(13.0)) {
    if (idx >= pieces.count) { [self sendJSON:endMsg]; return; }
    __weak typeof(self) wself = self;
    [self sendJSON:@{@"type": @"http_response_chunk", @"id": endMsg[@"id"] ?: @"", @"data": pieces[idx]}
        completion:^{ [wself sendHTTPChunks:pieces at:idx + 1 end:endMsg]; }];
}

- (void)sendJSON:(NSDictionary *)dict toWebSocketTask:(id)task completion:(void (^)(void))completion API_AVAILABLE(ios(13.0)) {
    void (^finish)(void) = ^{
        if (completion) completion();
    };
    if (!task) {
        finish();
        return;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    id message = [self webSocketMessageWithString:json];
    if (!message) {
        relay_log(@"send failed: NSURLSessionWebSocketMessage unavailable");
        [self scheduleReconnect];
        finish();
        return;
    }
    [task sendMessage:message completionHandler:^(NSError *error) {
        if (error) {
            relay_log([NSString stringWithFormat:@"send failed: %@", error.localizedDescription]);
            if (task == self.task) {
                dispatch_async(self.queue, ^{
                    [self scheduleReconnect];
                });
            }
        }
        finish();
    }];
}

- (void)sendData:(NSData *)data toWebSocketTask:(id)task completion:(void (^)(void))completion API_AVAILABLE(ios(13.0)) {
    void (^finish)(void) = ^{
        if (completion) completion();
    };
    if (!task) {
        finish();
        return;
    }
    id message = [self webSocketMessageWithData:data];
    if (!message) {
        relay_log(@"send failed: NSURLSessionWebSocketMessage unavailable");
        finish();
        return;
    }
    [task sendMessage:message completionHandler:^(NSError *error) {
        if (error) relay_log([NSString stringWithFormat:@"stream send failed: %@", error.localizedDescription]);
        finish();
    }];
}

// Start the supervisor pthread once; it lives for the daemon's lifetime and
// ticks the serial queue on a cadence iOS does not defer the way it defers
// background GCD timers.
- (void)ensureSupervisor {
    pthread_mutex_lock(&g_supervisor_mutex);
    BOOL needStart = !g_supervisor_started;
    if (needStart) {
        g_supervisor_started = YES;
        g_supervisor_stop = NO;
    }
    pthread_mutex_unlock(&g_supervisor_mutex);
    if (!needStart) return;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&g_supervisor_thread, &attr, relay_supervisor_main, NULL) != 0) {
        pthread_mutex_lock(&g_supervisor_mutex);
        g_supervisor_started = NO;
        pthread_mutex_unlock(&g_supervisor_mutex);
        relay_log(@"supervisor: thread failed to start");
    }
    pthread_attr_destroy(&attr);
}

- (void)supervisorWake {
    dispatch_async(self.queue, ^{
        [self supervisorTick];
    });
}

// Runs on the serial queue, ticked by the un-throttled supervisor thread. Owns
// the liveness check and reconnect timing that used to live on GCD timers: it
// pings while connected, reconnects a stale/half-open link, and fires a pending
// reconnect once due.
- (void)supervisorTick {
    if (!self.running) {
        [self releaseWakeAssertion];
        return;
    }
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (self.wakeAssertion != 0 && now - self.wakeAssertionAt > 90.0) {
        [self releaseWakeAssertion];   // cap: don't stay awake through a long outage
    }
    if (self.task) {
        if (now - self.lastActivityAt > 40.0) {          // ~3 missed pings: dead/half-open
            relay_log(@"supervisor: link stale, reconnecting");
            [self scheduleReconnect];
            return;
        }
        [self sendKeepAlivePing];
    } else if (self.reconnectAt > 0.0 && now >= self.reconnectAt) {
        self.reconnectAt = 0.0;
        [self connect];
    }
}

- (void)sendKeepAlivePing {
    id task = self.task;
    if (![task respondsToSelector:@selector(sendPingWithPongReceiveHandler:)]) return;
    NSInteger gen = self.connGen;
    [task sendPingWithPongReceiveHandler:^(NSError *error) {
        dispatch_async(self.queue, ^{
            if (gen != self.connGen) return;
            if (error) {
                relay_log([NSString stringWithFormat:@"keepalive ping failed: %@", error.localizedDescription]);
                [self scheduleReconnect];
            } else {
                self.lastActivityAt = [NSDate timeIntervalSinceReferenceDate];
            }
        });
    }];
}

// Keep the device awake ONLY while reconnecting. The disconnect that triggers a
// reconnect is itself an inbound network event, so the device is briefly awake
// at that moment — grab the assertion before it re-sleeps and hold it until we
// reconnect (capped in supervisorTick), so the reconnect isn't stuck waiting for
// the next time something else happens to wake the device. Released the instant
// we connect, so steady-state idle costs nothing.
- (void)takeWakeAssertion {
    if (self.wakeAssertion != 0) return;
    RCTLPMAssertionID aid = 0;
    int rc = IOPMAssertionCreateWithName(CFSTR("PreventUserIdleSystemSleep"), 255,
                                         CFSTR("com.greatlove.rctl.relay.reconnect"), &aid);
    if (rc == 0 && aid != 0) {
        self.wakeAssertion = aid;
        self.wakeAssertionAt = [NSDate timeIntervalSinceReferenceDate];
        relay_log(@"wake assertion held for reconnect");
    }
}

- (void)releaseWakeAssertion {
    if (self.wakeAssertion == 0) return;
    IOPMAssertionRelease(self.wakeAssertion);
    self.wakeAssertion = 0;
    relay_log(@"wake assertion released");
}

- (void)scheduleReconnect {
    if (!self.running) return;
    if (self.reconnectScheduled) return;
    self.reconnectScheduled = YES;
    [self takeWakeAssertion];
    [self resetTransport];
    NSInteger delay = self.reconnectDelay;
    self.reconnectDelay = MIN(self.reconnectDelay * 2, 60);
    uint32_t jitterMs = arc4random_uniform(1000);
    self.reconnectAt = [NSDate timeIntervalSinceReferenceDate] + (NSTimeInterval)delay + (NSTimeInterval)jitterMs / 1000.0;
    relay_log([NSString stringWithFormat:@"reconnect in %lds + %ums jitter", (long)delay, jitterMs]);
    [self ensureSupervisor];
}

@end

static void *relay_supervisor_main(void *arg) {
    (void)arg;
    pthread_setname_np("com.greatlove.rctl.relay.supervisor");
    while (1) {
        struct timespec rel = { .tv_sec = 12, .tv_nsec = 0 };
        pthread_mutex_lock(&g_supervisor_mutex);
        pthread_cond_timedwait_relative_np(&g_supervisor_cond, &g_supervisor_mutex, &rel);
        BOOL stop = g_supervisor_stop;
        pthread_mutex_unlock(&g_supervisor_mutex);
        if (stop) break;
        @autoreleasepool {
            NSArray *clients = nil;
            @synchronized ([RCTLRelayClient class]) {
                clients = [g_relay_clients copy];
            }
            for (RCTLRelayClient *client in clients) [client supervisorWake];
        }
    }
    return NULL;
}

static void relay_webrtc_send_routed(void *ctx, const char *json) {
    if (!ctx || !json) return;
    RCTLRelayClient *client = (__bridge RCTLRelayClient *)ctx;
    [client sendRoutedSignal:[NSString stringWithUTF8String:json]];
}

void rctl_relay_start(void) {
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:RCTL_RELAY_CONFIG_PLIST];
    if (![raw isKindOfClass:[NSDictionary class]] ||
        ![raw[@"Enabled"] respondsToSelector:@selector(boolValue)] || ![raw[@"Enabled"] boolValue]) {
        relay_log(@"disabled: config plist missing or Enabled=false");
        return;
    }

    NSMutableDictionary *root = [raw mutableCopy];
    NSString *deviceID = [root[@"DeviceID"] isKindOfClass:[NSString class]] ? root[@"DeviceID"] : nil;
    if (deviceID.length < 16) {
        deviceID = relay_random_hex(16);
        root[@"DeviceID"] = deviceID;
        if (![root writeToFile:RCTL_RELAY_CONFIG_PLIST atomically:YES]) {
            relay_log(@"disabled: failed to persist DeviceID");
            return;
        }
    }

    NSArray *configured = [root[@"Relays"] isKindOfClass:[NSArray class]] ? root[@"Relays"] : nil;
    if (!configured) configured = @[root]; // legacy single-relay plist
    NSMutableArray *clients = [NSMutableArray array];
    NSMutableSet *urls = [NSMutableSet set];
    for (id item in configured) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *entry = [item mutableCopy];
        if (![entry[@"DeviceName"] isKindOfClass:[NSString class]] &&
            [root[@"DeviceName"] isKindOfClass:[NSString class]]) {
            entry[@"DeviceName"] = root[@"DeviceName"];
        }
        if ([entry[@"Enabled"] respondsToSelector:@selector(boolValue)] && ![entry[@"Enabled"] boolValue]) continue;
        NSString *url = [entry[@"RelayURL"] isKindOfClass:[NSString class]] ? entry[@"RelayURL"] : nil;
        NSString *secret = [entry[@"DeviceSecret"] isKindOfClass:[NSString class]] ? entry[@"DeviceSecret"] : nil;
        NSString *enroll = [entry[@"EnrollToken"] isKindOfClass:[NSString class]] ? entry[@"EnrollToken"] : nil;
        if (![url hasPrefix:@"wss://"] || (secret.length < 32 && enroll.length < 32) || [urls containsObject:url]) {
            relay_log(@"skipping invalid or duplicate relay entry");
            continue;
        }
        [urls addObject:url];
        RCTLRelayClient *client = [[RCTLRelayClient alloc] initWithConfig:entry deviceID:deviceID];
        if (client) [clients addObject:client];
    }
    if (!clients.count) {
        relay_log(@"disabled: no usable relay entries");
        return;
    }
    @synchronized ([RCTLRelayClient class]) {
        g_relay_clients = clients;
    }
    // Every relay session installs an explicit namespaced sender route before the
    // bridge creates its PeerConnection. There is intentionally no global sender.
    rctl_webrtc_set_sender(NULL);
    relay_log([NSString stringWithFormat:@"starting %lu relay connection(s)", (unsigned long)clients.count]);
    for (RCTLRelayClient *client in clients) [client start];
}
