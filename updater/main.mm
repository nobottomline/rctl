#import <Foundation/Foundation.h>
#import <mbedtls/pk.h>
#import <mbedtls/sha256.h>
#import <fcntl.h>
#import <signal.h>
#import <spawn.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#include <errno.h>
#include <time.h>
#include <vector>

extern char **environ;

static NSString *const kPackageID = @"com.greatlove.rctl";
static NSString *const kStateRoot = @"/var/mobile/Library/Caches/com.greatlove.rctl/update";
static NSString *const kStatusPath = @"/var/mobile/Library/Caches/com.greatlove.rctl/update/status.json";
static NSString *const kLaunchGuard = @"/var/mobile/Library/Caches/com.greatlove.rctl/update/active.request";
static NSString *const kRelayPreferences = @"/var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist";
static NSString *const kPublicKeyPath = @"/usr/local/share/rctl/update-public-key.pem";
static const NSUInteger kMaximumManifestBytes = 1 << 20;
static const unsigned long long kMaximumArtifactBytes = 512ULL << 20;
static char *gCleanupRequest = nullptr;

static void cleanupTemporaryLauncher(void) {
    if (gCleanupRequest) unlink(gCleanupRequest);
    free(gCleanupRequest);
    gCleanupRequest = nullptr;
}

static void ensureDirectory(NSString *path) {
    [NSFileManager.defaultManager createDirectoryAtPath:path
                            withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions: @0700}
                                                  error:nil];
    chmod(path.fileSystemRepresentation, 0700);
}

static void writeJSON(NSString *path, NSDictionary *value, mode_t mode) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data) return;
    NSString *temporary = [path stringByAppendingFormat:@".tmp.%d", getpid()];
    if ([data writeToFile:temporary atomically:NO]) {
        chmod(temporary.fileSystemRepresentation, mode);
        rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation);
    }
}

static void writeStatus(NSString *job, NSString *phase, NSString *message,
                        NSString *fromVersion, NSString *toVersion, BOOL terminal) {
    ensureDirectory(kStateRoot);
    writeJSON(kStatusPath, @{
        @"job_id": job ?: @"",
        @"phase": phase ?: @"unknown",
        @"message": message ?: @"",
        @"from_version": fromVersion ?: @"",
        @"to_version": toVersion ?: @"",
        @"terminal": @(terminal),
        @"updated_at": @((long long)time(nullptr)),
    }, 0644);
}

static void touchFile(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT, 0600);
    if (fd >= 0) {
        ftruncate(fd, 0);
        const char byte = '1';
        write(fd, &byte, 1);
        close(fd);
    }
}

static NSDictionary *readJSONObject(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (!data) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSString *installedVersion(void) {
    for (NSString *path in @[@"/var/lib/dpkg/status", @"/var/jb/var/lib/dpkg/status"]) {
        NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!raw) continue;
        for (NSString *stanza in [raw componentsSeparatedByString:@"\n\n"]) {
            BOOL package = NO, installed = NO;
            NSString *version = nil;
            for (NSString *line in [stanza componentsSeparatedByString:@"\n"]) {
                if ([line isEqualToString:[@"Package: " stringByAppendingString:kPackageID]]) package = YES;
                else if ([line hasPrefix:@"Status: "] && [line containsString:@" installed"]) installed = YES;
                else if ([line hasPrefix:@"Version: "]) version = [line substringFromIndex:9];
            }
            if (package && installed && version.length) return version;
        }
    }
    return nil;
}

static BOOL secureHTTPSURL(NSString *value) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    return [parts.scheme.lowercaseString isEqualToString:@"https"] && parts.host.length > 0 &&
           parts.user.length == 0 && parts.password.length == 0 && parts.fragment.length == 0;
}

@interface RCTLBoundedDownload : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property(nonatomic, assign) unsigned long long maximum;
@property(nonatomic, assign) unsigned long long received;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, assign) int outputFD;
@property(nonatomic, copy) NSString *failure;
@property(nonatomic, strong) dispatch_semaphore_t done;
@end

