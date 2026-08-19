#import <Foundation/Foundation.h>

#include "net/MediaLibrary.h"

#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSString *const kRoot = @"/tmp/rctl-media-library-test/root";
static NSString *const kWork = @"/tmp/rctl-media-library-test";
static NSString *gDeletedUUID;

static char *delete_asset(const char *uuid) {
    gDeletedUUID = uuid ? [NSString stringWithUTF8String:uuid] : nil;
    return strdup("{\"ok\":true}");
}

static void require(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "media library test failed: %s\n", message.UTF8String);
    exit(1);
}

static NSDictionary *requestWithBody(NSString *path, NSString *query, NSString *requestBody,
                                     int expectedStatus) {
    int status = 200;
    int length = 0;
    const char *contentType = NULL;
    NSData *requestData = [requestBody dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    char *body = rctl_media_handle(path.UTF8String, query.UTF8String,
                                   static_cast<const char *>(requestData.bytes), (int)requestData.length,
                                   &status, &length, &contentType);
    require(body != NULL, [NSString stringWithFormat:@"%@ was not handled", path]);
    require(status == expectedStatus,
            [NSString stringWithFormat:@"%@ returned %d, expected %d", path, status, expectedStatus]);
    NSData *data = [NSData dataWithBytes:body length:length > 0 ? (NSUInteger)length : strlen(body)];
    free(body);
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    require([value isKindOfClass:[NSDictionary class]], [NSString stringWithFormat:@"%@ returned invalid JSON", path]);
    return value;
}

static NSDictionary *request(NSString *path, NSString *query, int expectedStatus) {
    return requestWithBody(path, query, @"", expectedStatus);
}

static void write_file(NSString *relative, NSString *contents) {
    NSString *path = [kRoot stringByAppendingPathComponent:relative];
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    require([contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil],
            [NSString stringWithFormat:@"could not create %@", relative]);
}

static void create_database(void) {
    NSString *path = [kRoot stringByAppendingPathComponent:@"PhotoData/Photos.sqlite"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    sqlite3 *database = NULL;
    require(sqlite3_open(path.fileSystemRepresentation, &database) == SQLITE_OK, @"could not create Photos.sqlite");
    const char *schema =
        "CREATE TABLE ZASSET (ZDIRECTORY TEXT,ZFILENAME TEXT,ZKIND INTEGER,ZDATECREATED REAL,"
        "ZADDEDDATE REAL,ZWIDTH INTEGER,ZHEIGHT INTEGER,ZDURATION REAL,ZTRASHEDSTATE INTEGER,"
        "ZHIDDEN INTEGER,ZVISIBILITYSTATE INTEGER,ZUUID TEXT);"
        "INSERT INTO ZASSET VALUES('DCIM/100APPLE','IMG_0001.JPG',0,100,100,4032,3024,0,0,0,0,'PHOTO-UUID');"
        "INSERT INTO ZASSET VALUES('DCIM/100APPLE','VID_0002.MOV',1,200,200,1920,1080,12.5,0,0,0,'VIDEO-UUID');"
        "INSERT INTO ZASSET VALUES('DCIM/100APPLE','HIDDEN.JPG',0,300,300,1,1,0,0,1,0,'HIDDEN-UUID');"
        "INSERT INTO ZASSET VALUES('DCIM/100APPLE','DELETED.JPG',0,400,400,1,1,0,1,0,0,'DELETED-UUID');"
        "INSERT INTO ZASSET VALUES('DCIM/100APPLE','CLOUD.JPG',0,500,500,1,1,0,0,0,0,'CLOUD-UUID');"
        "INSERT INTO ZASSET VALUES('../outside','ESCAPE.JPG',0,600,600,1,1,0,0,0,0,'ESCAPE-UUID');";
    char *error = NULL;
    int result = sqlite3_exec(database, schema, NULL, NULL, &error);
    NSString *message = error ? [NSString stringWithUTF8String:error] : @"schema setup failed";
    if (error) sqlite3_free(error);
    sqlite3_close(database);
    require(result == SQLITE_OK, message);
}

static void make_database_incompatible(void) {
    NSString *path = [kRoot stringByAppendingPathComponent:@"PhotoData/Photos.sqlite"];
    sqlite3 *database = NULL;
    require(sqlite3_open(path.fileSystemRepresentation, &database) == SQLITE_OK, @"could not reopen Photos.sqlite");
    require(sqlite3_exec(database, "DROP TABLE ZASSET; CREATE TABLE ZASSET (Z_PK INTEGER);",
                         NULL, NULL, NULL) == SQLITE_OK, @"could not create incompatible schema");
    sqlite3_close(database);
}

static void make_database_without_uuid(void) {
    NSString *path = [kRoot stringByAppendingPathComponent:@"PhotoData/Photos.sqlite"];
    sqlite3 *database = NULL;
    require(sqlite3_open(path.fileSystemRepresentation, &database) == SQLITE_OK, @"could not reopen Photos.sqlite");
    const char *schema =
        "DROP TABLE ZASSET;"
        "CREATE TABLE ZASSET (ZDIRECTORY TEXT,ZFILENAME TEXT,ZKIND INTEGER,ZDATECREATED REAL,"
        "ZADDEDDATE REAL,ZWIDTH INTEGER,ZHEIGHT INTEGER,ZDURATION REAL,ZTRASHEDSTATE INTEGER,"
        "ZHIDDEN INTEGER,ZVISIBILITYSTATE INTEGER);"
        "INSERT INTO ZASSET VALUES('DCIM/100APPLE','IMG_0001.JPG',0,100,100,4032,3024,0,0,0,0);";
    require(sqlite3_exec(database, schema, NULL, NULL, NULL) == SQLITE_OK,
            @"could not create UUID-less schema");
    sqlite3_close(database);
}

int main(void) {
    @autoreleasepool {
        NSFileManager *files = [NSFileManager defaultManager];
        [files removeItemAtPath:kWork error:nil];
        write_file(@"DCIM/100APPLE/IMG_0001.JPG", @"photo");
        write_file(@"DCIM/100APPLE/IMG_0001.MOV", @"live photo paired video");
        write_file(@"DCIM/100APPLE/VID_0002.MOV", @"video");
        write_file(@"DCIM/100APPLE/HIDDEN.JPG", @"hidden");
        write_file(@"DCIM/100APPLE/HIDDEN.MOV", @"hidden live photo paired video");
        write_file(@"DCIM/100APPLE/DELETED.JPG", @"deleted");
        write_file(@"DCIM/100APPLE/DELETED.MOV", @"deleted live photo paired video");
        write_file(@"DCIM/100APPLE/CLOUD.MOV", @"local resource for cloud placeholder");
        write_file(@"DCIM/100APPLE/NEW.JPG", @"new capture");
        write_file(@"DCIM/100APPLE/UNINDEXED.MOV", @"new video");
        write_file(@"DCIM/100APPLE/ANIMATED.GIF", @"animated image");
        NSString *outside = [kWork stringByAppendingPathComponent:@"outside/ESCAPE.JPG"];
        [files createDirectoryAtPath:outside.stringByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:nil];
        require([@"outside" writeToFile:outside atomically:YES encoding:NSUTF8StringEncoding error:nil],
                @"could not create traversal fixture");
        create_database();

        NSString *link = [kRoot stringByAppendingPathComponent:@"DCIM/100APPLE/LINK.JPG"];
        symlink([kWork stringByAppendingPathComponent:@"outside/ESCAPE.JPG"].fileSystemRepresentation,
                link.fileSystemRepresentation);

        NSDictionary *page = request(@"/v1/media", @"type=all&limit=100&refresh=1", 200);
        NSArray *items = page[@"items"];
        require([items isKindOfClass:[NSArray class]], @"list has no items array");
        require([page[@"total"] integerValue] == 5,
                @"logical database assets plus new DCIM files expected");

        NSMutableSet *names = [NSMutableSet set];
        for (NSDictionary *item in items) [names addObject:item[@"name"] ?: @""];
        require([names isEqualToSet:[NSSet setWithArray:@[
                    @"IMG_0001.JPG", @"VID_0002.MOV", @"NEW.JPG", @"UNINDEXED.MOV", @"ANIMATED.GIF"]]],
                @"paired, hidden, deleted, cloud-only, traversal, or symlink asset leaked into the list");

        NSDictionary *live = nil;
        NSDictionary *animated = nil;
        for (NSDictionary *candidate in items) {
            if ([candidate[@"name"] isEqualToString:@"IMG_0001.JPG"]) live = candidate;
            if ([candidate[@"name"] isEqualToString:@"ANIMATED.GIF"]) animated = candidate;
        }
        require([live[@"live"] boolValue], @"Live Photo was not marked as a compound asset");
        require([live[@"motion_name"] isEqualToString:@"IMG_0001.MOV"],
                @"Live Photo motion resource was not attached");
        require([live[@"motion_size"] integerValue] > 0, @"Live Photo motion size was lost");
        require([animated[@"animated"] boolValue], @"GIF was not marked as animated");
        require([live[@"deletable"] boolValue], @"database asset was not marked deletable");
        require(![animated[@"deletable"] boolValue], @"unindexed fallback asset became deletable");

        NSDictionary *deleteToken = requestWithBody(@"/v1/media_delete_token",
            [NSString stringWithFormat:@"id=%@", live[@"id"]], @"{}", 200);
        NSString *token = deleteToken[@"token"];
        require(token.length == 32, @"delete token is not 128-bit hex");
        NSData *tokenJSON = [NSJSONSerialization dataWithJSONObject:@{@"token": token} options:0 error:nil];
        NSString *tokenBody = [[NSString alloc] initWithData:tokenJSON encoding:NSUTF8StringEncoding];
        requestWithBody(@"/v1/media_delete", [NSString stringWithFormat:@"id=%@", live[@"id"]],
                        tokenBody, 503);

        rctl_media_set_delete_callback(delete_asset);
        deleteToken = requestWithBody(@"/v1/media_delete_token",
            [NSString stringWithFormat:@"id=%@", live[@"id"]], @"{}", 200);
        token = deleteToken[@"token"];
        requestWithBody(@"/v1/media_delete", [NSString stringWithFormat:@"id=%@", live[@"id"]],
                        @"{\"token\":\"wrong\"}", 409);
        tokenJSON = [NSJSONSerialization dataWithJSONObject:@{@"token": token} options:0 error:nil];
        tokenBody = [[NSString alloc] initWithData:tokenJSON encoding:NSUTF8StringEncoding];
        NSDictionary *deleted = requestWithBody(@"/v1/media_delete",
            [NSString stringWithFormat:@"id=%@", live[@"id"]], tokenBody, 200);
        require([deleted[@"ok"] boolValue], @"confirmed delete did not succeed");
        require([gDeletedUUID isEqualToString:@"PHOTO-UUID"], @"opaque id resolved to the wrong Photos UUID");
        requestWithBody(@"/v1/media_delete", [NSString stringWithFormat:@"id=%@", live[@"id"]],
                        tokenBody, 409);
        requestWithBody(@"/v1/media_delete_token",
                        [NSString stringWithFormat:@"id=%@", animated[@"id"]], @"{}", 404);

        NSDictionary *videoPage = request(@"/v1/media", @"type=video", 200);
        require([videoPage[@"total"] integerValue] == 2, @"video filter failed");
        NSDictionary *video = nil;
        for (NSDictionary *candidate in videoPage[@"items"])
            if ([candidate[@"name"] isEqualToString:@"VID_0002.MOV"]) video = candidate;
        require(video != nil, @"indexed video was not returned");
        require([video[@"duration"] doubleValue] == 12.5, @"video duration metadata was lost");
        require([video[@"width"] integerValue] == 1920, @"video dimensions were lost");

        NSDictionary *search = request(@"/v1/media", @"q=new", 200);
        require([search[@"total"] integerValue] == 1, @"case-insensitive filename search failed");

        NSDictionary *first = [items firstObject];
        NSDictionary *asset = request(@"/v1/media_asset",
                                      [NSString stringWithFormat:@"id=%@", first[@"id"]], 200);
        require([asset[@"id"] isEqual:first[@"id"]], @"opaque asset lookup failed");
        request(@"/v1/media_asset", @"id=ffffffffffffffff", 404);
        int unrelatedStatus = 200;
        int unrelatedLength = 0;
        const char *unrelatedType = NULL;
        require(rctl_media_handle("/v1/not_media", "", "", 0, &unrelatedStatus,
                                  &unrelatedLength, &unrelatedType) == NULL,
                @"unrelated endpoint was intercepted");

        make_database_incompatible();
        NSDictionary *closed = request(@"/v1/media", @"refresh=1", 200);
        require([closed[@"total"] integerValue] == 0,
                @"incompatible Photos schema did not fail closed before DCIM fallback");

        make_database_without_uuid();
        NSDictionary *compatible = request(@"/v1/media", @"refresh=1", 200);
        NSDictionary *uuidless = nil;
        for (NSDictionary *candidate in compatible[@"items"])
            if ([candidate[@"name"] isEqualToString:@"IMG_0001.JPG"]) uuidless = candidate;
        require(uuidless != nil, @"UUID-less Photos schema disabled read-only browsing");
        require(![uuidless[@"deletable"] boolValue], @"UUID-less asset became deletable");

        [files removeItemAtPath:kWork error:nil];
        printf("media library test passed\n");
    }
    return 0;
}
