#import "TLScheduler.h"

#import "TLCapture.h"
#import "TLConfig.h"
#import "TLEncode.h"
#import "TLEncoder.h"
#import "TLJobs.h"
#import "TLLog.h"
#import "TLRules.h"
#import "TLState.h"
#import "TLSupport.h"
#import "TLUploader.h"

@implementation TLScheduler {
    TLState *_state;
    dispatch_queue_t _cameraQueue;
    dispatch_queue_t _workQueue;
    TLScheduledCapture _capture;
    TLEncoder *_encoder;
    TLUploader *_uploader;
    dispatch_queue_t _queue;
    TLConfig *_config;
    NSMutableDictionary<NSString *, dispatch_source_t> *_timers;
    NSMutableDictionary<NSString *, dispatch_source_t> *_encodeTimers;
    dispatch_source_t _maintenance;
    NSMutableSet<NSString *> *_inflight;
    NSMutableSet<NSString *> *_encodeInflight;
    NSMutableSet<NSString *> *_nightAnnounced;
    BOOL _stopped;
    NSDate *_lastStorageLog;
}

- (instancetype)initWithState:(TLState *)state
                  cameraQueue:(dispatch_queue_t)cameraQueue
                      capture:(TLScheduledCapture)capture
                      encoder:(TLEncoder *)encoder
                     uploader:(TLUploader *)uploader {
    self = [super init];
    if (self) {
        _state = state;
        _cameraQueue = cameraQueue;
        _capture = [capture copy];
        _encoder = encoder;
        _uploader = uploader;
        _queue = dispatch_queue_create("com.ddxyl.tlapsed.scheduler", DISPATCH_QUEUE_SERIAL);
        _workQueue = dispatch_queue_create("com.ddxyl.tlapsed.work", DISPATCH_QUEUE_SERIAL);
        _timers = [NSMutableDictionary dictionary];
        _encodeTimers = [NSMutableDictionary dictionary];
        _inflight = [NSMutableSet set];
        _encodeInflight = [NSMutableSet set];
        _nightAnnounced = [NSMutableSet set];
    }
    return self;
}

- (void)applyConfig:(TLConfig *)config {
    dispatch_async(_queue, ^{
        if (self->_stopped) {
            return;
        }
        self->_config = config;
        NSMutableSet<NSString *> *enabled = [NSMutableSet set];
        for (TLProject *project in config.projects) {
            if (!project.enabled) {
                continue;
            }
            [enabled addObject:project.projectID];
            // 在途拍摄由完成回调按最新配置重排，避免热载重复排队。
            if (![self->_inflight containsObject:project.projectID]) {
                [self armProject:project];
            }
            [self armEncode:project];
        }
        for (NSString *projectID in [self->_timers.allKeys copy]) {
            if (![enabled containsObject:projectID]) {
                dispatch_source_cancel(self->_timers[projectID]);
                [self->_timers removeObjectForKey:projectID];
            }
        }
        for (NSString *projectID in [self->_encodeTimers.allKeys copy]) {
            if (![enabled containsObject:projectID]) {
                dispatch_source_cancel(self->_encodeTimers[projectID]);
                [self->_encodeTimers removeObjectForKey:projectID];
            }
        }
        [self armMaintenance];
        if (enabled.count == 0) {
            TLLogInfo(@"没有启用的项目。把 config.json 里的 enabled 改为 true 后会自动开始");
        }
    });
}

- (void)stop {
    dispatch_sync(_queue, ^{
        self->_stopped = YES;
        for (dispatch_source_t timer in self->_timers.allValues) {
            dispatch_source_cancel(timer);
        }
        for (dispatch_source_t timer in self->_encodeTimers.allValues) {
            dispatch_source_cancel(timer);
        }
        if (self->_maintenance) {
            dispatch_source_cancel(self->_maintenance);
            self->_maintenance = nil;
        }
        [self->_timers removeAllObjects];
        [self->_encodeTimers removeAllObjects];
    });
}