@implementation RCTLBoundedDownload
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                        newRequest:(NSURLRequest *)request
                  completionHandler:(void (^)(NSURLRequest *))completionHandler {
    if (!secureHTTPSURL(request.URL.absoluteString)) {
        self.failure = @"insecure download redirect rejected";
        completionHandler(nil);
        [task cancel];
        return;
    }
    completionHandler(request);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
 didReceiveResponse:(NSURLResponse *)response
  completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    NSInteger status = [(NSHTTPURLResponse *)response statusCode];
    long long expected = response.expectedContentLength;
    if (status < 200 || status >= 300) self.failure = [NSString stringWithFormat:@"HTTP %ld", (long)status];
    else if (expected > 0 && (unsigned long long)expected > self.maximum) self.failure = @"response exceeds size limit";
    completionHandler(self.failure ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (self.failure) return;
    if (data.length > self.maximum - self.received) {
        self.failure = @"response exceeds size limit";
        [dataTask cancel];
        return;
    }
    self.received += data.length;
    if (self.outputFD >= 0) {
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        NSUInteger written = 0;
        while (written < data.length) {
            ssize_t count = write(self.outputFD, bytes + written, data.length - written);
            if (count <= 0) {
                self.failure = @"artifact write failed";
                [dataTask cancel];
                return;
            }
            written += (NSUInteger)count;
        }
    } else {
        [self.data appendData:data];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error && !self.failure) self.failure = error.localizedDescription;
    dispatch_semaphore_signal(self.done);
}
@end

static RCTLBoundedDownload *startBoundedDownload(NSString *url, unsigned long long maximum,
                                                 int outputFD, NSTimeInterval timeout) {
    RCTLBoundedDownload *delegate = [RCTLBoundedDownload new];
    delegate.maximum = maximum;
    delegate.data = outputFD < 0 ? [NSMutableData data] : nil;
    delegate.outputFD = outputFD;
    delegate.done = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = timeout;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
    [[session dataTaskWithURL:[NSURL URLWithString:url]] resume];
    if (dispatch_semaphore_wait(delegate.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 10) * NSEC_PER_SEC))) != 0) {
        delegate.failure = @"download timed out";
        [session invalidateAndCancel];
        // Do not let a late delegate callback write through an fd the caller has
        // already closed. Cancellation completion is expected promptly.
        dispatch_semaphore_wait(delegate.done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    } else {
        [session finishTasksAndInvalidate];
    }
    return delegate;
}

static NSData *downloadData(NSString *url, NSUInteger maximum, NSString **errorOut) {
    if (!secureHTTPSURL(url)) {
        if (errorOut) *errorOut = @"download URL must be HTTPS without credentials";
        return nil;
    }
    RCTLBoundedDownload *download = startBoundedDownload(url, maximum, -1, 60);
    if (download.failure && errorOut) *errorOut = download.failure;
    return download.failure ? nil : download.data;
}

static BOOL downloadFile(NSString *url, NSString *destination, unsigned long long maximum,
                         NSString **errorOut) {
    if (!secureHTTPSURL(url)) {
        if (errorOut) *errorOut = @"artifact URL must be HTTPS without credentials";
        return NO;
    }
    NSString *temporary = [destination stringByAppendingString:@".download"];
    unlink(temporary.fileSystemRepresentation);
    int output = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (output < 0) {
        if (errorOut) *errorOut = @"artifact destination unavailable";
        return NO;
    }
    RCTLBoundedDownload *download = startBoundedDownload(url, maximum, output, 20 * 60);
    BOOL synced = fsync(output) == 0;
    close(output);
    if (download.failure || !synced || rename(temporary.fileSystemRepresentation, destination.fileSystemRepresentation) != 0) {
        unlink(temporary.fileSystemRepresentation);
        if (errorOut) *errorOut = download.failure ?: @"artifact commit failed";
        return NO;
    }
    return YES;
}

static NSString *sha256File(NSString *path) {
    FILE *file = fopen(path.fileSystemRepresentation, "rb");
    if (!file) return nil;
    mbedtls_sha256_context context;
    mbedtls_sha256_init(&context);
    mbedtls_sha256_starts(&context, 0);
    unsigned char buffer[64 * 1024];
    size_t count = 0;
    while ((count = fread(buffer, 1, sizeof(buffer), file)) > 0) {
        mbedtls_sha256_update(&context, buffer, count);
    }
    BOOL readOK = ferror(file) == 0;
    fclose(file);
    unsigned char digest[32];
    mbedtls_sha256_finish(&context, digest);
    mbedtls_sha256_free(&context);
    if (!readOK) return nil;
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (unsigned char byte : digest) [hex appendFormat:@"%02x", byte];
    return hex;
}

