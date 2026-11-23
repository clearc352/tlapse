#import "TLDaemon.h"

#import "TLCapture.h"
#import "TLConfig.h"
#import "TLEncoder.h"
#import "TLLog.h"
#import "TLScheduler.h"
#import "TLState.h"
#import "TLSupport.h"
#import "TLUploader.h"
#import "TLVersion.h"
#import "TLWeb.h"

#import <IOKit/pwr_mgt/IOPMLib.h>

#import <errno.h>
#import <fcntl.h>
#import <signal.h>
#import <stdint.h>
#import <string.h>
#import <unistd.h>

// MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT. flags is the fatal limit in megabytes.
// iOS 12 exports the symbol and does not ship the header.
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);

static const uint32_t TLDaemonMemoryMegabytes = 96;

/// 0 when the limit was raised. -1 when this process is not root. Otherwise errno.
static int TLRaiseDaemonMemoryLimit(void) {
    if (geteuid() != 0) {
        return -1;
    }
    if (memorystatus_control(6, (int32_t)getpid(), TLDaemonMemoryMegabytes, NULL, 0) == 0) {
        return 0;
    }
    return errno != 0 ? errno : EPERM;
}

@implementation TLDaemon {
    NSString *_configPath;
    TLConfig *_config;
    TLState *_state;
    TLCapture *_capture;
    TLEncoder *_encoder;
    TLUploader *_uploader;
    TLScheduler *_scheduler;
    TLWebServer *_web;
    dispatch_queue_t _cameraQueue;
    dispatch_queue_t _watchQueue;
    dispatch_source_t _configSource;
    int _configFD;
    BOOL _watchingDirectory;
    volatile BOOL _stopped;
    NSInteger _reloadGeneration;
    NSMutableArray *_keptSources;
    IOPMAssertionID _assertion;
    BOOL _assertionHeld;
}

