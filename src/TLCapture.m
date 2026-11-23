#import "TLCapture.h"

#import "TLConfig.h"
#import "TLImage.h"
#import "TLLog.h"
#import "TLPhotoRequest.h"
#import "TLRules.h"
#import "TLSupport.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>

static BOOL TLSampleGravity(double *x, double *y, double *z) {
    CMMotionManager *motion = [[CMMotionManager alloc] init];
    if (!motion.isDeviceMotionAvailable) {
        return NO;
    }
    motion.deviceMotionUpdateInterval = 0.05;
    [motion startDeviceMotionUpdates];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.4];
    CMDeviceMotion *sample = nil;
    while ([deadline timeIntervalSinceNow] > 0) {
        sample = motion.deviceMotion;
        if (sample) {
            break;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
    }
    [motion stopDeviceMotionUpdates];
    if (!sample) {
        return NO;
    }
    *x = sample.gravity.x;
    *y = sample.gravity.y;
    *z = sample.gravity.z;
    return YES;
}

static TLCaptureResult *TLResult(TLCaptureOutcome outcome, NSString *message) {
    TLCaptureResult *result = [[TLCaptureResult alloc] init];
    result.outcome = outcome;
    result.message = message;
    result.capturedAt = [NSDate date];
    return result;
}

@interface TLPhotoWaiter : NSObject <AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, strong) NSData *data;
@property (nonatomic, strong) NSError *error;
@property (atomic) BOOL finished;
@property (atomic) BOOL delivered;
@end

@implementation TLPhotoWaiter

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    (void)output;
    NSData *data = nil;
    if (!error) {
        data = [photo fileDataRepresentation];
        if (!data) {
            error = TLError(TLErrorCodeCamera, @"相机没有返回照片数据");
        }
    }
    BOOL accept = NO;
    @synchronized (self) {
        if (!self.finished) {
            self.data = data;
            self.error = error;
            self.finished = YES;
            accept = YES;
        }
        self.delivered = YES;
    }
    if (accept) {
        dispatch_semaphore_signal(self.semaphore);
    }
}

@end

@interface TLCapture ()
@property (atomic) BOOL cancelled;
@property (nonatomic, strong) AVCaptureSession *activeSession;
@property (nonatomic, strong) NSMutableArray<TLPhotoWaiter *> *pendingWaiters;
@end

@implementation TLCapture

- (instancetype)init {
    self = [super init];
    if (self) {
        _pendingWaiters = [NSMutableArray array];
    }
    return self;
}

- (void)cancel {
    self.cancelled = YES;
}

// A timed-out waiter stays until its own callback sets delivered, so that photo cannot satisfy the next attempt.
- (void)retireDeliveredWaiters {
    @synchronized (self) {
        NSIndexSet *delivered = [self.pendingWaiters indexesOfObjectsPassingTest:^BOOL(TLPhotoWaiter *waiter, NSUInteger index, BOOL *stop) {
            (void)index;
            (void)stop;
            return waiter.delivered;
        }];
        [self.pendingWaiters removeObjectsAtIndexes:delivered];
    }
}

