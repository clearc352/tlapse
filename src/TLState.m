#import "TLState.h"

#import "TLCapture.h"
#import "TLLog.h"
#import "TLRules.h"
#import "TLSupport.h"

NSString *const TLStateLastAttemptAt = @"lastAttemptAt";
NSString *const TLStateLastCaptureAt = @"lastCaptureAt";
NSString *const TLStateFrameCount = @"frameCount";
NSString *const TLStateLastFile = @"lastFile";
NSString *const TLStateLastError = @"lastError";
NSString *const TLStateConsecutiveFailures = @"consecutiveFailures";
NSString *const TLStateLastEncodeAt = @"lastEncodeAt";
NSString *const TLStateLastEncodeAttemptAt = @"lastEncodeAttemptAt";
NSString *const TLStateLastEncodeFile = @"lastEncodeFile";
NSString *const TLStateLastEncodeError = @"lastEncodeError";
NSString *const TLStateLastUploadAt = @"lastUploadAt";
NSString *const TLStateLastUploadError = @"lastUploadError";

// Lives with state so host tests can record outcomes without linking the camera.
@implementation TLCaptureResult
@end

@implementation TLState {
    NSString *_path;
    NSString *_lockPath;
    NSLock *_threadLock;
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _path = [path copy];
        _lockPath = [path stringByAppendingString:@".lock"];
        _threadLock = [[NSLock alloc] init];
    }
    return self;
}

- (BOOL)withRootWriting:(BOOL)writing block:(void (^)(NSMutableDictionary *root))block error:(NSError **)error {
    [_threadLock lock];
    TLFileLock *fileLock = [[TLFileLock alloc] initWithPath:_lockPath];
    if (![fileLock lockWithTimeout:5 error:error]) {
        [_threadLock unlock];
        return NO;
    }
    NSMutableDictionary *root = [self readRoot];
    block(root);
    BOOL ok = YES;
    if (writing) {
        ok = [self writeRoot:root error:error];
    }
    [fileLock unlock];
    [_threadLock unlock];
    return ok;
}

- (NSMutableDictionary *)readRoot {
    NSData *data = [NSData dataWithContentsOfFile:_path];
    if (data.length == 0) {
        return [NSMutableDictionary dictionary];
    }
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        NSString *badPath = [NSString stringWithFormat:@"%@.bad-%@", _path, [NSUUID UUID].UUIDString];
        [[NSFileManager defaultManager] moveItemAtPath:_path toPath:badPath error:nil];
        TLLogError(@"状态文件损坏，已改名为 %@", badPath.lastPathComponent);
        return [NSMutableDictionary dictionary];
    }
    return [object mutableCopy];
}

- (BOOL)writeRoot:(NSDictionary *)root error:(NSError **)error {
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                                                     error:&jsonError];
    if (!data) {
        if (error) {
            *error = TLError(TLErrorCodeStorage, jsonError.localizedDescription ?: @"无法编码状态文件");
        }
        return NO;
    }
    return TLWriteDataAtomic(data, _path, error);
}

- (NSMutableDictionary *)mutableProjects:(NSMutableDictionary *)root {
    id existing = root[@"projects"];
    NSMutableDictionary *projects = [existing isKindOfClass:[NSDictionary class]] ? [existing mutableCopy] : [NSMutableDictionary dictionary];
    root[@"projects"] = projects;
    return projects;
}

- (NSDictionary *)snapshot {
    __block NSDictionary *copy = @{};
    [self withRootWriting:NO block:^(NSMutableDictionary *root) {
        copy = [root copy] ?: @{};
    } error:nil];
    return copy;
}

- (NSDictionary *)projectEntry:(NSString *)projectID {
    id projects = self.snapshot[@"projects"];
    if (![projects isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    id entry = ((NSDictionary *)projects)[projectID];
    return [entry isKindOfClass:[NSDictionary class]] ? entry : @{};
}

- (NSDate *)dateForProject:(NSString *)projectID key:(NSString *)key {
    id value = [self projectEntry:projectID][key];
    return [value isKindOfClass:[NSString class]] ? TLParseTimestamp(value) : nil;
}

- (NSInteger)integerForProject:(NSString *)projectID key:(NSString *)key {
    id value = [self projectEntry:projectID][key];
    return [value isKindOfClass:[NSNumber class]] ? [value integerValue] : 0;
}

- (NSString *)stringForProject:(NSString *)projectID key:(NSString *)key {
    id value = [self projectEntry:projectID][key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

- (BOOL)updateProject:(NSString *)projectID values:(NSDictionary *)values error:(NSError **)error {
    return [self withRootWriting:YES block:^(NSMutableDictionary *root) {
        NSMutableDictionary *projects = [self mutableProjects:root];
        NSMutableDictionary *entry = [projects[projectID] isKindOfClass:[NSDictionary class]] ? [projects[projectID] mutableCopy] : [NSMutableDictionary dictionary];
        [entry addEntriesFromDictionary:values];
        projects[projectID] = entry;
    } error:error];
}

- (BOOL)updateDaemon:(NSDictionary *)values error:(NSError **)error {
    return [self withRootWriting:YES block:^(NSMutableDictionary *root) {
        NSMutableDictionary *daemon = [root[@"daemon"] isKindOfClass:[NSDictionary class]] ? [root[@"daemon"] mutableCopy] : [NSMutableDictionary dictionary];
        [daemon addEntriesFromDictionary:values];
        root[@"daemon"] = daemon;
    } error:error];
}

- (NSInteger)recordCaptureResult:(TLCaptureResult *)result projectID:(NSString *)projectID {
    if (result.outcome == TLCaptureOutcomeSkippedNight || result.outcome == TLCaptureOutcomeSkippedStorage) {
        return [self integerForProject:projectID key:TLStateConsecutiveFailures];
    }
    __block NSInteger failures = 0;
    [self withRootWriting:YES block:^(NSMutableDictionary *root) {
        NSMutableDictionary *projects = [self mutableProjects:root];
        NSMutableDictionary *entry = [projects[projectID] isKindOfClass:[NSDictionary class]] ? [projects[projectID] mutableCopy] : [NSMutableDictionary dictionary];
        if (result.outcome == TLCaptureOutcomeSaved) {
            NSInteger count = [entry[TLStateFrameCount] integerValue] + 1;
            entry[TLStateFrameCount] = @(count);
            entry[TLStateLastCaptureAt] = TLFormatTimestamp(result.capturedAt ?: [NSDate date], [NSTimeZone localTimeZone]);
            entry[TLStateLastFile] = result.relativePath ?: @"";
            entry[TLStateLastError] = @"";
            entry[TLStateConsecutiveFailures] = @0;
            failures = 0;
        } else if (result.outcome == TLCaptureOutcomeFailed) {
            failures = [entry[TLStateConsecutiveFailures] integerValue] + 1;
            entry[TLStateConsecutiveFailures] = @(failures);
            entry[TLStateLastError] = result.message ?: @"拍照失败";
        } else if (result.outcome == TLCaptureOutcomeSkippedDark) {
            entry[@"lastSkip"] = result.message ?: @"画面过暗";
            failures = [entry[TLStateConsecutiveFailures] integerValue];
        }
        projects[projectID] = entry;
    } error:nil];
    return failures;
}

@end
