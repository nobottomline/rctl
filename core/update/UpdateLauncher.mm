#import "UpdateLauncher.h"

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <pthread.h>
#import <time.h>
#import <unistd.h>
#include <errno.h>

extern char **environ;

static NSString *const kUpdater = @"/usr/local/libexec/rctl-updater";
static NSString *const kStateRoot = @"/var/mobile/Library/Caches/com.greatlove.rctl/update";
static NSString *const kStatusPath = @"/var/mobile/Library/Caches/com.greatlove.rctl/update/status.json";
static NSString *const kLaunchGuard = @"/var/mobile/Library/Caches/com.greatlove.rctl/update/active.request";
static pthread_mutex_t gLaunchLock = PTHREAD_MUTEX_INITIALIZER;

static char *json_bytes(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    char *result = (char *)malloc(data.length + 1);
    memcpy(result, data.bytes, data.length); result[data.length] = 0;
    return result;
}

static BOOL secure_manifest_url(NSString *value) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    return [parts.scheme.lowercaseString isEqualToString:@"https"] && parts.host.length > 0 &&
           !parts.user.length && !parts.password.length && !parts.fragment.length;
}

static int spawn_updater(NSString *executable, NSString *request) {
    char *argv[] = {(char *)executable.fileSystemRepresentation, (char *)"--run",
                    (char *)request.fileSystemRepresentation, nullptr};
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
    pid_t child = -1;
    int result = posix_spawn(&child, executable.fileSystemRepresentation, &actions, nullptr, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (result == 0) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int childStatus = 0;
            while (waitpid(child, &childStatus, 0) < 0 && errno == EINTR) {}
        });
    }
    return result;
}

char *rctl_update_launch(const char *manifest_url, int *status) {
    pthread_mutex_lock(&gLaunchLock);
    NSString *manifest = manifest_url ? [NSString stringWithUTF8String:manifest_url] : nil;
    if (!secure_manifest_url(manifest)) {
        if (status) *status = 400;
        pthread_mutex_unlock(&gLaunchLock);
        return json_bytes(@{@"error": @"manifest_url_must_be_https"});
    }
    if (![NSFileManager.defaultManager isExecutableFileAtPath:kUpdater]) {
        if (status) *status = 503;
        pthread_mutex_unlock(&gLaunchLock);
        return json_bytes(@{@"error": @"updater_unavailable"});
    }
    [NSFileManager.defaultManager createDirectoryAtPath:kStateRoot withIntermediateDirectories:YES
                                              attributes:@{NSFilePosixPermissions: @0700} error:nil];
    struct stat guardStat = {};
    if (stat(kLaunchGuard.fileSystemRepresentation, &guardStat) == 0 && time(nullptr) - guardStat.st_mtime < 30 * 60) {
        if (status) *status = 409;
        pthread_mutex_unlock(&gLaunchLock);
        return json_bytes(@{@"error": @"update_already_active"});
    }
    unlink(kLaunchGuard.fileSystemRepresentation);
    int guard = open(kLaunchGuard.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (guard < 0) {
        if (status) *status = 409;
        pthread_mutex_unlock(&gLaunchLock);
        return json_bytes(@{@"error": @"update_already_active"});
    }
    close(guard);
    NSString *job = [NSUUID.UUID.UUIDString lowercaseString];
    NSString *request = [kStateRoot stringByAppendingPathComponent:[job stringByAppendingString:@".request.json"]];
    NSData *requestData = [NSJSONSerialization dataWithJSONObject:@{@"job_id": job, @"manifest_url": manifest}
                                                           options:0 error:nil];
    if (![requestData writeToFile:request atomically:YES]) {
        if (status) *status = 500;
        unlink(kLaunchGuard.fileSystemRepresentation);
        pthread_mutex_unlock(&gLaunchLock);
        return json_bytes(@{@"error": @"update_request_write_failed"});
    }
    chmod(request.fileSystemRepresentation, 0600);

    int spawnResult = spawn_updater(kUpdater, request);
    if (spawnResult != 0) {
        unlink(request.fileSystemRepresentation);
        if (status) *status = 500;
        unlink(kLaunchGuard.fileSystemRepresentation);
        pthread_mutex_unlock(&gLaunchLock);
        return json_bytes(@{@"error": @"updater_spawn_failed"});
    }
    if (status) *status = 202;
    pthread_mutex_unlock(&gLaunchLock);
    return json_bytes(@{@"accepted": @YES, @"job_id": job});
}

char *rctl_update_status(void) {
    NSData *data = [NSData dataWithContentsOfFile:kStatusPath options:0 error:nil];
    if (!data.length) return json_bytes(@{@"phase": @"idle", @"terminal": @YES});
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class]) return json_bytes(@{@"phase": @"unknown", @"terminal": @YES});
    return json_bytes(value);
}