- (TLProject *)projectWithID:(NSString *)projectID {
    return [_config projectWithID:projectID];
}

- (void)armProject:(TLProject *)project {
    NSDate *lastAttempt = [_state dateForProject:project.projectID key:TLStateLastAttemptAt];
    NSTimeInterval delay = TLNextCaptureDelay(lastAttempt, project.captureInterval, [NSDate date]);
    [self armTimerNamed:project.projectID delay:delay store:_timers handler:^{
        [self fireProjectID:project.projectID];
    }];
}

- (void)armEncode:(TLProject *)project {
    NSDate *slot = nil;
    NSTimeInterval delay = TLNextEncodeDelay([_state dateForProject:project.projectID key:TLStateLastEncodeAt],
                                             [_state dateForProject:project.projectID key:TLStateLastEncodeAttemptAt],
                                             project.encodeEveryDays,
                                             project.encodeAtMinutes,
                                             [NSDate date],
                                             [NSTimeZone localTimeZone],
                                             &slot);
    (void)slot;
    [self armTimerNamed:project.projectID delay:delay store:_encodeTimers handler:^{
        [self fireEncodeID:project.projectID];
    }];
}

- (void)armTimerNamed:(NSString *)name
                delay:(NSTimeInterval)delay
                store:(NSMutableDictionary<NSString *, dispatch_source_t> *)store
              handler:(dispatch_block_t)handler {
    if (_stopped) {
        return;
    }
    dispatch_source_t timer = store[name];
    if (!timer) {
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_event_handler(timer, handler);
        store[name] = timer;
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                                  DISPATCH_TIME_FOREVER,
                                  (uint64_t)(1 * NSEC_PER_SEC));
        dispatch_resume(timer);
        return;
    }
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(1 * NSEC_PER_SEC));
}

- (void)armMaintenance {
    if (_maintenance || _stopped) {
        return;
    }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    __weak TLScheduler *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf fireMaintenance];
    });
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC),
                              60 * NSEC_PER_SEC,
                              5 * NSEC_PER_SEC);
    _maintenance = timer;
    dispatch_resume(timer);
}

- (void)reclaimIfNeeded:(TLConfig *)config {
    double freeGB = TLFreeGigabytes(config.storageRoot);
    if (freeGB < 0 || freeGB >= config.minFreeGB) {
        return;
    }
    NSMutableSet<NSString *> *uploaded = [NSMutableSet set];
    NSMutableArray<NSString *> *projectIDs = [NSMutableArray array];
    for (TLProject *project in config.projects) {
        [projectIDs addObject:project.projectID];
        if ([_state stringForProject:project.projectID key:TLStateLastUploadAt].length > 0) {
            [uploaded addObject:project.projectID];
        }
    }
    NSString *today = TLFormatFileDay([NSDate date], [NSTimeZone localTimeZone]);
    NSInteger removed = TLReclaimUploadedFrames(config.storageRoot, projectIDs, uploaded, today, config.minFreeGB);
    if (removed > 0) {
        TLLogInfo(@"剩余空间不足，已清理已上传项目的 %ld 张原图", (long)removed);
    }
}

- (void)fireMaintenance {
    if (_stopped) {
        return;
    }
    TLConfig *config = _config;
    if (!config) {
        return;
    }
    [self reclaimIfNeeded:config];
    TLUploader *uploader = _uploader;
    dispatch_async(_workQueue, ^{
        if (!uploader) {
            return;
        }
        [uploader drainWithConfig:config];
        [uploader sendHeartbeatIfNeededWithConfig:config];
        TLBatteryReading battery = TLReadBattery();
        if (battery.valid && battery.hasTemperature && battery.celsius > 40.0) {
            [uploader sendAlertForKey:@"heat"
                              message:[NSString stringWithFormat:@"电池温度 %.1f°C，高于 40°C", battery.celsius]
                             cooldown:60 * 60
                               config:config];
        }
        double freeGB = TLFreeGigabytes(config.storageRoot);
        if (freeGB >= 0 && freeGB < config.minFreeGB) {
            [uploader sendAlertForKey:@"storage"
                              message:[NSString stringWithFormat:@"剩余空间 %@，低于 %.1f GB，拍照已暂停", TLFormatGigabytes(freeGB), config.minFreeGB]
                             cooldown:6 * 60 * 60
                               config:config];
        }
    });
}

