// 使用真实调度器和 NSURLSession；相机动作与远端端点仅在隔离夹具内替换。
#import "TLScheduler.h"
#import <sys/stat.h>

@interface TLRuntimeEvents : NSObject
@property (nonatomic, strong) NSCondition *condition;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *events;
- (void)add:(NSString *)name;
- (NSArray<NSDictionary *> *)waitForCount:(NSUInteger)count timeout:(NSTimeInterval)timeout;
@end
@implementation TLRuntimeEvents
- (instancetype)init {
    if ((self = [super init])) { _condition = [NSCondition new]; _events = [NSMutableArray array]; }
    return self;
}
- (void)add:(NSString *)name {
    [_condition lock];
    [_events addObject:@{@"name": name, @"at": [NSDate date]}];
    [_condition broadcast];
    [_condition unlock];
}
- (NSArray<NSDictionary *> *)waitForCount:(NSUInteger)count timeout:(NSTimeInterval)timeout {
    [_condition lock];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (_events.count < count && [_condition waitUntilDate:deadline]) {}
    NSArray *snapshot = [_events copy];
    [_condition unlock];
    return snapshot;
}
@end

static TLConfig *TLRuntimeConfig(NSArray *projects) {
    TLConfig *config = [TLConfig configWithDictionary:@{
        @"storage": @{@"root": @"/var/mobile/TimelapseFixture", @"minFreeGB": @1}, @"projects": projects
    } error:nil];
    EXPECT(config != nil, "runtime config valid");
    return config;
}
static NSDictionary *TLRuntimeProject(NSString *projectID, BOOL enabled) {
    return @{@"id": projectID, @"name": projectID, @"enabled": @(enabled), @"capture": @{@"interval": @5}};
}
static TLState *TLRuntimeState(NSString **rootOut) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    TLEnsureDirectory(root, nil);
    *rootOut = root;
    return [[TLState alloc] initWithPath:[root stringByAppendingPathComponent:@"state.json"]];
}
static TLCaptureResult *TLRuntimeResult(TLCaptureOutcome outcome) {
    TLCaptureResult *result = [TLCaptureResult new];
    result.outcome = outcome;
    result.message = @"隔离调度夹具";
    result.capturedAt = [NSDate date];
    return result;
}
static void TLSeedAttempt(TLState *state, NSString *projectID) {
    [state updateProject:projectID values:@{TLStateLastAttemptAt: TLFormatTimestamp([NSDate dateWithTimeIntervalSinceNow:-3600], NSTimeZone.localTimeZone)} error:nil];
}
static NSTimeInterval TLEventGap(NSArray *events, NSUInteger first, NSUInteger second) {
    if (events.count <= second) return -1;
    return [events[second][@"at"] timeIntervalSinceDate:events[first][@"at"]];
}

