#import "net/MediaLibrary.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <sqlite3.h>
#import <sys/stat.h>

#ifndef RCTL_MEDIA_ROOT
#define RCTL_MEDIA_ROOT "/var/mobile/Media"
#endif
#ifndef RCTL_MEDIA_CACHE_ROOT
#define RCTL_MEDIA_CACHE_ROOT "/var/mobile/Library/Caches/com.greatlove.rctl/media"
#endif

static NSString *device_media_root(void) { return [NSString stringWithUTF8String:RCTL_MEDIA_ROOT]; }
static NSString *dcim_root(void) { return [device_media_root() stringByAppendingPathComponent:@"DCIM"]; }
static NSString *photos_database(void) {
    return [device_media_root() stringByAppendingPathComponent:@"PhotoData/Photos.sqlite"];
}
static NSString *thumb_root(void) { return [NSString stringWithUTF8String:RCTL_MEDIA_CACHE_ROOT]; }

static dispatch_queue_t g_media_queue;
static NSArray<NSDictionary *> *g_assets;
static NSDictionary<NSString *, NSDictionary *> *g_assets_by_id;
static NSTimeInterval g_scanned_at;

static dispatch_queue_t media_queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_media_queue = dispatch_queue_create("com.greatlove.rctl.media", DISPATCH_QUEUE_SERIAL); });
    return g_media_queue;
}

static NSString *query_value(const char *query, NSString *wanted) {
    if (!query || !*query) return nil;
    NSString *raw = [NSString stringWithUTF8String:query] ?: @"";
    for (NSString *part in [raw componentsSeparatedByString:@"&"]) {
        NSRange eq = [part rangeOfString:@"="];
        NSString *key = eq.location == NSNotFound ? part : [part substringToIndex:eq.location];
        if (![key isEqualToString:wanted]) continue;
        NSString *value = eq.location == NSNotFound ? @"" : [part substringFromIndex:eq.location + 1];
        return [value stringByRemovingPercentEncoding] ?: @"";
    }
    return nil;
}

static char *json_body(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return strdup("{\"error\":\"json_failed\"}");
    char *out = (char *)malloc(data.length + 1);
    memcpy(out, data.bytes, data.length);
    out[data.length] = 0;
    return out;
}

static NSString *asset_id(NSString *path) {
    const uint8_t *bytes = (const uint8_t *)path.UTF8String;
    uint64_t hash = 1469598103934665603ULL;
    for (size_t i = 0; bytes && bytes[i]; i++) { hash ^= bytes[i]; hash *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)hash];
}

// Photos stores a Live Photo as one logical ZASSET plus image/video resources
// with the same directory and filename stem. The DCIM fallback must not publish
// those resources as separate assets.
static NSString *logical_asset_key(NSString *path) {
    if (!path.length) return nil;
    return path.stringByDeletingPathExtension.lowercaseString;
}

static NSString *media_kind(NSString *extension) {
    static NSSet *photos;
    static NSSet *videos;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        photos = [NSSet setWithArray:@[@"jpg", @"jpeg", @"heic", @"heif", @"png", @"gif", @"tif", @"tiff", @"dng"]];
        videos = [NSSet setWithArray:@[@"mov", @"mp4", @"m4v", @"3gp"]];
    });
    NSString *ext = extension.lowercaseString;
    if ([photos containsObject:ext]) return @"photo";
    if ([videos containsObject:ext]) return @"video";
    return nil;
}

static BOOL path_is_inside_media_root(NSString *path) {
    NSString *root = device_media_root().stringByStandardizingPath;
    NSString *candidate = path.stringByStandardizingPath;
    return [candidate hasPrefix:[root stringByAppendingString:@"/"]];
}