- (void)fireProjectID:(NSString *)projectID {
    if (_stopped) {
        return;
    }
    TLProject *project = [self projectWithID:projectID];
    if (!project || !project.enabled) {
        return;
    }
    NSDate *lastAttempt = [_state dateForProject:project.projectID key:TLStateLastAttemptAt];
    NSTimeInterval wait = TLNextCaptureDelay(lastAttempt, project.captureInterval, [NSDate date]);
    if (lastAttempt && wait > TLCaptureCatchUpDelay() + 0.5) {
        [self armProject:project];
        return;
    }
    if ([_inflight containsObject:projectID]) {
        return;
    }
    [_inflight addObject:projectID];
    TLConfig *config = _config;
    [self reclaimIfNeeded:config];
    TLState *state = _state;
    TLScheduledCapture capture = _capture;
    dispatch_async(_cameraQueue, ^{
        // 项目可能在等待串行相机时被暂停、删除或替换，开始前复核。
        __block BOOL allowed = NO;
        dispatch_sync(self->_queue, ^{
            allowed = !self->_stopped && config == self->_config && [self projectWithID:projectID].enabled;
            if (!allowed) {
                [self->_inflight removeObject:projectID];
                TLProject *current = [self projectWithID:projectID];
                if (!self->_stopped && current.enabled) {
                    [self armProject:current];
                }
            }
        });
        if (!allowed) {
            return;
        }
        __block BOOL attempted = NO;
        TLCaptureResult *result = capture(project, ^{
            attempted = YES;
            [state updateProject:project.projectID
                          values:@{TLStateLastAttemptAt: TLFormatTimestamp([NSDate date], [NSTimeZone localTimeZone])}
                           error:nil];
        });
        dispatch_async(self->_queue, ^{
            [self finishProject:project result:result config:config attempted:attempted];
        });
    });
}

- (void)fireEncodeID:(NSString *)projectID {
    if (_stopped || !_encoder) {
        return;
    }
    TLProject *project = [self projectWithID:projectID];
    if (!project || !project.enabled) {
        return;
    }
    NSDate *slot = nil;
    NSDate *now = [NSDate date];
    NSTimeInterval delay = TLNextEncodeDelay([_state dateForProject:projectID key:TLStateLastEncodeAt],
                                             [_state dateForProject:projectID key:TLStateLastEncodeAttemptAt],
                                             project.encodeEveryDays,
                                             project.encodeAtMinutes,
                                             now,
                                             [NSTimeZone localTimeZone],
                                             &slot);
    if (!slot || delay > 20) {
        [self armEncode:project];
        return;
    }
    if ([_encodeInflight containsObject:projectID]) {
        return;
    }
    [_encodeInflight addObject:projectID];
    TLConfig *config = _config;
    TLEncoder *encoder = _encoder;
    TLUploader *uploader = _uploader;
    TLState *state = _state;
    dispatch_async(_workQueue, ^{
        TLEncodeResult *result = TLPerformEncodeJob(encoder, uploader, state, config, project, slot, [NSTimeZone localTimeZone]);
        dispatch_async(self->_queue, ^{
            [self->_encodeInflight removeObject:projectID];
            if (self->_stopped) {
                return;
            }
            if (result.succeeded || result.empty) {
                [state updateProject:projectID values:@{
                    TLStateLastEncodeAt: TLFormatTimestamp(slot, [NSTimeZone localTimeZone]),
                    TLStateLastEncodeAttemptAt: TLFormatTimestamp(slot, [NSTimeZone localTimeZone]),
                } error:nil];
            } else {
                [state updateProject:projectID values:@{
                    TLStateLastEncodeAttemptAt: TLFormatTimestamp([NSDate date], [NSTimeZone localTimeZone]),
                } error:nil];
            }
            TLProject *current = [self projectWithID:projectID];
            if (current.enabled) {
                [self armEncode:current];
            }
        });
    });
}