- (TLCaptureResult *)captureProject:(TLProject *)project
                         storageRoot:(NSString *)storageRoot
                           minFreeGB:(double)minFreeGB
                              manual:(BOOL)manual
                     willOpenCamera:(void (^)(void))willOpenCamera {
    if ([NSThread isMainThread]) {
        return TLResult(TLCaptureOutcomeFailed, @"拍照不能在主线程执行");
    }
    if (self.cancelled) {
        return TLResult(TLCaptureOutcomeFailed, @"拍照已取消");
    }
    NSDate *now = [NSDate date];
    NSTimeZone *timeZone = [NSTimeZone localTimeZone];
    if (!manual && [project.nightSkip skipsTimeAtDate:now timeZone:timeZone]) {
        return TLResult(TLCaptureOutcomeSkippedNight, [NSString stringWithFormat:@"%@：夜间跳过", project.projectID]);
    }
    double freeGB = TLFreeGigabytes(storageRoot);
    if (freeGB >= 0 && freeGB < minFreeGB) {
        return TLResult(TLCaptureOutcomeSkippedStorage,
                        [NSString stringWithFormat:@"剩余空间 %@，低于 %.1f GB，已暂停拍照", TLFormatGigabytes(freeGB), minFreeGB]);
    }

    double gravityX = 0;
    double gravityY = 0;
    double gravityZ = 0;
    BOOL haveGravity = TLSampleGravity(&gravityX, &gravityY, &gravityZ);
    BOOL flat = NO;
    int gravityExif = haveGravity ? TLExifForGravity(gravityX, gravityY, gravityZ, &flat) : 0;
    if (willOpenCamera) {
        willOpenCamera();
    }

    NSError *lastError = nil;
    NSData *jpeg = nil;
    for (NSInteger attempt = 1; attempt <= 2; attempt++) {
        @autoreleasepool {
            jpeg = [self takeJPEGForProject:project storageRoot:storageRoot error:&lastError];
        }
        if (jpeg || self.cancelled) {
            break;
        }
        TLLogError(@"%@：第 %ld 次拍照失败：%@", project.projectID, (long)attempt, lastError.localizedDescription ?: @"未知错误");
        if (attempt == 1) {
            [NSThread sleepForTimeInterval:0.4];
        }
    }
    if (!jpeg) {
        return TLResult(TLCaptureOutcomeFailed, lastError.localizedDescription ?: @"拍照失败");
    }

    int overrideExif = 0;
    if (project.orientationMode == TLOrientationModeAuto) {
        int sourceExif = TLJPEGExifOrientation(jpeg);
        if (sourceExif == 1 && gravityExif > 1) {
            overrideExif = gravityExif;
        }
        if (flat && overrideExif == 6) {
            TLLogInfo(@"%@：手机接近平放，按竖屏处理。固定机位可把 capture.orientation 设为 portrait 或 landscapeHomeRight", project.projectID);
        }
    } else if (project.orientationMode != TLOrientationModeRaw) {
        overrideExif = TLExifForOrientationMode(project.orientationMode);
    }

    NSError *encodeError = nil;
    TLEncodedImage *encoded = TLEncodeJPEG(jpeg, project.resolution, project.jpegQuality, overrideExif, &encodeError);
    if (!encoded) {
        return TLResult(TLCaptureOutcomeFailed, encodeError.localizedDescription ?: @"无法处理照片");
    }
    TLLogInfo(@"%@：方向 原始=%d 应用=%d 重力=%d 尺寸=%ldx%ld",
              project.projectID,
              encoded.sourceExif,
              encoded.appliedExif,
              gravityExif,
              (long)encoded.width,
              (long)encoded.height);

    TLCaptureResult *result = [[TLCaptureResult alloc] init];
    result.capturedAt = now;
    result.width = encoded.width;
    result.height = encoded.height;
    result.bytes = encoded.jpeg.length;
    result.averageLuma = encoded.averageLuma;
    result.sourceExif = encoded.sourceExif;
    result.appliedExif = encoded.appliedExif;
    if (!manual && project.nightSkip.enabled && project.nightSkip.brightness > 0 && encoded.averageLuma < project.nightSkip.brightness) {
        result.outcome = TLCaptureOutcomeSkippedDark;
        result.message = [NSString stringWithFormat:@"%@：画面亮度过低（%.2f < %.2f），已丢弃",
                          project.projectID,
                          encoded.averageLuma,
                          project.nightSkip.brightness];
        return result;
    }

    NSString *relative = TLFrameRelativePath(project.projectID, now, timeZone, NO);
    NSString *absolute = TLUniqueFilePath([storageRoot stringByAppendingPathComponent:relative]);
    NSError *writeError = nil;
    if (!TLWriteDataAtomic(encoded.jpeg, absolute, &writeError)) {
        result.outcome = TLCaptureOutcomeFailed;
        result.message = [NSString stringWithFormat:@"无法保存照片：%@", writeError.localizedDescription ?: absolute];
        return result;
    }
    if (encoded.thumbnail) {
        NSString *thumbRelative = [relative stringByReplacingOccurrencesOfString:@"/frames/" withString:@"/thumbs/"];
        NSString *thumbAbsolute = [[storageRoot stringByAppendingPathComponent:thumbRelative.stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:absolute.lastPathComponent];
        TLWriteDataAtomic(encoded.thumbnail, thumbAbsolute, nil);
    }
    NSString *storedRelative = absolute;
    NSString *rootPrefix = [storageRoot hasSuffix:@"/"] ? storageRoot : [storageRoot stringByAppendingString:@"/"];
    if ([storedRelative hasPrefix:rootPrefix]) {
        storedRelative = [storedRelative substringFromIndex:rootPrefix.length];
    }
    result.outcome = TLCaptureOutcomeSaved;
    result.relativePath = storedRelative;
    result.absolutePath = absolute;
    result.message = [NSString stringWithFormat:@"已保存 %@（%ldx%ld，%@，亮度 %.2f）",
                      absolute,
                      (long)encoded.width,
                      (long)encoded.height,
                      TLFormatBytes(encoded.jpeg.length),
                      encoded.averageLuma];
    return result;
}

- (NSData *)takeJPEGForProject:(TLProject *)project storageRoot:(NSString *)storageRoot error:(NSError **)error {
    [self retireDeliveredWaiters];
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusNotDetermined) {
        __block BOOL granted = NO;
        dispatch_semaphore_t permission = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL grantedAccess) {
            granted = grantedAccess;
            dispatch_semaphore_signal(permission);
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (dispatch_semaphore_wait(permission, DISPATCH_TIME_NOW) != 0) {
            if ([deadline timeIntervalSinceNow] <= 0) {
                break;
            }
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        }
        status = granted ? AVAuthorizationStatusAuthorized : [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    }
    if (status != AVAuthorizationStatusAuthorized) {
        if (error) {
            *error = TLError(TLErrorCodeCamera, @"没有摄像头权限。请用 mobile 用户运行，并确认安装包写入了摄像头 entitlements");
        }
        return nil;
    }

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                  mediaType:AVMediaTypeVideo
                                                                   position:AVCaptureDevicePositionBack];
    if (!device) {
        if (error) {
            *error = TLError(TLErrorCodeCamera, @"找不到后置摄像头");
        }
        return nil;
    }

    NSString *lockPath = [storageRoot stringByAppendingPathComponent:@"camera.lock"];
    // ARC may otherwise release the lock as soon as lockWithTimeout returns.
    __attribute__((objc_precise_lifetime)) TLFileLock *cameraLock = [[TLFileLock alloc] initWithPath:lockPath];
    NSError *lockError = nil;
    if (![cameraLock lockWithTimeout:20 error:&lockError]) {
        if (error) {
            *error = lockError ?: TLError(TLErrorCodeBusy, @"摄像头正被占用");
        }
        return nil;
    }

    NSError *inputError = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&inputError];
    if (!input) {
        if (error) {
            *error = TLError(TLErrorCodeCamera, inputError.localizedDescription ?: @"无法打开后置摄像头");
        }
        return nil;
    }
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
#if TARGET_OS_IPHONE
    session.usesApplicationAudioSession = NO;
    session.automaticallyConfiguresApplicationAudioSession = NO;