static NSDictionary *make_asset(NSString *path, NSString *name, NSString *kind, NSDate *date,
                                NSNumber *width, NSNumber *height, NSNumber *duration) {
    struct stat info = {};
    if (!path.length || !kind || lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISREG(info.st_mode) || S_ISLNK(info.st_mode)) return nil;
    NSString *resolved = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    if (!path_is_inside_media_root(resolved)) return nil;
    NSMutableDictionary *asset = [@{
        @"id": asset_id(resolved),
        @"name": name.length ? name : resolved.lastPathComponent ?: @"media",
        @"path": resolved,
        @"type": kind,
        @"size": @((unsigned long long)info.st_size),
        @"created": @((long long)(date ?: [NSDate dateWithTimeIntervalSince1970:info.st_mtimespec.tv_sec]).timeIntervalSince1970),
    } mutableCopy];
    if (width.longLongValue > 0) asset[@"width"] = width;
    if (height.longLongValue > 0) asset[@"height"] = height;
    if (duration.doubleValue > 0) asset[@"duration"] = duration;
    return asset;
}

static void add_asset(NSMutableArray *assets, NSMutableDictionary *byID,
                      NSMutableSet *paths, NSDictionary *asset) {
    NSString *identifier = asset[@"id"];
    NSString *path = asset[@"path"];
    if (!identifier || !path || byID[identifier] || [paths containsObject:path]) return;
    [assets addObject:asset];
    byID[identifier] = asset;
    [paths addObject:path];
}

static BOOL load_photos_database(NSMutableArray *assets, NSMutableDictionary *byID,
                                 NSMutableSet *paths, NSMutableSet *knownPaths,
                                 NSMutableSet *knownLogicalAssets) {
    sqlite3 *database = NULL;
    if (sqlite3_open_v2(photos_database().fileSystemRepresentation, &database,
                        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (database) sqlite3_close(database);
        return NO;
    }
    sqlite3_busy_timeout(database, 250);
    const char *sql =
        "SELECT ZDIRECTORY,ZFILENAME,ZKIND,ZDATECREATED,ZADDEDDATE,ZWIDTH,ZHEIGHT,ZDURATION,"
        "IFNULL(ZTRASHEDSTATE,0),IFNULL(ZHIDDEN,0),IFNULL(ZVISIBILITYSTATE,0) "
        "FROM ZASSET WHERE ZDIRECTORY IS NOT NULL AND ZFILENAME IS NOT NULL";
    sqlite3_stmt *statement = NULL;
    BOOL complete = NO;
    if (sqlite3_prepare_v2(database, sql, -1, &statement, NULL) == SQLITE_OK) {
        int step = SQLITE_ROW;
        while ((step = sqlite3_step(statement)) == SQLITE_ROW) {
            @autoreleasepool {
                const char *directoryBytes = (const char *)sqlite3_column_text(statement, 0);
                const char *filenameBytes = (const char *)sqlite3_column_text(statement, 1);
                if (!directoryBytes || !filenameBytes) continue;
                NSString *directory = [NSString stringWithUTF8String:directoryBytes];
                NSString *filename = [NSString stringWithUTF8String:filenameBytes];
                NSString *path = [[device_media_root() stringByAppendingPathComponent:directory]
                                  stringByAppendingPathComponent:filename];
                NSString *resolved = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
                if (path_is_inside_media_root(resolved)) {
                    [knownPaths addObject:resolved];
                    NSString *logicalKey = logical_asset_key(resolved);
                    if (logicalKey) [knownLogicalAssets addObject:logicalKey];
                }
                if (sqlite3_column_int(statement, 8) != 0 || sqlite3_column_int(statement, 9) != 0 ||
                    sqlite3_column_int(statement, 10) != 0) continue;
                NSString *kind = sqlite3_column_int(statement, 2) == 1 ? @"video" : media_kind(filename.pathExtension);
                if (!kind) kind = @"photo";
                double timestamp = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? sqlite3_column_double(statement, 4) : sqlite3_column_double(statement, 3);
                NSDate *date = [NSDate dateWithTimeIntervalSince1970:timestamp + NSTimeIntervalSince1970];
                NSDictionary *asset = make_asset(path, filename, kind, date,
                    @(sqlite3_column_int64(statement, 5)), @(sqlite3_column_int64(statement, 6)),
                    @(sqlite3_column_double(statement, 7)));
                if (asset) add_asset(assets, byID, paths, asset);
            }
        }
        complete = step == SQLITE_DONE;
    }
    if (statement) sqlite3_finalize(statement);
    sqlite3_close(database);
    return complete;
}

static void load_dcim_fallback(NSMutableArray *assets, NSMutableDictionary *byID,
                               NSMutableSet *paths, NSSet *knownPaths,
                               NSSet *knownLogicalAssets) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *keys = @[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey, NSURLContentModificationDateKey,
                      NSURLCreationDateKey, NSURLNameKey];
    NSDirectoryEnumerator *it = [fm enumeratorAtURL:[NSURL fileURLWithPath:dcim_root() isDirectory:YES]
                         includingPropertiesForKeys:keys
                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                       errorHandler:^BOOL(NSURL *url, NSError *error) { (void)url; (void)error; return YES; }];
    for (NSURL *url in it) {
        @autoreleasepool {
            NSDictionary *values = [url resourceValuesForKeys:keys error:nil];
            if (![values[NSURLIsRegularFileKey] boolValue] || [values[NSURLIsSymbolicLinkKey] boolValue]) continue;
            NSString *kind = media_kind(url.pathExtension);
            if (!kind) continue;
            NSString *resolved = url.path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
            if ([knownPaths containsObject:resolved]) continue;
            NSString *logicalKey = logical_asset_key(resolved);
            if (logicalKey && [knownLogicalAssets containsObject:logicalKey]) continue;
            NSDate *date = values[NSURLCreationDateKey] ?: values[NSURLContentModificationDateKey] ?: [NSDate dateWithTimeIntervalSince1970:0];
            NSDictionary *asset = make_asset(url.path, values[NSURLNameKey] ?: url.lastPathComponent,
                                             kind, date, nil, nil, nil);
            if (asset) add_asset(assets, byID, paths, asset);
        }
    }
}