- (void)finishProject:(TLProject *)project result:(TLCaptureResult *)result config:(TLConfig *)config attempted:(BOOL)attempted {
    [_inflight removeObject:project.projectID];
    if (!result) {
        result = [[TLCaptureResult alloc] init];
        result.outcome = TLCaptureOutcomeFailed;
        result.message = @"拍照没有返回结果";
    }
    if (result.outcome == TLCaptureOutcomeSkippedNight) {
        if (![_nightAnnounced containsObject:project.projectID]) {
            TLLogInfo(@"%@：进入夜间跳过", project.projectID);
            [_nightAnnounced addObject:project.projectID];
        }
    } else {
        if ([_nightAnnounced containsObject:project.projectID]) {
            TLLogInfo(@"%@：夜间跳过结束", project.projectID);
            [_nightAnnounced removeObject:project.projectID];
        }
        if (result.outcome == TLCaptureOutcomeSkippedStorage) {
            if (!_lastStorageLog || -[_lastStorageLog timeIntervalSinceNow] > 600) {
                TLLogError(@"%@", result.message);
                _lastStorageLog = [NSDate date];
            }
            if (_uploader) {
                TLConfig *active = config;
                NSString *message = result.message ?: @"剩余空间不足，拍照已暂停";
                dispatch_async(_workQueue, ^{
                    [self->_uploader sendAlertForKey:@"storage" message:message cooldown:6 * 60 * 60 config:active];
                });
            }
        } else if (result.outcome == TLCaptureOutcomeSkippedDark) {
            TLLogInfo(@"%@", result.message);
            [_state recordCaptureResult:result projectID:project.projectID];
        } else if (result.outcome == TLCaptureOutcomeSaved) {
            [_state recordCaptureResult:result projectID:project.projectID];
            TLLogInfo(@"%@", result.message);
        } else {
            NSInteger failures = [_state recordCaptureResult:result projectID:project.projectID];
            TLLogError(@"%@：%@（连续失败 %ld 次）", project.projectID, result.message ?: @"拍照失败", (long)failures);
            if (failures >= 3 && _uploader) {
                NSString *message = [NSString stringWithFormat:@"%@ 连续拍照失败 %ld 次：%@", project.projectID, (long)failures, result.message ?: @"拍照失败"];
                NSString *key = [@"capture-" stringByAppendingString:project.projectID];
                TLConfig *active = config;
                dispatch_async(_workQueue, ^{
                    [self->_uploader sendAlertForKey:key message:message cooldown:60 * 60 config:active];
                });
            }
        }
    }

    if (_stopped) {
        return;
    }
    TLProject *current = [self projectWithID:project.projectID];
    if (!current.enabled) {
        return;
    }
    // 只从本轮真正打开相机的时间补足间隔；夜间/空间跳过没有新尝试时间。
    // 长耗时复用规则的有界追赶延时，不补放历史拍摄。热载使用最新间隔。
    NSDate *lastAttempt = [_state dateForProject:current.projectID key:TLStateLastAttemptAt];
    NSTimeInterval delay = attempted ? TLNextCaptureDelay(lastAttempt, current.captureInterval, [NSDate date]) : current.captureInterval;
    [self armTimerNamed:current.projectID delay:delay store:_timers handler:^{
        [self fireProjectID:current.projectID];
    }];
}

@end