#endif
    AVCapturePhotoOutput *output = [[AVCapturePhotoOutput alloc] init];
    if (![session canAddInput:input] || ![session canAddOutput:output]) {
        if (error) {
            *error = TLError(TLErrorCodeCamera, @"无法配置拍照会话");
        }
        return nil;
    }
    [session beginConfiguration];
    if ([session canSetSessionPreset:AVCaptureSessionPresetPhoto]) {
        session.sessionPreset = AVCaptureSessionPresetPhoto;
    }
    [session addInput:input];
    [session addOutput:output];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if ([output respondsToSelector:@selector(setHighResolutionCaptureEnabled:)]) {
        output.highResolutionCaptureEnabled = YES;
    }
#pragma clang diagnostic pop
    [session commitConfiguration];
    TLLogInfo(@"%@：打开摄像头", project.projectID);
    self.activeSession = session;
    __block NSString *runtimeDetail = nil;
    id runtimeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVCaptureSessionRuntimeErrorNotification
                    object:session
                     queue:nil
                usingBlock:^(NSNotification *note) {
        NSError *runtimeError = note.userInfo[AVCaptureSessionErrorKey];
        if (![runtimeError isKindOfClass:[NSError class]]) {
            return;
        }
        runtimeDetail = [NSString stringWithFormat:@"%@（%@ %ld）",
            runtimeError.localizedDescription ?: @"未知错误",
            runtimeError.domain ?: @"",
            (long)runtimeError.code];
    }];
    __block NSString *interruptDetail = nil;
    id interruptObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVCaptureSessionWasInterruptedNotification
                    object:session
                     queue:nil
                usingBlock:^(NSNotification *note) {
        NSNumber *reason = note.userInfo[AVCaptureSessionInterruptionReasonKey];
        if (reason.integerValue == 1) {
            interruptDetail = @"系统把这个进程当成后台，拒绝使用摄像头";
        } else {
            interruptDetail = [NSString stringWithFormat:@"打断原因 %@", reason ?: @"未知"];
        }
    }];
    @try {
        [session startRunning];
    } @catch (NSException *exception) {
        [[NSNotificationCenter defaultCenter] removeObserver:runtimeObserver];
        [[NSNotificationCenter defaultCenter] removeObserver:interruptObserver];
        self.activeSession = nil;
        if (error) {
            *error = TLError(TLErrorCodeCamera, exception.reason ?: @"摄像头会话启动失败");
        }
        return nil;
    }
    if (!session.isRunning && runtimeDetail.length == 0 && interruptDetail.length == 0) {
        [NSThread sleepForTimeInterval:0.3];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:runtimeObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:interruptObserver];
    if (self.cancelled || !session.isRunning) {
        [session stopRunning];
        self.activeSession = nil;
        if (error) {
            NSString *reason = @"摄像头会话没有启动";
            if (self.cancelled) {
                reason = @"拍照已取消";
            } else if (runtimeDetail.length > 0) {
                reason = [NSString stringWithFormat:@"摄像头会话没有启动：%@", runtimeDetail];
            } else if (interruptDetail.length > 0) {
                reason = [NSString stringWithFormat:@"摄像头会话没有启动：%@", interruptDetail];
            } else if (session.interrupted) {
                reason = @"摄像头会话没有启动：会话处于打断状态";
            }
            *error = TLError(TLErrorCodeCamera, reason);
        }
        return nil;
    }
    if (![self configureDevice:device project:project lockFinal:NO error:error]) {
        [session stopRunning];
        self.activeSession = nil;
        return nil;
    }

    NSDate *settleStart = [NSDate date];
    NSTimeInterval minimum = project.settleSeconds;
    NSTimeInterval limit = minimum + 2.0;
    while (YES) {
        if (self.cancelled) {
            [session stopRunning];
            self.activeSession = nil;
            if (error) {
                *error = TLError(TLErrorCodeCamera, @"拍照已取消");
            }
            return nil;
        }
        NSTimeInterval elapsed = -[settleStart timeIntervalSinceNow];
        BOOL busy = device.isAdjustingFocus || device.isAdjustingExposure || device.isAdjustingWhiteBalance;
        if (elapsed >= minimum && !busy) {
            break;
        }
        if (elapsed >= limit) {
            TLLogInfo(@"%@：对焦等待达到 %.1f 秒，继续拍照", project.projectID, elapsed);
            break;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    }
    if (![self configureDevice:device project:project lockFinal:YES error:error]) {
        [session stopRunning];
        self.activeSession = nil;
        return nil;
    }

    TLPhotoWaiter *waiter = [[TLPhotoWaiter alloc] init];
    waiter.semaphore = dispatch_semaphore_create(0);
    @synchronized (self) {
        [self.pendingWaiters addObject:waiter];
    }
    TLLogInfo(@"%@：正在拍照", project.projectID);
    BOOL submitted = TLSubmitPhotoRequest(project.shutterSound, project.projectID, ^id {
        AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey: AVVideoCodecTypeJPEG}];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (output.isHighResolutionCaptureEnabled) {
            settings.highResolutionPhotoEnabled = YES;
        }
#pragma clang diagnostic pop
        return settings;
    }, ^(__unsafe_unretained id settings) {
        [output capturePhotoWithSettings:settings delegate:waiter];
    }, error);
    if (!submitted) {
        @synchronized (waiter) {
            waiter.finished = YES;
            waiter.delivered = YES;
        }
        [session stopRunning];
        self.activeSession = nil;
        return nil;
    }

    NSDate *captureDeadline = [NSDate dateWithTimeIntervalSinceNow:8];
    BOOL timedOut = NO;
    while (dispatch_semaphore_wait(waiter.semaphore, DISPATCH_TIME_NOW) != 0) {
        if (self.cancelled || [captureDeadline timeIntervalSinceNow] <= 0) {
            timedOut = YES;
            break;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    }
    [session stopRunning];
    self.activeSession = nil;
    TLLogInfo(@"%@：已关闭摄像头", project.projectID);
    if (timedOut) {
        @synchronized (waiter) {
            waiter.finished = YES;
        }
        if (error) {
            *error = TLError(TLErrorCodeCamera, self.cancelled ? @"拍照已取消" : @"拍照超时");
        }
        return nil;
    }

    NSData *data = nil;
    NSError *photoError = nil;
    @synchronized (waiter) {
        data = waiter.data;
        photoError = waiter.error;
    }
    if (!data) {
        if (error) {
            *error = photoError ?: TLError(TLErrorCodeCamera, @"相机没有返回照片数据");
        }
        return nil;
    }
    return data;
}