static void rebuild_assets(void) {
    NSMutableArray *assets = [NSMutableArray array];
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    NSMutableSet *paths = [NSMutableSet set];
    NSMutableSet *knownPaths = [NSMutableSet set];
    NSMutableSet *knownLogicalAssets = [NSMutableSet set];
    BOOL indexed = load_photos_database(assets, byID, paths, knownPaths, knownLogicalAssets);
    if (indexed) load_dcim_fallback(assets, byID, paths, knownPaths, knownLogicalAssets);
    [assets sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult byDate = [b[@"created"] compare:a[@"created"]];
        return byDate == NSOrderedSame ? [a[@"path"] compare:b[@"path"]] : byDate;
    }];
    g_assets = [assets copy];
    g_assets_by_id = [byID copy];
    g_scanned_at = [NSDate timeIntervalSinceReferenceDate];
}

static void ensure_assets(BOOL force) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (force || !g_assets || now - g_scanned_at > 15.0) rebuild_assets();
}

static NSDictionary *lookup_asset(NSString *identifier) {
    if (!identifier.length) return nil;
    ensure_assets(NO);
    NSDictionary *asset = g_assets_by_id[identifier];
    NSString *path = [asset[@"path"] isKindOfClass:[NSString class]] ? asset[@"path"] : nil;
    if (!path || !path_is_inside_media_root(path) || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    return asset;
}

static CGImageRef video_frame(NSString *path, CGFloat maxPixel) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(maxPixel, maxPixel);
    CMTime at = CMTIME_COMPARE_INLINE(asset.duration, >, kCMTimeZero) ? CMTimeMultiplyByFloat64(asset.duration, 0.1) : CMTimeMake(1, 10);
    return [generator copyCGImageAtTime:at actualTime:NULL error:nil];
}

static CGImageRef photo_frame(NSString *path, NSInteger maxPixel) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!source) return NULL;
    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxPixel),
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    return image;
}