static BOOL verifyEnvelope(NSData *envelopeData, NSDictionary **payloadOut, NSString **errorOut) {
    id object = [NSJSONSerialization JSONObjectWithData:envelopeData options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class]) {
        if (errorOut) *errorOut = @"manifest envelope is not JSON";
        return NO;
    }
    NSString *payload64 = [object[@"payload"] isKindOfClass:NSString.class] ? object[@"payload"] : nil;
    NSString *signature64 = [object[@"signature"] isKindOfClass:NSString.class] ? object[@"signature"] : nil;
    NSData *payload = [[NSData alloc] initWithBase64EncodedString:payload64 ?: @"" options:0];
    NSData *signature = [[NSData alloc] initWithBase64EncodedString:signature64 ?: @"" options:0];
    NSMutableData *key = [[NSData dataWithContentsOfFile:kPublicKeyPath] mutableCopy];
    if (!payload.length || !signature.length || !key.length) {
        if (errorOut) *errorOut = @"manifest signature material missing";
        return NO;
    }
    unsigned char zero = 0;
    [key appendBytes:&zero length:1];
    unsigned char digest[32];
    mbedtls_sha256((const unsigned char *)payload.bytes, payload.length, digest, 0);
    mbedtls_pk_context publicKey;
    mbedtls_pk_init(&publicKey);
    int rc = mbedtls_pk_parse_public_key(&publicKey, (const unsigned char *)key.bytes, key.length);
    if (rc == 0) rc = mbedtls_pk_verify(&publicKey, MBEDTLS_MD_SHA256, digest, sizeof(digest),
                                        (const unsigned char *)signature.bytes, signature.length);
    mbedtls_pk_free(&publicKey);
    if (rc != 0) {
        if (errorOut) *errorOut = @"manifest signature rejected";
        return NO;
    }
    id payloadJSON = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    if (![payloadJSON isKindOfClass:NSDictionary.class]) {
        if (errorOut) *errorOut = @"signed payload is invalid";
        return NO;
    }
    *payloadOut = payloadJSON;
    return YES;
}

static NSDictionary *artifactForVersion(NSDictionary *payload, NSString *version) {
    NSArray *artifacts = [payload[@"artifacts"] isKindOfClass:NSArray.class] ? payload[@"artifacts"] : nil;
    for (id value in artifacts) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *artifact = value;
        if ([artifact[@"version"] isEqualToString:version]) return artifact;
    }
    return nil;
}

static BOOL validateArtifact(NSDictionary *artifact, NSString **errorOut) {
    NSString *version = [artifact[@"version"] isKindOfClass:NSString.class] ? artifact[@"version"] : nil;
    NSString *url = [artifact[@"url"] isKindOfClass:NSString.class] ? artifact[@"url"] : nil;
    NSString *sha = [artifact[@"sha256"] isKindOfClass:NSString.class] ? [artifact[@"sha256"] lowercaseString] : nil;
    NSNumber *size = [artifact[@"size"] isKindOfClass:NSNumber.class] ? artifact[@"size"] : nil;
    NSCharacterSet *nonHex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet;
    if (!version.length || !secureHTTPSURL(url) || sha.length != 64 || [sha rangeOfCharacterFromSet:nonHex].location != NSNotFound ||
        size.unsignedLongLongValue == 0 || size.unsignedLongLongValue > kMaximumArtifactBytes) {
        if (errorOut) *errorOut = @"signed artifact metadata invalid";
        return NO;
    }
    return YES;
}