- (int)runWithConfigPath:(NSString *)path {
    _configPath = [path copy];
    _configFD = -1;
    _cameraQueue = dispatch_queue_create("com.ddxyl.tlapsed.camera", DISPATCH_QUEUE_SERIAL);
    _watchQueue = dispatch_queue_create("com.ddxyl.tlapsed.watch", DISPATCH_QUEUE_SERIAL);
    _capture = [[TLCapture alloc] init];
    _encoder = [[TLEncoder alloc] init];

    NSError *error = nil;
    TLConfig *initial = [TLConfig configWithContentsOfFile:path error:&error];
    NSString *storageRoot = initial.storageRoot ?: TLDefaultStorageRoot;
    // iPhone 6 把没声明上限的守护进程卡在 6MB。编码一张 1920 宽的照片会超过它，
    // 进程在快门之后、写文件之前被杀掉，网页就只看到 Failed to fetch。
    int memoryLimit = TLRaiseDaemonMemoryLimit();
    if (!TLDropToMobileUser(storageRoot, &error)) {
        fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        return 3;
    }
    TLLogSetup([storageRoot stringByAppendingPathComponent:@"logs/tlapsed.log"]);
    TLLogInfo(@"tlapsed %@ 启动，配置 %@", TLAPSED_VERSION_STRING, path);
    if (memoryLimit == 0) {
        TLLogInfo(@"拍照内存上限已提高到 %u MB", TLDaemonMemoryMegabytes);
    } else if (memoryLimit < 0) {
        TLLogError(@"没能提高拍照内存上限：进程不是 root。网页拍照会在保存照片时退出");
    } else {
        TLLogError(@"没能提高拍照内存上限：%s。网页拍照会在保存照片时退出", strerror(memoryLimit));
    }
    [self acquireSleepAssertion];

    _state = [[TLState alloc] initWithPath:[storageRoot stringByAppendingPathComponent:@"state.json"]];
    [_state updateDaemon:@{
        @"pid": @(getpid()),
        @"startedAt": TLFormatTimestamp([NSDate date], [NSTimeZone localTimeZone]),
        @"version": TLAPSED_VERSION_STRING,
    } error:nil];

    __weak TLDaemon *weakSelf = self;
    _uploader = [[TLUploader alloc] initWithState:_state storageRoot:storageRoot];
    _scheduler = [[TLScheduler alloc] initWithState:_state cameraQueue:_cameraQueue capture:^TLCaptureResult *(TLProject *project, void (^willOpenCamera)(void)) {
        TLDaemon *strongSelf = weakSelf;
        if (!strongSelf) {
            TLCaptureResult *missing = [[TLCaptureResult alloc] init];
            missing.outcome = TLCaptureOutcomeFailed;
            missing.message = @"守护进程已停止";
            missing.capturedAt = [NSDate date];
            return missing;
        }
        TLConfig *activeConfig = nil;
        @synchronized (strongSelf) {
            activeConfig = strongSelf->_config;
        }
        if (!activeConfig) {
            TLCaptureResult *missing = [[TLCaptureResult alloc] init];
            missing.outcome = TLCaptureOutcomeFailed;
            missing.message = @"配置尚未加载";
            missing.capturedAt = [NSDate date];
            return missing;
        }
        return [strongSelf->_capture captureProject:project
                                         storageRoot:activeConfig.storageRoot
                                           minFreeGB:activeConfig.minFreeGB
                                              manual:NO
                                     willOpenCamera:willOpenCamera];
    } encoder:_encoder uploader:_uploader];
    _web = [[TLWebServer alloc] initWithConfigPath:_configPath state:_state snap:^TLCaptureResult *(TLProject *project) {
        TLDaemon *strongSelf = weakSelf;
        if (!strongSelf) {
            return nil;
        }
        __block TLCaptureResult *result = nil;
        dispatch_sync(strongSelf->_cameraQueue, ^{
            TLConfig *activeConfig = nil;
            @synchronized (strongSelf) {
                activeConfig = strongSelf->_config;
            }
            if (!activeConfig) {
                result = [[TLCaptureResult alloc] init];
                result.outcome = TLCaptureOutcomeFailed;
                result.message = @"配置尚未加载";
                result.capturedAt = [NSDate date];
                return;
            }
            result = [strongSelf->_capture captureProject:project
                                               storageRoot:activeConfig.storageRoot
                                                 minFreeGB:activeConfig.minFreeGB
                                                    manual:YES
                                           willOpenCamera:^{
                [strongSelf->_state updateProject:project.projectID
                                           values:@{TLStateLastAttemptAt: TLFormatTimestamp([NSDate date], [NSTimeZone localTimeZone])}
                                            error:nil];
            }];
            if (result) {
                [strongSelf->_state recordCaptureResult:result projectID:project.projectID];
            }
        });
        return result;
    }];
    _web.encoder = _encoder;
    _web.uploader = _uploader;

    if (initial) {
        [self applyConfig:initial];
    } else {
        TLLogError(@"配置暂不可用：%@。修正 %@ 后会自动加载", error.localizedDescription ?: @"无法读取", path);
    }
    [self armConfigWatch];
    [self installSignals];

    while (!_stopped) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3600, true);
        }
    }

    TLLogInfo(@"正在停止");
    [_web stop];
    [_scheduler stop];
    [_capture cancel];
    dispatch_semaphore_t drained = dispatch_semaphore_create(0);
    dispatch_async(_cameraQueue, ^{
        dispatch_semaphore_signal(drained);
    });
    dispatch_semaphore_wait(drained, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (_configSource) {
        dispatch_source_cancel(_configSource);
        _configSource = nil;
    }
    [self releaseSleepAssertion];
    TLLogInfo(@"守护进程退出");
    return 0;
}

- (void)applyConfig:(TLConfig *)config {
    @synchronized (self) {
        _config = config;
    }
    NSString *logPath = [config.storageRoot stringByAppendingPathComponent:@"logs/tlapsed.log"];
    TLLogSetup(logPath);
    NSError *error = nil;
    if (!TLEnsureDirectory([config.storageRoot stringByAppendingPathComponent:@"projects"], &error)) {
        TLLogError(@"无法创建存储目录：%@", error.localizedDescription);
    }
    [_uploader updateStorageRoot:config.storageRoot];
    TLLogInfo(@"已加载配置，启用 %ld 个项目。定时拍照、合成、上传和网页控制台可用", (long)config.enabledProjectCount);
    for (TLProject *project in config.projects) {
        if (!project.enabled) {
            continue;
        }
        TLLogInfo(@"%@ %@：每 %.0f 秒拍摄，分辨率 %@", project.projectID, project.name, project.captureInterval, project.resolution);
    }
    [_state updateDaemon:@{
        @"pid": @(getpid()),
        @"version": TLAPSED_VERSION_STRING,
    } error:nil];
    [_scheduler applyConfig:config];
    NSError *webError = nil;
    if (![_web applyConfig:config error:&webError]) {
        TLLogError(@"控制台启动失败：%@", webError.localizedDescription ?: @"未知错误");
    }
}