static NSString *rendered_path(NSDictionary *asset, NSInteger maxPixel, double quality, NSString *tag) {
    NSString *path = asset[@"path"];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    long long stamp = (long long)[attrs[NSFileModificationDate] timeIntervalSince1970];
    NSString *out = [thumb_root() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%lld-%@.jpg", asset[@"id"], stamp, tag]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:out]) return out;
    [[NSFileManager defaultManager] createDirectoryAtPath:thumb_root() withIntermediateDirectories:YES
                                                attributes:@{NSFilePosixPermissions: @0700} error:nil];
    CGImageRef image = [asset[@"type"] isEqualToString:@"video"] ? video_frame(path, maxPixel) : photo_frame(path, maxPixel);
    if (!image) return nil;
    NSMutableData *jpeg = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(quality)});
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CGImageRelease(image);
    if (!jpeg.length || ![jpeg writeToFile:out atomically:YES]) return nil;
    chmod(out.fileSystemRepresentation, 0600);
    return out;
}

static char *read_binary(NSString *path, int *status, int *out_len, const char **out_ctype) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length || data.length > 8 * 1024 * 1024) {
        *status = 500;
        return strdup("{\"error\":\"thumbnail_failed\"}");
    }
    char *out = (char *)malloc(data.length);
    memcpy(out, data.bytes, data.length);
    *out_len = (int)data.length;
    *out_ctype = "image/jpeg";
    return out;
}

char *rctl_media_handle(const char *path, const char *query, int *status,
                        int *out_len, const char **out_ctype) {
    if (!path || strncmp(path, "/v1/media", 9) != 0) return NULL;
    if (!strcmp(path, "/v1/media")) {
        __block char *result = NULL;
        dispatch_sync(media_queue(), ^{
            BOOL refresh = [query_value(query, @"refresh") boolValue];
            ensure_assets(refresh);
            NSString *kind = query_value(query, @"type") ?: @"all";
            NSString *search = (query_value(query, @"q") ?: @"").lowercaseString;
            NSInteger cursor = MAX(0, [query_value(query, @"cursor") integerValue]);
            NSInteger limit = [query_value(query, @"limit") integerValue];
            if (limit <= 0) limit = 60;
            limit = MIN(limit, 100);
            NSMutableArray *filtered = [NSMutableArray array];
            for (NSDictionary *asset in g_assets) {
                if (![kind isEqualToString:@"all"] && ![asset[@"type"] isEqualToString:kind]) continue;
                if (search.length && ![[asset[@"name"] lowercaseString] containsString:search]) continue;
                [filtered addObject:asset];
            }
            NSInteger end = MIN((NSInteger)filtered.count, cursor + limit);
            NSArray *page = cursor < end ? [filtered subarrayWithRange:NSMakeRange(cursor, end - cursor)] : @[];
            result = json_body(@{@"items": page, @"total": @(filtered.count),
                                 @"next": end < (NSInteger)filtered.count ? @(end) : [NSNull null]});
        });
        return result;
    }

    if (!strcmp(path, "/v1/media_asset") || !strcmp(path, "/v1/media_thumb") ||
        !strcmp(path, "/v1/media_preview")) {
        __block NSDictionary *asset = nil;
        __block NSString *rendered = nil;
        NSString *identifier = query_value(query, @"id");
        BOOL preview = !strcmp(path, "/v1/media_preview");
        dispatch_sync(media_queue(), ^{
            asset = [lookup_asset(identifier) copy];
            if (asset && strcmp(path, "/v1/media_asset")) {
                // ImageIO and AVAssetImageGenerator have significant transient
                // memory cost. Keep one renderer in flight regardless of how
                // many thumbnail requests the browser opens concurrently.
                rendered = rendered_path(asset, preview ? 2048 : 640, preview ? 0.88 : 0.72,
                                         preview ? @"preview" : @"thumb");
            }
        });
        if (!asset) { *status = 404; return strdup("{\"error\":\"asset_not_found\"}"); }
        if (!strcmp(path, "/v1/media_asset")) return json_body(asset);

        if (!rendered) { *status = 415; return strdup("{\"error\":\"thumbnail_unavailable\"}"); }
        return read_binary(rendered, status, out_len, out_ctype);
    }

    *status = 404;
    return strdup("{\"error\":\"unknown_media_action\"}");
}