static int runProcess(NSString *executable, NSArray<NSString *> *arguments, NSString *logPath) {
    NSMutableArray<NSData *> *storage = [NSMutableArray array];
    std::vector<char *> argv;
    NSData *exeData = [[executable stringByAppendingString:@"\0"] dataUsingEncoding:NSUTF8StringEncoding];
    [storage addObject:exeData];
    argv.push_back((char *)exeData.bytes);
    for (NSString *argument in arguments) {
        NSData *data = [[argument stringByAppendingString:@"\0"] dataUsingEncoding:NSUTF8StringEncoding];
        [storage addObject:data];
        argv.push_back((char *)data.bytes);
    }
    argv.push_back(nullptr);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logPath.fileSystemRepresentation,
                                     O_WRONLY | O_CREAT | O_APPEND, 0600);
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
    pid_t pid = -1;
    int rc = posix_spawn(&pid, executable.fileSystemRepresentation, &actions, nullptr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) return rc;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}

static NSString *captureProcess(NSString *executable, NSArray<NSString *> *arguments) {
    int pipes[2];
    if (pipe(pipes) != 0) return nil;
    NSMutableArray<NSData *> *storage = [NSMutableArray array];
    std::vector<char *> argv;
    for (NSString *value in [@[[executable lastPathComponent]] arrayByAddingObjectsFromArray:arguments]) {
        NSData *data = [[value stringByAppendingString:@"\0"] dataUsingEncoding:NSUTF8StringEncoding];
        [storage addObject:data]; argv.push_back((char *)data.bytes);
    }
    argv.push_back(nullptr);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipes[0]);
    posix_spawn_file_actions_addclose(&actions, pipes[1]);
    pid_t pid = -1;
    int rc = posix_spawn(&pid, executable.fileSystemRepresentation, &actions, nullptr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipes[1]);
    if (rc != 0) { close(pipes[0]); return nil; }
    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[4096]; ssize_t count;
    while ((count = read(pipes[0], buffer, sizeof(buffer))) > 0 && output.length < (64 << 10)) {
        [output appendBytes:buffer length:(NSUInteger)count];
    }
    close(pipes[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return nil;
    return [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
}

static NSString *dpkgPath(void) {
    for (NSString *path in @[@"/usr/bin/dpkg", @"/bin/dpkg"]) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

static BOOL packageMatches(NSString *artifact, NSString *expectedVersion) {
    NSString *tool = nil;
    for (NSString *path in @[@"/usr/bin/dpkg-deb", @"/bin/dpkg-deb"]) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) { tool = path; break; }
    }
    NSString *metadata = tool ? captureProcess(tool, @[@"-f", artifact, @"Package", @"Version"]) : nil;
    BOOL packageOK = NO, versionOK = NO;
    for (NSString *line in [metadata componentsSeparatedByString:@"\n"]) {
        if ([line isEqualToString:[@"Package: " stringByAppendingString:kPackageID]]) packageOK = YES;
        if ([line isEqualToString:[@"Version: " stringByAppendingString:expectedVersion]]) versionOK = YES;
    }
    return packageOK && versionOK;
}

static BOOL restoreRelay(NSString *backup, NSString *logPath) {
    if (!backup.length || ![NSFileManager.defaultManager fileExistsAtPath:backup]) return YES;
    NSData *relayData = [NSData dataWithContentsOfFile:backup options:0 error:nil];
    if (!relayData.length || ![relayData writeToFile:kRelayPreferences atomically:YES]) return NO;
    chmod(kRelayPreferences.fileSystemRepresentation, 0600);
    chown(kRelayPreferences.fileSystemRepresentation, 501, 501);
    NSString *plist = @"/Library/LaunchDaemons/com.greatlove.rctld.plist";
    runProcess(@"/bin/launchctl", @[@"unload", plist], logPath);
    runProcess(@"/bin/launchctl", @[@"load", plist], logPath);
    return [[NSData dataWithContentsOfFile:kRelayPreferences] isEqualToData:relayData];
}

static BOOL cleanInstall(NSString *artifact, NSString *relayBackup, NSString *logPath) {
    NSString *dpkg = dpkgPath();
    if (!dpkg) return NO;
    if (installedVersion().length && runProcess(dpkg, @[@"-r", kPackageID], logPath) != 0) return NO;
    if (runProcess(dpkg, @[@"-i", artifact], logPath) != 0) return NO;
    return restoreRelay(relayBackup, logPath);
}

static NSDictionary *localJSON(NSString *path) {
    if (![path hasPrefix:@"/"] || [path containsString:@"\r"] || [path containsString:@"\n"]) return nil;
    int socketFD = socket(AF_INET, SOCK_STREAM, 0);
    if (socketFD < 0) return nil;
    struct timeval timeout = {.tv_sec = 3, .tv_usec = 0};
    setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(8080);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(socketFD, (sockaddr *)&address, sizeof(address)) != 0) {
        close(socketFD);
        return nil;
    }
    NSString *request = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", path];
    NSData *requestData = [request dataUsingEncoding:NSASCIIStringEncoding];
    const uint8_t *bytes = (const uint8_t *)requestData.bytes;
    size_t sent = 0;
    while (sent < requestData.length) {
        ssize_t count = send(socketFD, bytes + sent, requestData.length - sent, 0);
        if (count <= 0) { close(socketFD); return nil; }
        sent += (size_t)count;
    }
    NSMutableData *response = [NSMutableData data];
    uint8_t buffer[4096];
    ssize_t count = 0;
    while ((count = recv(socketFD, buffer, sizeof(buffer), 0)) > 0 && response.length <= (1 << 20)) {
        [response appendBytes:buffer length:(NSUInteger)count];
    }
    close(socketFD);
    if (response.length > (1 << 20)) return nil;
    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange headerEnd = [response rangeOfData:separator options:0 range:NSMakeRange(0, response.length)];
    if (headerEnd.location == NSNotFound) return nil;
    NSString *header = [[NSString alloc] initWithData:[response subdataWithRange:NSMakeRange(0, headerEnd.location)]
                                             encoding:NSASCIIStringEncoding];
    if (![header hasPrefix:@"HTTP/1.1 200 "]) return nil;
    NSUInteger bodyStart = NSMaxRange(headerEnd);
    NSData *body = [response subdataWithRange:NSMakeRange(bodyStart, response.length - bodyStart)];
    id value = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static BOOL verifyRuntime(NSString *version, BOOL expectRelay, NSTimeInterval timeout,
                          NSString *heartbeat) {
    const NSTimeInterval deadline = NSDate.timeIntervalSinceReferenceDate + timeout;
    while (NSDate.timeIntervalSinceReferenceDate < deadline) {
        touchFile(heartbeat);
        NSDictionary *capabilities = localJSON(@"/v1/capabilities");
        NSString *runningVersion = [capabilities[@"daemon"] isKindOfClass:NSDictionary.class] ? capabilities[@"daemon"][@"version"] : nil;
        NSNumber *major = [capabilities[@"protocol"] isKindOfClass:NSDictionary.class] ? capabilities[@"protocol"][@"major"] : nil;
        BOOL daemonOK = [runningVersion isEqualToString:version] && major.integerValue == 1;
        BOOL springBoardOK = localJSON(@"/v1/deviceinfo") != nil;
        BOOL relayOK = !expectRelay;
        if (expectRelay) {
            NSDictionary *relay = localJSON(@"/v1/relay_status");
            relayOK = [relay[@"connected"] integerValue] > 0;
        }
        if (daemonOK && springBoardOK && relayOK) return YES;
        sleep(3);
    }
    return NO;
}

static BOOL relayExpected(NSString *backup) {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:backup];
    if (![root[@"Enabled"] boolValue]) return NO;
    NSArray *entries = [root[@"Relays"] isKindOfClass:NSArray.class] ? root[@"Relays"] : @[root ?: @{}];
    for (NSDictionary *entry in entries) {
        if ((![entry[@"Enabled"] respondsToSelector:@selector(boolValue)] || [entry[@"Enabled"] boolValue]) &&
            [entry[@"DeviceSecret"] isKindOfClass:NSString.class] && [entry[@"DeviceSecret"] length] >= 32) return YES;
    }
    return NO;
}