static void TLTestSchedulerRuntime(void) {
    NSString *root;
    TLState *state = TLRuntimeState(&root);
    dispatch_queue_t camera = dispatch_queue_create("test.camera.serial", DISPATCH_QUEUE_SERIAL);
    TLRuntimeEvents *events = [TLRuntimeEvents new];
    TLScheduler *scheduler = [[TLScheduler alloc] initWithState:state cameraQueue:camera capture:^TLCaptureResult *(TLProject *project, void (^willOpen)(void)) {
        willOpen(); [events add:project.projectID];
        [NSThread sleepForTimeInterval:2.2];
        return TLRuntimeResult(TLCaptureOutcomeSaved);
    } encoder:nil uploader:nil];
    NSDate *began = [NSDate date];
    [scheduler applyConfig:TLRuntimeConfig(@[TLRuntimeProject(@"a", YES), TLRuntimeProject(@"b", YES)])];
    NSArray *shots = [events waitForCount:4 timeout:20];
    [scheduler stop];
    dispatch_sync(camera, ^{});
    EXPECT(shots.count == 4, "real timers execute two projects twice");
    if (shots.count == 4) {
        EXPECT([shots[0][@"at"] timeIntervalSinceDate:began] >= 4.8, "fresh scheduler observes initial delay");
        EXPECT(TLEventGap(shots, 0, 2) >= 3.7 && TLEventGap(shots, 0, 2) < 6.7, "camera duration is included in interval, no extra full wait");
        EXPECT(TLEventGap(shots, 1, 3) >= 3.7 && TLEventGap(shots, 1, 3) < 6.7, "queued project times from actual camera start");
        EXPECT(TLEventGap(shots, 0, 1) >= 2.1 && TLEventGap(shots, 2, 3) >= 2.1, "camera actions remain serial");
        fprintf(stdout, "调度实测：双项目间隔 %.3fs / %.3fs（各拍摄耗时2.2s，配置5s）\n", TLEventGap(shots, 0, 2), TLEventGap(shots, 1, 3));
    }
    NSUInteger countAtStop = [events waitForCount:0 timeout:0].count;
    EXPECT([events waitForCount:countAtStop + 1 timeout:2.5].count == countAtStop, "stop prevents later captures");
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];

    state = TLRuntimeState(&root); TLSeedAttempt(state, @"a");
    events = [TLRuntimeEvents new];
    TLRuntimeEvents *longEvents = events;
    scheduler = [[TLScheduler alloc] initWithState:state cameraQueue:camera capture:^TLCaptureResult *(TLProject *project, void (^willOpen)(void)) {
        willOpen(); [longEvents add:project.projectID];
        [NSThread sleepForTimeInterval:6.1];
        return TLRuntimeResult(TLCaptureOutcomeFailed);
    } encoder:nil uploader:nil];
    [scheduler applyConfig:TLRuntimeConfig(@[TLRuntimeProject(@"a", YES)])];
    shots = [events waitForCount:2 timeout:15];
    [scheduler stop]; dispatch_sync(camera, ^{}); [scheduler stop];
    EXPECT(shots.count == 2 && TLEventGap(shots, 0, 1) >= 7.8 && TLEventGap(shots, 0, 1) < 9.8, "long failed capture uses bounded two-second delay, no historical burst or full interval");
    fprintf(stdout, "调度实测：长耗时开始间隔 %.3fs（拍摄6.1s后有界等待2s）\n", TLEventGap(shots, 0, 1));
    EXPECT([[[state snapshot][@"projects"] objectForKey:@"a"][@"consecutiveFailures"] integerValue] == 2, "failed attempts retain result accounting");
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];

    state = TLRuntimeState(&root); TLSeedAttempt(state, @"a");
    NSDate *oldAttempt = [state dateForProject:@"a" key:TLStateLastAttemptAt];
    events = [TLRuntimeEvents new]; TLRuntimeEvents *skipEvents = events;
    __block NSUInteger skips = 0;
    scheduler = [[TLScheduler alloc] initWithState:state cameraQueue:camera capture:^TLCaptureResult *(TLProject *project, void (^willOpen)(void)) {
        (void)willOpen; [skipEvents add:project.projectID];
        return TLRuntimeResult(skips++ == 0 ? TLCaptureOutcomeSkippedNight : TLCaptureOutcomeSkippedStorage);
    } encoder:nil uploader:nil];
    [scheduler applyConfig:TLRuntimeConfig(@[TLRuntimeProject(@"a", YES)])];
    shots = [events waitForCount:3 timeout:15];
    [scheduler stop]; dispatch_sync(camera, ^{}); [scheduler stop];
    EXPECT(shots.count == 3 && TLEventGap(shots, 0, 1) >= 4.8 && TLEventGap(shots, 1, 2) >= 4.8, "night and storage skips wait interval without stale-attempt busy loop");
    EXPECT([[state dateForProject:@"a" key:TLStateLastAttemptAt] isEqualToDate:oldAttempt], "pre-camera skips do not fabricate attempts");
    fprintf(stdout, "调度实测：提前跳过间隔 %.3fs / %.3fs\n", TLEventGap(shots, 0, 1), TLEventGap(shots, 1, 2));
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];

    state = TLRuntimeState(&root); TLSeedAttempt(state, @"a");
    events = [TLRuntimeEvents new]; TLRuntimeEvents *reloadEvents = events;
    scheduler = [[TLScheduler alloc] initWithState:state cameraQueue:camera capture:^TLCaptureResult *(TLProject *project, void (^willOpen)(void)) {
        willOpen(); [reloadEvents add:project.projectID];
        [NSThread sleepForTimeInterval:2.2];
        return TLRuntimeResult(TLCaptureOutcomeSkippedDark);
    } encoder:nil uploader:nil];
    [scheduler applyConfig:TLRuntimeConfig(@[TLRuntimeProject(@"a", YES)])];
    EXPECT([events waitForCount:1 timeout:5].count == 1, "hot reload fixture began capture");
    [scheduler applyConfig:TLRuntimeConfig(@[TLRuntimeProject(@"a", NO)])];
    EXPECT([events waitForCount:2 timeout:7.5].count == 1, "old-config completion cannot reactivate paused project");
    [scheduler applyConfig:TLRuntimeConfig(@[TLRuntimeProject(@"a", YES)])];
    EXPECT([events waitForCount:2 timeout:4].count == 2, "resume performs one overdue capture");
    NSMutableDictionary *changed = [TLRuntimeProject(@"a", YES) mutableCopy];
    changed[@"capture"] = @{@"interval": @8};
    [scheduler applyConfig:TLRuntimeConfig(@[changed])];
    shots = [events waitForCount:3 timeout:11];
    EXPECT(shots.count == 3 && TLEventGap(shots, 1, 2) > 6.8 && TLEventGap(shots, 1, 2) < 9.5, "old-config completion rearms latest enabled interval exactly once");
    [scheduler stop]; dispatch_sync(camera, ^{}); [scheduler stop];
    // 同一持久状态重新创建调度器，不能清掉尝试时间而立即补放历史帧。
    TLState *restored = [[TLState alloc] initWithPath:[root stringByAppendingPathComponent:@"state.json"]];
    TLRuntimeEvents *restartEvents = [TLRuntimeEvents new];
    scheduler = [[TLScheduler alloc] initWithState:restored cameraQueue:camera capture:^TLCaptureResult *(TLProject *project, void (^willOpen)(void)) {
        willOpen(); [restartEvents add:project.projectID]; return TLRuntimeResult(TLCaptureOutcomeSaved);
    } encoder:nil uploader:nil];
    began = [NSDate date];
    [scheduler applyConfig:TLRuntimeConfig(@[TLRuntimeProject(@"a", YES)])];
    shots = [restartEvents waitForCount:1 timeout:6];
    [scheduler stop]; dispatch_sync(camera, ^{}); [scheduler stop];
    EXPECT(shots.count == 1 && [shots[0][@"at"] timeIntervalSinceDate:began] >= 1.8, "restart honors persisted attempt and bounded catch-up");
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];

    state = TLRuntimeState(&root); TLSeedAttempt(state, @"a"); TLSeedAttempt(state, @"b"); TLSeedAttempt(state, @"c");
    dispatch_semaphore_t releaseCamera = dispatch_semaphore_create(0);
    dispatch_async(camera, ^{ dispatch_semaphore_wait(releaseCamera, DISPATCH_TIME_FOREVER); });
    TLRuntimeEvents *queuedEvents = [TLRuntimeEvents new];
    scheduler = [[TLScheduler alloc] initWithState:state cameraQueue:camera capture:^TLCaptureResult *(TLProject *project, void (^willOpen)(void)) {
        willOpen(); [queuedEvents add:project.projectID];
        EXPECT(![project.projectID isEqualToString:@"c"] || project.captureInterval == 8, "queued capture receives reloaded project parameters");
        return TLRuntimeResult(TLCaptureOutcomeSaved);
    } encoder:nil uploader:nil];
    [scheduler applyConfig:TLRuntimeConfig(@[TLRuntimeProject(@"a", YES), TLRuntimeProject(@"b", YES), TLRuntimeProject(@"c", YES)])];
    [NSThread sleepForTimeInterval:3.3];
    NSMutableDictionary *queuedChange = [TLRuntimeProject(@"c", YES) mutableCopy];
    queuedChange[@"capture"] = @{@"interval": @8};
    [scheduler applyConfig:TLRuntimeConfig(@[TLRuntimeProject(@"a", NO), queuedChange])];
    dispatch_semaphore_signal(releaseCamera); dispatch_sync(camera, ^{});
    EXPECT([queuedEvents waitForCount:1 timeout:1].count == 0, "pause/delete/hot-reload discard old captures still waiting for camera");
    shots = [queuedEvents waitForCount:1 timeout:4];
    EXPECT(shots.count == 1 && [shots[0][@"name"] isEqualToString:@"c"], "enabled queued project restarts once with latest config");
    [scheduler stop]; dispatch_sync(camera, ^{}); [scheduler stop];
    // 独立验证 stop，避免暂停/删除的断言被停止状态掩盖。
    dispatch_semaphore_t releaseStopped = dispatch_semaphore_create(0);
    dispatch_async(camera, ^{ dispatch_semaphore_wait(releaseStopped, DISPATCH_TIME_FOREVER); });
    scheduler = [[TLScheduler alloc] initWithState:state cameraQueue:camera capture:^TLCaptureResult *(TLProject *project, void (^willOpen)(void)) {
        willOpen(); [queuedEvents add:project.projectID]; return TLRuntimeResult(TLCaptureOutcomeSaved);
    } encoder:nil uploader:nil];
    [scheduler applyConfig:TLRuntimeConfig(@[TLRuntimeProject(@"a", YES)])];
    [NSThread sleepForTimeInterval:3.3];
    [scheduler stop];
    dispatch_semaphore_signal(releaseStopped); dispatch_sync(camera, ^{});
    EXPECT([queuedEvents waitForCount:2 timeout:0.2].count == 1, "stop discards captures still waiting for camera");
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
}