- (void)installSignals {
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    signal(SIGHUP, SIG_IGN);
    _keptSources = [NSMutableArray array];
    __weak TLDaemon *weakSelf = self;
    dispatch_queue_t queue = dispatch_get_main_queue();
    for (NSNumber *signalNumber in @[@SIGTERM, @SIGINT]) {
        int number = signalNumber.intValue;
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)number, 0, queue);
        dispatch_source_set_event_handler(source, ^{
            TLDaemon *strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_stopped) {
                return;
            }
            strongSelf->_stopped = YES;
            CFRunLoopStop(CFRunLoopGetMain());
        });
        dispatch_resume(source);
        [_keptSources addObject:source];
    }
    dispatch_source_t reload = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGHUP, 0, queue);
    dispatch_source_set_event_handler(reload, ^{
        TLDaemon *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        dispatch_async(strongSelf->_watchQueue, ^{
            [strongSelf scheduleReload];
        });
    });
    dispatch_resume(reload);
    [_keptSources addObject:reload];
}

- (void)acquireSleepAssertion {
    IOReturn result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep,
                                                   kIOPMAssertionLevelOn,
                                                   CFSTR("tlapsed"),
                                                   &_assertion);
    if (result == kIOReturnSuccess) {
        _assertionHeld = YES;
        TLLogInfo(@"已阻止系统空闲睡眠");
    } else {
        TLLogError(@"无法阻止系统空闲睡眠（IOReturn %d）。熄屏后请检查帧间隔是否被拉开", result);
    }
}

- (void)releaseSleepAssertion {
    if (_assertionHeld) {
        IOPMAssertionRelease(_assertion);
        _assertionHeld = NO;
    }
}

- (void)armConfigWatch {
    if (_stopped) {
        return;
    }
    int fd = open(_configPath.fileSystemRepresentation, O_EVTONLY);
    BOOL watchingDirectory = NO;
    if (fd < 0) {
        NSString *directory = _configPath.stringByDeletingLastPathComponent;
        fd = open(directory.fileSystemRepresentation, O_EVTONLY);
        watchingDirectory = YES;
    }
    if (fd < 0) {
        TLLogError(@"无法监听配置文件：%s", strerror(errno));
        return;
    }
    if (_configSource) {
        dispatch_source_cancel(_configSource);
    }
    _configFD = fd;
    _watchingDirectory = watchingDirectory;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
                                                      (uintptr_t)fd,
                                                      DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_EXTEND,
                                                      _watchQueue);
    __weak TLDaemon *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        TLDaemon *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        unsigned long flags = dispatch_source_get_data(source);
        [strongSelf scheduleReload];
        if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME)) {
            dispatch_source_cancel(source);
        }
    });
    dispatch_source_set_cancel_handler(source, ^{
        close(fd);
        TLDaemon *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_stopped || strongSelf->_configSource != source) {
            return;
        }
        strongSelf->_configSource = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), strongSelf->_watchQueue, ^{
            [strongSelf armConfigWatch];
        });
    });
    _configSource = source;
    dispatch_resume(source);
}

- (void)scheduleReload {
    _reloadGeneration += 1;
    NSInteger generation = _reloadGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), _watchQueue, ^{
        if (generation != self->_reloadGeneration || self->_stopped) {
            return;
        }
        [self reloadConfig];
    });
}

- (void)reloadConfig {
    NSError *error = nil;
    TLConfig *config = [TLConfig configWithContentsOfFile:_configPath error:&error];
    if (!config) {
        TLLogError(@"配置没有生效：%@", error.localizedDescription ?: @"无法读取");
        return;
    }
    if (!TLStorageRootAllowed(config.storageRoot)) {
        TLLogError(@"配置没有生效：storage.root 不在 /var/mobile/ 下面");
        return;
    }
    NSError *directoryError = nil;
    if (!TLEnsureDirectory(config.storageRoot, &directoryError)) {
        TLLogError(@"配置没有生效：%@", directoryError.localizedDescription);
        return;
    }
    TLConfig *current = nil;
    @synchronized (self) {
        current = _config;
    }
    if (current && ![config.storageRoot isEqualToString:current.storageRoot]) {
        TLLogError(@"运行中不改存储目录。请停止守护进程后再修改 storage.root");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyConfig:config];
        if (self->_watchingDirectory) {
            dispatch_source_cancel(self->_configSource);
        }
    });
}

@end