static BOOL performRollback(NSDictionary *plan, NSString *message) {
    NSString *work = plan[@"work_dir"];
    touchFile([work stringByAppendingPathComponent:@"rollback_in_progress"]);
    writeStatus(plan[@"job_id"], @"rolling_back", message, plan[@"current_version"], plan[@"target_version"], NO);
    BOOL installed = cleanInstall(plan[@"current_path"], plan[@"relay_backup"], plan[@"log_path"]);
    BOOL verified = installed && verifyRuntime(plan[@"current_version"], [plan[@"expect_relay"] boolValue], 150,
                                               [work stringByAppendingPathComponent:@"heartbeat"]);
    writeStatus(plan[@"job_id"], verified ? @"rolled_back" : @"rollback_failed",
                verified ? @"Previous version restored" : @"Automatic rollback failed",
                plan[@"current_version"], plan[@"target_version"], YES);
    if (verified) touchFile([work stringByAppendingPathComponent:@"rollback_complete"]);
    return verified;
}

static int watchdogMain(NSString *planPath, pid_t parentPID) {
    NSDictionary *plan = readJSONObject(planPath);
    if (!plan) return 2;
    NSString *work = plan[@"work_dir"];
    NSString *success = [work stringByAppendingPathComponent:@"success"];
    NSString *rollbackComplete = [work stringByAppendingPathComponent:@"rollback_complete"];
    NSString *heartbeat = [work stringByAppendingPathComponent:@"heartbeat"];
    touchFile([work stringByAppendingPathComponent:@"watchdog_ready"]);
    for (int elapsed = 0; elapsed < 600; elapsed += 5) {
        if ([NSFileManager.defaultManager fileExistsAtPath:success] ||
            [NSFileManager.defaultManager fileExistsAtPath:rollbackComplete]) return 0;
        struct stat st = {};
        BOOL fresh = stat(heartbeat.fileSystemRepresentation, &st) == 0 && time(nullptr) - st.st_mtime < 180;
        BOOL parentAlive = kill(parentPID, 0) == 0 || errno == EPERM;
        if (!parentAlive || !fresh) {
            if (parentAlive) {
                kill(parentPID, SIGTERM);
                for (int i = 0; i < 10 && kill(parentPID, 0) == 0; ++i) sleep(1);
                if (kill(parentPID, 0) == 0) kill(parentPID, SIGKILL);
            }
            int lock = open([[kStateRoot stringByAppendingPathComponent:@"update.lock"] fileSystemRepresentation], O_CREAT | O_RDWR, 0600);
            if (lock < 0 || flock(lock, LOCK_EX) != 0) { if (lock >= 0) close(lock); return 1; }
            BOOL rolledBack = performRollback(plan, parentAlive ? @"Updater stalled; watchdog rollback" : @"Updater exited; watchdog rollback");
            flock(lock, LOCK_UN); close(lock);
            return rolledBack ? 0 : 1;
        }
        sleep(5);
    }
    kill(parentPID, SIGTERM);
    for (int i = 0; i < 10 && kill(parentPID, 0) == 0; ++i) sleep(1);
    if (kill(parentPID, 0) == 0) kill(parentPID, SIGKILL);
    int lock = open([[kStateRoot stringByAppendingPathComponent:@"update.lock"] fileSystemRepresentation], O_CREAT | O_RDWR, 0600);
    if (lock < 0 || flock(lock, LOCK_EX) != 0) { if (lock >= 0) close(lock); return 1; }
    BOOL rolledBack = performRollback(plan, @"Update exceeded watchdog deadline");
    flock(lock, LOCK_UN); close(lock);
    return rolledBack ? 0 : 1;
}