// 本地 TCP 接收端逐块收包；仅小请求保留完整字节用于精确比较。
@interface TLUploadReceiver : NSObject
@property (nonatomic) int listener;
@property (nonatomic) NSUInteger port;
@property (atomic) NSInteger status;
@property (atomic, copy) NSString *responseText;
@property (atomic) BOOL stall;
@property (atomic) BOOL stopped;
@property (nonatomic, strong) dispatch_group_t worker;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *requests;
- (NSArray<NSDictionary *> *)snapshot;
- (void)stop;
@end
@implementation TLUploadReceiver
- (instancetype)init {
    if ((self = [super init])) {
        _requests = [NSMutableArray array]; _status = 200; _responseText = @"{\"ok\":true}";
        _listener = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in address = {0}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        EXPECT(bind(_listener, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(_listener, 8) == 0, "local upload listener");
        socklen_t length = sizeof(address); getsockname(_listener, (struct sockaddr *)&address, &length); _port = ntohs(address.sin_port);
        _worker = dispatch_group_create();
        dispatch_group_async(_worker, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            while (!self.stopped) {
                int client = accept(self.listener, NULL, NULL);
                if (client < 0) break;
                int noSigPipe = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
                struct timeval timeout = {5, 0}; setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
                NSMutableData *headerData = [NSMutableData data];
                unsigned char ch;
                while (headerData.length < 64 * 1024 && recv(client, &ch, 1, 0) == 1) {
                    [headerData appendBytes:&ch length:1];
                    if (headerData.length >= 4 && memcmp((const char *)headerData.bytes + headerData.length - 4, "\r\n\r\n", 4) == 0) break;
                }
                NSString *header = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding] ?: @"";
                unsigned long long expected = 0;
                for (NSString *line in [header componentsSeparatedByString:@"\r\n"]) {
                    if ([line.lowercaseString hasPrefix:@"content-length:"]) expected = strtoull([[line substringFromIndex:15] UTF8String], NULL, 10);
                }
                if ([header.lowercaseString containsString:@"expect: 100-continue"]) send(client, "HTTP/1.1 100 Continue\r\n\r\n", 25, 0);
                NSMutableData *body = [NSMutableData data];
                unsigned long long received = 0; unsigned char buffer[64 * 1024];
                while (received < expected) {
                    ssize_t count = recv(client, buffer, (size_t)MIN(expected - received, sizeof(buffer)), 0);
                    if (count <= 0) break;
                    if (expected < 4 * 1024 * 1024) [body appendBytes:buffer length:(NSUInteger)count];
                    received += (unsigned long long)count;
                }
                @synchronized (self) { [self.requests addObject:@{@"header": header, @"body": body, @"received": @(received), @"expected": @(expected)}]; }
                while (self.stall && !self.stopped) [NSThread sleepForTimeInterval:0.02];
                NSData *response = [self.responseText dataUsingEncoding:NSUTF8StringEncoding];
                NSString *prefix = [NSString stringWithFormat:@"HTTP/1.1 %ld Fixture\r\nContent-Length: %lu\r\nConnection: close\r\nContent-Type: application/json\r\n\r\n", (long)self.status, (unsigned long)response.length];
                NSData *prefixData = [prefix dataUsingEncoding:NSUTF8StringEncoding];
                send(client, prefixData.bytes, prefixData.length, 0); send(client, response.bytes, response.length, 0); close(client);
            }
        });
    }
    return self;
}
- (NSArray<NSDictionary *> *)snapshot { @synchronized (self) { return [_requests copy]; } }
- (void)stop {
    self.stopped = YES; self.stall = NO;
    shutdown(_listener, SHUT_RDWR); close(_listener);
    dispatch_group_wait(_worker, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
}
@end

@interface TLUploader (RuntimeTransport)
- (BOOL)performRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL status:(NSInteger *)status body:(NSData **)bodyOut error:(NSError **)error;
- (NSTimeInterval)requestTimeout;
- (NSString *)uploadPath:(NSString *)path project:(TLProject *)project target:(NSString *)target config:(TLConfig *)config retryable:(BOOL *)retryable;
@end
@interface TLLocalUploader : TLUploader
@property (nonatomic) NSUInteger fixturePort;
@property (nonatomic) BOOL throwTransport;
@property (nonatomic) NSTimeInterval fixtureTimeout;
@property (nonatomic, strong) NSMutableArray<NSString *> *bodyPaths;
@end
@implementation TLLocalUploader
- (NSTimeInterval)requestTimeout { return self.fixtureTimeout > 0 ? self.fixtureTimeout : 10; }
- (BOOL)performRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL status:(NSInteger *)status body:(NSData **)bodyOut error:(NSError **)error {
    EXPECT(request.HTTPBody == nil || fileURL == nil, "video request has no memory HTTPBody");
    if (fileURL) {
        [self.bodyPaths addObject:fileURL.path];
        struct stat info; EXPECT(stat(fileURL.path.fileSystemRepresentation, &info) == 0, "request file exists until transport");
        if ([fileURL.lastPathComponent hasPrefix:@"tlapse-upload-"]) {
            EXPECT((info.st_mode & 0777) == 0600, "multipart file is private");
        }
    }
    if (self.throwTransport) [NSException raise:@"FixtureTransportException" format:@"隔离异常出口"];
    NSMutableURLRequest *local = [request mutableCopy];
    local.URL = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%lu/%@", (unsigned long)self.fixturePort, request.URL.lastPathComponent]];
    BOOL result = [super performRequest:local fromFile:fileURL status:status body:bodyOut error:error];
    if ([fileURL.lastPathComponent hasPrefix:@"tlapse-upload-"]) {
        EXPECT([[NSFileManager defaultManager] fileExistsAtPath:fileURL.path], "multipart owner survives until synchronous transport returns");
    }
    return result;
}
@end

static NSArray *TLStoredJobs(NSString *root) {
    NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"logs/upload-queue.json"]];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil][@"jobs"] : @[];
}
static void TLDueJobs(NSString *root) {
    NSMutableArray *jobs = [TLStoredJobs(root) mutableCopy];
    for (NSMutableDictionary *job in jobs) job[@"nextAt"] = @"2020-01-01T00:00:00+0000";
    [[NSJSONSerialization dataWithJSONObject:@{@"jobs": jobs} options:0 error:nil] writeToFile:[root stringByAppendingPathComponent:@"logs/upload-queue.json"] atomically:YES];
}
static TLLocalUploader *TLLocalUpload(TLState *state, NSString *root, TLUploadReceiver *receiver) {
    TLLocalUploader *uploader = [[TLLocalUploader alloc] initWithState:state storageRoot:root];
    uploader.fixturePort = receiver.port; uploader.bodyPaths = [NSMutableArray array];
    return uploader;
}
static void TLTestUploadRuntime(void) {
    NSString *root; TLState *state = TLRuntimeState(&root);
    TLUploadReceiver *receiver = [TLUploadReceiver new];
    TLConfig *config = [TLConfig configWithDictionary:@{
        @"storage": @{@"root": @"/var/mobile/TimelapseFixture"},
        @"uploads": @{@"telegram": @{@"enabled": @YES, @"botToken": @"123:fixture-token", @"chatId": @"fixture-chat"},
                       @"webdav": @{@"enabled": @YES, @"url": @"https://fixture.invalid/dav/", @"user": @"fixture-user", @"password": @"fixture-password"}},
        @"projects": @[@{@"id": @"plant", @"name": @"plant", @"upload": @[@"telegram", @"webdav"]}]
    } error:nil];
    EXPECT(config != nil && config.telegramEnabled && config.webdavEnabled, "fixture upload config enabled locally");
    if (!config) { [receiver stop]; return; }
    TLProject *project = config.projects.firstObject;
    NSString *path = [root stringByAppendingPathComponent:@"projects/plant/videos/clip.mp4"];
    TLEnsureDirectory(path.stringByDeletingLastPathComponent, nil);
    NSData *video = [@"video\0bytes\r\n尾" dataUsingEncoding:NSUTF8StringEncoding];
    [video writeToFile:path atomically:YES];
    TLLocalUploader *uploader = TLLocalUpload(state, root, receiver);
    NSString *summary = [uploader uploadFileAtPath:path project:project config:config];
    EXPECT([summary containsString:@"telegram 已上传"] && [summary containsString:@"webdav 已上传"], "real loopback file transport returns local fixture acceptance");
    NSArray *requests = receiver.snapshot;
    EXPECT(requests.count == 2, "both video protocols reached loopback receiver");
    if (requests.count == 2) {
        NSString *header = requests[0][@"header"];
        NSRange start = [header rangeOfString:@"boundary="];
        NSString *boundary = start.location == NSNotFound ? @"" : [[[header substringFromIndex:start.location + start.length] componentsSeparatedByString:@"\r\n"] firstObject];
        NSData *expected = TLMultipartBody(boundary, @{@"chat_id": @"fixture-chat", @"caption": @"plant clip.mp4"}, @"video", @"clip.mp4", video, @"video/mp4");
        EXPECT([requests[0][@"body"] isEqualToData:expected], "actual multipart wire bytes equal fields, video and closing boundary");
        EXPECT([requests[0][@"received"] unsignedLongLongValue] == expected.length && [requests[0][@"expected"] unsignedLongLongValue] == expected.length, "multipart content length is exact");
        EXPECT([requests[1][@"body"] isEqualToData:video], "WebDAV file upload sends exact video bytes");
    }
    NSString *temporary = uploader.bodyPaths.firstObject;
    EXPECT(![[NSFileManager defaultManager] fileExistsAtPath:temporary] && [[NSFileManager defaultManager] fileExistsAtPath:path], "success removes temporary multipart and preserves source video");
    EXPECT([state stringForProject:@"plant" key:TLStateLastUploadAt].length > 0, "accepted transfer records upload timestamp");

    receiver.status = 503; receiver.responseText = @"fixture 123:fixture-token fixture-chat fixture-user fixture-password";
    summary = [uploader uploadFileAtPath:path project:project config:config];
    EXPECT([summary containsString:@"重试队列"] && uploader.pendingCount == 2, "transient failures create persistent jobs for both targets");
    NSArray *jobs = TLStoredJobs(root);
    EXPECT(jobs.count == 2 && [jobs[0][@"attempts"] integerValue] == 1, "initial failure is persisted as attempt one");
    EXPECT(![[jobs description] containsString:@"fixture-token"] && ![[jobs description] containsString:@"fixture-password"] && ![summary containsString:@"fixture-chat"], "failure summaries and jobs redact configured credentials");
    NSDate *nextAt = TLParseTimestamp(jobs.firstObject[@"nextAt"]);
    EXPECT([nextAt timeIntervalSinceNow] > 27 && [nextAt timeIntervalSinceNow] <= 30, "first failure schedules 30-second backoff");
    TLLocalUploader *restored = TLLocalUpload(state, root, receiver);
    NSUInteger requestCount = receiver.snapshot.count;
    [restored drainWithConfig:config];
    EXPECT(restored.pendingCount == 2 && receiver.snapshot.count == requestCount, "new uploader restores jobs without sending before due time");
    for (NSInteger failure = 2; failure <= 5; failure++) {
        TLDueJobs(root); [restored drainWithConfig:config];
        jobs = TLStoredJobs(root);
        if (failure < 5) {
            EXPECT(jobs.count == 2 && [jobs[0][@"attempts"] integerValue] == failure, "retry failure advances persisted attempt");
            NSTimeInterval remaining = [TLParseTimestamp(jobs[0][@"nextAt"]) timeIntervalSinceNow];
            EXPECT(remaining > TLUploadRetryDelay(failure) - 3 && remaining <= TLUploadRetryDelay(failure), "reachable retry backoff matches attempt");
        }
    }
    EXPECT(restored.pendingCount == 0, "fifth total failure removes exhausted persistent jobs");
    requests = receiver.snapshot;
    NSUInteger alertCount = 0;
    for (NSDictionary *request in requests) if ([request[@"header"] containsString:@"/sendMessage "]) alertCount++;
    EXPECT(alertCount == 2, "drain exhaustion uses existing Telegram text alert once per target");
    NSString *uploadLog = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"logs/uploads.log"] encoding:NSUTF8StringEncoding error:nil];
    EXPECT([uploadLog containsString:@"失败 5 次后停止"] && ![uploadLog containsString:@"fixture-token"] && ![uploadLog containsString:@"fixture-password"], "exhaustion log is accurate and redacted despite alert transport failure");

    // 凭据横跨原来的180字符截断边界时，也不能留下任何未匹配的前缀。
    NSString *padding = [@"x" stringByPaddingToLength:174 withString:@"x" startingAtIndex:0];
    for (NSString *secret in @[@"123:fixture-token", @"fixture-password"]) {
        receiver.responseText = [padding stringByAppendingString:secret];
        NSString *redacted = [restored uploadFileAtPath:path project:project config:config];
        EXPECT([redacted containsString:[padding stringByAppendingString:@"***"]], "redact complete credential before truncating remote error");
        EXPECT(![[TLStoredJobs(root) description] containsString:secret], "cross-boundary credentials never reach persisted jobs");
    }
    // 凭据互相包含或部分重叠时，原文中的匹配区间都应一次脱敏。
    NSArray *overlaps = @[
        @{@"user": @"fixture", @"password": @"fixture-password", @"text": @"fixture-password"},
        @{@"user": @"secret-left", @"password": @"left-right", @"text": @"secret-left-right"},
        @{@"user": @"fixture-user", @"password": @"token-tail", @"text": @"123:fixture-token-tail"},
    ];
    for (NSDictionary *overlap in overlaps) {
        NSMutableDictionary *document = [[config dictionaryRepresentation] mutableCopy];
        NSMutableDictionary *uploads = [document[@"uploads"] mutableCopy];
        NSMutableDictionary *webdav = [uploads[@"webdav"] mutableCopy];
        webdav[@"user"] = overlap[@"user"]; webdav[@"password"] = overlap[@"password"];
        uploads[@"webdav"] = webdav; document[@"uploads"] = uploads;
        TLConfig *overlapConfig = [TLConfig configWithDictionary:document error:nil];
        EXPECT(overlapConfig != nil, "overlapping fixture credentials remain valid config");
        if (!overlapConfig) continue;
        // 同时覆盖原始HTTP错误与Telegram HTTP200业务拒绝的两条脱敏入口。
        for (NSNumber *status in @[@503, @200]) {
            [@"{\"jobs\":[]}" writeToFile:[root stringByAppendingPathComponent:@"logs/upload-queue.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            receiver.status = status.integerValue;
            receiver.responseText = status.integerValue == 503 ? overlap[@"text"] :
                [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@{@"ok": @NO, @"error_code": @503, @"description": overlap[@"text"]} options:0 error:nil] encoding:NSUTF8StringEncoding];
            NSString *redacted = [restored uploadFileAtPath:path project:project config:overlapConfig];
            EXPECT([redacted containsString:@"telegram 失败：***"] && ![redacted containsString:@"-password"] && ![redacted containsString:@"-right"] && ![redacted containsString:@"-tail"], "overlapping credential ranges leave no exposed suffix");
            NSArray *stored = TLStoredJobs(root);
            EXPECT([stored.firstObject[@"lastError"] isEqualToString:@"telegram 失败：***"], "persisted overlapping credentials are fully masked");
        }
    }
    // 去掉以上独立错误夹具的记账，不影响后续永久错误及次数断言。
    [@"{\"jobs\":[]}" writeToFile:[root stringByAppendingPathComponent:@"logs/upload-queue.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // 原先已排队的任务遭永久错误时必须退出，不能无限恢复重试。
    [restored recordFailureForProject:@"plant" fileName:@"clip.mp4" target:@"telegram" message:@"隔离前置"];
    TLDueJobs(root); receiver.status = 400; receiver.responseText = @"{\"ok\":false,\"error_code\":400,\"description\":\"permanent fixture\"}";
    [restored drainWithConfig:config];
    EXPECT(restored.pendingCount == 0 && [[state stringForProject:@"plant" key:TLStateLastUploadError] containsString:@"失败"], "permanent drain failure is recorded and removed");
    [restored recordFailureForProject:@"plant" fileName:@"clip.mp4" target:@"telegram" message:@"隔离前置"];
    [restored uploadFileAtPath:path project:project config:config];
    EXPECT(restored.pendingCount == 0, "manual permanent failure also removes prior job");

    // 手动上传路径也能耗尽已有四次失败，不能只有 drain 才通知。
    for (NSInteger index = 0; index < 4; index++) [restored recordFailureForProject:@"plant" fileName:@"clip.mp4" target:@"telegram" message:@"隔离前置"];
    TLState *freshAlertState = [[TLState alloc] initWithPath:[root stringByAppendingPathComponent:@"manual-alert-state.json"]];
    TLLocalUploader *manual = TLLocalUpload(freshAlertState, root, receiver);
    receiver.status = 503;
    requestCount = receiver.snapshot.count;
    [manual uploadFileAtPath:path project:project config:config];
    NSUInteger manualAlerts = 0;
    requests = receiver.snapshot;
    for (NSUInteger index = requestCount; index < requests.count; index++) if ([requests[index][@"header"] containsString:@"/sendMessage "]) manualAlerts++;
    EXPECT(manualAlerts == 1, "manual upload exhaustion also invokes one text alert without video recursion");

    receiver.status = 200; receiver.responseText = @"{\"ok\":true}"; receiver.stall = YES;
    TLLocalUploader *timeout = TLLocalUpload(state, root, receiver); timeout.fixtureTimeout = 0.2;
    [timeout uploadFileAtPath:path project:project config:config];
    EXPECT(![[NSFileManager defaultManager] fileExistsAtPath:timeout.bodyPaths.firstObject], "cancelled timeout removes multipart file");
    receiver.stall = NO;
    TLLocalUploader *exceptional = TLLocalUpload(state, root, receiver); exceptional.throwTransport = YES;
    BOOL raised = NO;
    // 异常不能跨 GCD 执行边界捕获，直接覆盖实际上传动作的异常展开出口。
    @try { [exceptional uploadPath:path project:project target:@"telegram" config:config retryable:NULL]; }
    @catch (NSException *exception) { raised = [exception.name isEqualToString:@"FixtureTransportException"]; }
    EXPECT(raised && ![[NSFileManager defaultManager] fileExistsAtPath:exceptional.bodyPaths.firstObject], "exception propagates and releases temporary body");
    for (NSString *bodyPath in restored.bodyPaths) {
        if ([bodyPath.lastPathComponent hasPrefix:@"tlapse-upload-"]) EXPECT(![[NSFileManager defaultManager] fileExistsAtPath:bodyPath], "failed retries release each multipart file");
    }
    // 50MiB 是有效输入上界：接收端逐块计数，夹具也不把整个请求留在内存。
    int large = open(path.fileSystemRepresentation, O_WRONLY | O_TRUNC);
    EXPECT(large >= 0 && ftruncate(large, 50 * 1024 * 1024) == 0, "prepare maximum-size sparse upload fixture"); if (large >= 0) close(large);
    receiver.status = 200;
    TLLocalUploader *bounded = TLLocalUpload(state, root, receiver);
    summary = [bounded uploadFileAtPath:path project:project config:config];
    requests = receiver.snapshot;
    EXPECT([summary containsString:@"telegram 已上传"] && [requests[requests.count - 2][@"received"] unsignedLongLongValue] > 50 * 1024 * 1024 && [requests.lastObject[@"received"] unsignedLongLongValue] == 50 * 1024 * 1024, "50MiB video traverses real file transport for both targets");
    EXPECT(![[NSFileManager defaultManager] fileExistsAtPath:bounded.bodyPaths.firstObject], "large multipart cleaned after transfer");
    [receiver stop];
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
}

static void TLTestRuntime(void) {
    TLTestUploadRuntime();
    TLTestSchedulerRuntime();
}