- (BOOL)configureDevice:(AVCaptureDevice *)device project:(TLProject *)project lockFinal:(BOOL)lockFinal error:(NSError **)error {
    NSError *lockError = nil;
    if (![device lockForConfiguration:&lockError]) {
        if (error) {
            *error = TLError(TLErrorCodeCamera, lockError.localizedDescription ?: @"无法配置摄像头");
        }
        return NO;
    }
    if (!lockFinal) {
        if (device.isFocusPointOfInterestSupported) {
            device.focusPointOfInterest = CGPointMake(0.5, 0.5);
        }
        if (device.isExposurePointOfInterestSupported) {
            device.exposurePointOfInterest = CGPointMake(0.5, 0.5);
        }
        if (project.lockFocus && [device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
        }
        if (project.lockExposure && [device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
            device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
        }
        if (project.lockWhiteBalance && [device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) {
            device.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
        }
        @try {
            device.subjectAreaChangeMonitoringEnabled = YES;
        } @catch (NSException *exception) {
            (void)exception;
        }
    } else {
        if (project.lockFocus && [device isFocusModeSupported:AVCaptureFocusModeLocked]) {
            device.focusMode = AVCaptureFocusModeLocked;
        }
        if (project.lockExposure && [device isExposureModeSupported:AVCaptureExposureModeLocked]) {
            device.exposureMode = AVCaptureExposureModeLocked;
        }
        if (project.lockWhiteBalance && [device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeLocked]) {
            device.whiteBalanceMode = AVCaptureWhiteBalanceModeLocked;
        }
    }
    [device unlockForConfiguration];
    return YES;
}

@end