static BOOL spawnWatchdog(NSString *executable, NSString *planPath) {
    NSString *parentPID = [NSString stringWithFormat:@"%d", getpid()];
    NSArray<NSString *> *values = @[executable, @"--watchdog", planPath, parentPID];
    NSMutableArray<NSData *> *storage = [NSMutableArray arrayWithCapacity:values.count];
    std::vector<char *> argv;
    for (NSString *value in values) {
        NSData *data = [[value stringByAppendingString:@"\0"] dataUsingEncoding:NSUTF8StringEncoding];
        [storage addObject:data]; argv.push_back((char *)data.bytes);
    }
    argv.push_back(nullptr);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
    pid_t child = -1;
    int result = posix_spawn(&child, executable.fileSystemRepresentation, &actions, nullptr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    if (result != 0) return NO;
    NSString *ready = [planPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"watchdog_ready"];
    for (int i = 0; i < 100; ++i) {
        if ([NSFileManager.defaultManager fileExistsAtPath:ready]) return YES;
        usleep(100 * 1000);
    }
    return NO;
}

static BOOL detachAndCloseInheritedDescriptors(void) {
    if (setsid() < 0) return NO;
    int descriptorLimit = getdtablesize();
    for (int fd = STDERR_FILENO + 1; fd < descriptorLimit; ++fd) close(fd);
    return YES;
}

static int updateMain(NSString *requestPath, NSString *executable) {
    NSDictionary *request = readJSONObject(requestPath);
    NSString *job = [request[@"job_id"] isKindOfClass:NSString.class] ? request[@"job_id"] : nil;
    NSString *manifestURL = [request[@"manifest_url"] isKindOfClass:NSString.class] ? request[@"manifest_url"] : nil;
    if (!job.length || !secureHTTPSURL(manifestURL)) return 2;
    ensureDirectory(kStateRoot);
    int lock = open([[kStateRoot stringByAppendingPathComponent:@"update.lock"] fileSystemRepresentation], O_CREAT | O_RDWR, 0600);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) {
        writeStatus(job, @"rejected", @"Another update is already active", @"", @"", YES);
        if (lock >= 0) close(lock);
        return 3;
    }
    unlink(kLaunchGuard.fileSystemRepresentation);

    NSString *current = installedVersion();
    NSString *work = [kStateRoot stringByAppendingPathComponent:job];
    ensureDirectory(work);
    NSString *heartbeat = [work stringByAppendingPathComponent:@"heartbeat"];
    NSString *logPath = [work stringByAppendingPathComponent:@"update.log"];
    touchFile(heartbeat);
    writeStatus(job, @"downloading_manifest", @"Downloading signed release catalog", current, @"", NO);

    NSString *error = nil;
    NSData *envelope = downloadData(manifestURL, kMaximumManifestBytes, &error);
    NSDictionary *payload = nil;
    if (!envelope || !verifyEnvelope(envelope, &payload, &error)) {
        writeStatus(job, @"failed", error ?: @"Manifest verification failed", current, @"", YES);
        flock(lock, LOCK_UN); close(lock); return 4;
    }
    NSNumber *schema = [payload[@"schema"] isKindOfClass:NSNumber.class] ? payload[@"schema"] : nil;
    NSNumber *protocol = [payload[@"protocol_major"] isKindOfClass:NSNumber.class] ? payload[@"protocol_major"] : nil;
    NSString *target = [payload[@"target_version"] isKindOfClass:NSString.class] ? payload[@"target_version"] : nil;
    NSDictionary *currentArtifact = artifactForVersion(payload, current);
    NSDictionary *targetArtifact = artifactForVersion(payload, target);
    if (schema.integerValue != 1 || protocol.integerValue != 1 || !current.length || !target.length || [target isEqualToString:current] ||
        !validateArtifact(currentArtifact, &error) || !validateArtifact(targetArtifact, &error)) {
        writeStatus(job, @"failed", error ?: @"Signed catalog cannot provide a safe update and rollback", current, target, YES);
        flock(lock, LOCK_UN); close(lock); return 5;
    }

    NSString *currentPath = [work stringByAppendingPathComponent:@"current.deb"];
    NSString *targetPath = [work stringByAppendingPathComponent:@"target.deb"];
    NSArray *items = @[@{ @"metadata": currentArtifact, @"path": currentPath },
                       @{ @"metadata": targetArtifact, @"path": targetPath }];
    for (NSDictionary *item in items) {
        NSDictionary *metadata = item[@"metadata"];
        NSString *path = item[@"path"];
        writeStatus(job, @"downloading_artifacts", [@"Downloading " stringByAppendingString:metadata[@"version"]], current, target, NO);
        touchFile(heartbeat);
        if (!downloadFile(metadata[@"url"], path, kMaximumArtifactBytes, &error)) {
            writeStatus(job, @"failed", error ?: @"Artifact download failed", current, target, YES);
            flock(lock, LOCK_UN); close(lock); return 6;
        }
        struct stat st = {};
        NSString *digest = sha256File(path);
        if (stat(path.fileSystemRepresentation, &st) != 0 || (unsigned long long)st.st_size != [metadata[@"size"] unsignedLongLongValue] ||
            ![digest isEqualToString:metadata[@"sha256"]] || !packageMatches(path, metadata[@"version"])) {
            writeStatus(job, @"failed", @"Artifact checksum or size mismatch", current, target, YES);
            flock(lock, LOCK_UN); close(lock); return 7;
        }
        chmod(path.fileSystemRepresentation, 0600);
    }

    NSString *relayBackup = [work stringByAppendingPathComponent:@"relay.plist"];
    if ([NSFileManager.defaultManager fileExistsAtPath:kRelayPreferences]) {
        NSError *backupError = nil;
        if (![NSFileManager.defaultManager copyItemAtPath:kRelayPreferences toPath:relayBackup error:&backupError]) {
            writeStatus(job, @"failed", @"Could not preserve relay identity", current, target, YES);
            flock(lock, LOCK_UN); close(lock); return 8;
        }
        chmod(relayBackup.fileSystemRepresentation, 0600);
    }
    NSDictionary *plan = @{
        @"job_id": job, @"work_dir": work, @"log_path": logPath,
        @"current_version": current, @"target_version": target,
        @"current_path": currentPath, @"target_path": targetPath,
        @"relay_backup": relayBackup, @"expect_relay": @(relayExpected(relayBackup)),
    };
    NSString *planPath = [work stringByAppendingPathComponent:@"plan.json"];
    writeJSON(planPath, plan, 0600);
    if (!spawnWatchdog(executable, planPath)) {
        writeStatus(job, @"failed", @"Could not start external watchdog", current, target, YES);
        flock(lock, LOCK_UN); close(lock); return 8;
    }

    writeStatus(job, @"installing", @"Installing verified package", current, target, NO);
    touchFile(heartbeat);
    BOOL installed = cleanInstall(targetPath, relayBackup, logPath);
    writeStatus(job, @"verifying", @"Checking daemon, SpringBoard IPC, and relay", current, target, NO);
    touchFile(heartbeat);
    BOOL verified = installed && verifyRuntime(target, [plan[@"expect_relay"] boolValue], 180, heartbeat);
    if (verified) {
        touchFile([work stringByAppendingPathComponent:@"success"]);
        writeStatus(job, @"complete", @"Update verified", current, target, YES);
        flock(lock, LOCK_UN); close(lock); return 0;
    }
    BOOL rolledBack = performRollback(plan, installed ? @"Runtime verification failed" : @"Installation failed");
    flock(lock, LOCK_UN); close(lock);
    return rolledBack ? 9 : 10;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--verify-envelope")) {
            NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]] options:0 error:nil];
            NSDictionary *payload = nil;
            NSString *error = nil;
            if (!data || !verifyEnvelope(data, &payload, &error)) {
                fprintf(stderr, "VERIFY_FAILED %s\n", (error ?: @"read failed").UTF8String);
                return 1;
            }
            NSString *target = [payload[@"target_version"] isKindOfClass:NSString.class] ? payload[@"target_version"] : @"";
            printf("VERIFIED %s\n", target.UTF8String);
            return 0;
        }
        if (argc == 4 && !strcmp(argv[1], "--watchdog")) {
            if (!detachAndCloseInheritedDescriptors()) return 70;
            return watchdogMain([NSString stringWithUTF8String:argv[2]], (pid_t)atoi(argv[3]));
        }
        if (argc == 3 && !strcmp(argv[1], "--run")) {
            gCleanupRequest = strdup(argv[2]);
            atexit(cleanupTemporaryLauncher);
            if (!detachAndCloseInheritedDescriptors()) {
                NSDictionary *request = readJSONObject([NSString stringWithUTF8String:argv[2]]);
                NSString *job = [request[@"job_id"] isKindOfClass:NSString.class] ? request[@"job_id"] : @"";
                writeStatus(job, @"failed", @"Could not detach updater process", @"", @"", YES);
                unlink(kLaunchGuard.fileSystemRepresentation);
                return 70;
            }
            return updateMain([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[0]]);
        }
        fprintf(stderr, "usage: rctl-updater --run request.json\n");
        return 64;
    }
}
