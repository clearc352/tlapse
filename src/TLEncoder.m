#import "TLEncoder.h"

#import "TLConfig.h"
#import "TLRules.h"
#import "TLSupport.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>

@implementation TLEncoder {
    dispatch_queue_t _queue;
    void *_queueKey;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queueKey = &_queueKey;
        _queue = dispatch_queue_create("com.ddxyl.tlapsed.encode", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, _queueKey, _queueKey, NULL);
    }
    return self;
}

- (void)sync:(dispatch_block_t)block {
    if (dispatch_get_specific(_queueKey) == _queueKey) {
        block();
    } else {
        dispatch_sync(_queue, block);
    }
}

- (TLEncodeResult *)encodeProject:(TLProject *)project
                       storageRoot:(NSString *)storageRoot
                              date:(NSDate *)date
                          timeZone:(NSTimeZone *)timeZone {
    __block TLEncodeResult *result = nil;
    [self sync:^{
        result = [self encodeOnQueue:project storageRoot:storageRoot date:date timeZone:timeZone];
    }];
    return result;
}

static CGImageRef TLOrientedThumbnail(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) {
        return NULL;
    }
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @1920,
        (id)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    return image;
}

static BOOL TLDrawImage(CGImageRef image, CVPixelBufferRef buffer) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    size_t width = CVPixelBufferGetWidth(buffer);
    size_t height = CVPixelBufferGetHeight(buffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(buffer);
    void *base = CVPixelBufferGetBaseAddress(buffer);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(base,
                                                  width,
                                                  height,
                                                  8,
                                                  bytesPerRow,
                                                  colorSpace,
                                                  kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        return NO;
    }
    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGFloat imageWidth = (CGFloat)CGImageGetWidth(image);
    CGFloat imageHeight = (CGFloat)CGImageGetHeight(image);
    CGFloat scale = MIN((CGFloat)width / imageWidth, (CGFloat)height / imageHeight);
    CGFloat drawWidth = imageWidth * scale;
    CGFloat drawHeight = imageHeight * scale;
    CGFloat x = ((CGFloat)width - drawWidth) / 2.0;
    CGFloat y = ((CGFloat)height - drawHeight) / 2.0;
    CGContextDrawImage(context, CGRectMake(x, y, drawWidth, drawHeight), image);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return YES;
}

- (TLEncodeResult *)failed:(NSString *)message {
    TLEncodeResult *result = [[TLEncodeResult alloc] init];
    result.message = message ?: @"合成失败";
    return result;
}

- (TLEncodeResult *)encodeOnQueue:(TLProject *)project
                       storageRoot:(NSString *)storageRoot
                              date:(NSDate *)date
                          timeZone:(NSTimeZone *)timeZone {
    NSDate *when = date ?: [NSDate date];
    NSTimeZone *zone = timeZone ?: [NSTimeZone localTimeZone];
    NSString *day = TLFormatFileDay(when, zone);
    BOOL daily = [project.encodeMode isEqualToString:@"daily"];
    NSArray<NSString *> *frames = TLListFramePaths(storageRoot, project.projectID, daily ? day : nil);
    if (frames.count == 0) {
        TLEncodeResult *result = [self failed:@"没有可合成的照片"];
        result.empty = YES;
        return result;
    }
    NSInteger stride = TLEncodeStride(frames.count, project.fps, project.hasTargetDuration, project.targetDuration);
    NSArray<NSString *> *selected = TLStridedFrames(frames, stride);
    CGImageRef first = TLOrientedThumbnail(selected[0]);
    if (!first) {
        return [self failed:@"第一张照片无法读取"];
    }
    TLPixelSize output = TLEncodeOutputSize(TLPixelSizeMake((NSInteger)CGImageGetWidth(first), (NSInteger)CGImageGetHeight(first)));
    CGImageRelease(first);

    NSString *relative = TLVideoRelativePath(project.projectID, day, project.encodeMode);
    NSString *absolute = [storageRoot stringByAppendingPathComponent:relative];
    NSError *directoryError = nil;
    if (!TLEnsureDirectory(absolute.stringByDeletingLastPathComponent, &directoryError)) {
        return [self failed:directoryError.localizedDescription ?: @"无法创建视频目录"];
    }
    NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tlapse-%@.mp4", [NSUUID UUID].UUIDString]];
    NSURL *url = [NSURL fileURLWithPath:temporary];
    NSError *writerError = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:&writerError];
    if (!writer) {
        return [self failed:writerError.localizedDescription ?: @"无法创建视频文件"];
    }
    NSString *codec = AVVideoCodecTypeH264;
    NSDictionary *settings = @{
        AVVideoCodecKey: codec,
        AVVideoWidthKey: @(output.width),
        AVVideoHeightKey: @(output.height),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(8000000),
            AVVideoExpectedSourceFrameRateKey: @(project.fps),
            AVVideoMaxKeyFrameIntervalKey: @(project.fps),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        },
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    input.expectsMediaDataInRealTime = NO;
    NSDictionary *bufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(output.width),
        (id)kCVPixelBufferHeightKey: @(output.height),
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:bufferAttributes];
    if (![writer canAddInput:input]) {
        return [self failed:@"无法添加视频轨道"];
    }
    [writer addInput:input];
    if (![writer startWriting]) {
        return [self failed:writer.error.localizedDescription ?: @"无法开始写入视频"];
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    dispatch_queue_t appendQueue = dispatch_queue_create("com.ddxyl.tlapsed.encode.append", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block NSInteger cursor = 0;
    __block NSInteger appended = 0;
    __block NSString *appendError = nil;
    __block BOOL ending = NO;
    NSInteger fps = project.fps > 0 ? project.fps : 30;
    [input requestMediaDataWhenReadyOnQueue:appendQueue usingBlock:^{
        if (ending) {
            return;
        }
        while (input.readyForMoreMediaData && !ending) {
            if (cursor >= (NSInteger)selected.count) {
                ending = YES;
                [input markAsFinished];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [writer finishWritingWithCompletionHandler:^{
                        dispatch_semaphore_signal(finished);
                    }];
                });
                return;
            }
            @autoreleasepool {
                NSString *path = selected[(NSUInteger)cursor];
                cursor += 1;
                CGImageRef image = TLOrientedThumbnail(path);
                if (!image) {
                    continue;
                }
                CVPixelBufferRef buffer = NULL;
                NSDictionary *attributes = @{
                    (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
                    (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                };
                CVReturn created = CVPixelBufferCreate(kCFAllocatorDefault,
                                                       (size_t)output.width,
                                                       (size_t)output.height,
                                                       kCVPixelFormatType_32BGRA,
                                                       (__bridge CFDictionaryRef)attributes,
                                                       &buffer);
                BOOL drew = created == kCVReturnSuccess && buffer && TLDrawImage(image, buffer);
                CGImageRelease(image);
                if (!drew || ![adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(appended, (int32_t)fps)]) {
                    if (buffer) {
                        CVPixelBufferRelease(buffer);
                    }
                    appendError = writer.error.localizedDescription ?: @"写入帧失败";
                    ending = YES;
                    [input markAsFinished];
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        [writer finishWritingWithCompletionHandler:^{
                            dispatch_semaphore_signal(finished);
                        }];
                    });
                    return;
                }
                CVPixelBufferRelease(buffer);
                appended += 1;
            }
        }
    }];
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    if (appended == 0 || writer.status != AVAssetWriterStatusCompleted) {
        [[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
        return [self failed:appendError ?: writer.error.localizedDescription ?: @"视频写入失败"];
    }
    [[NSFileManager defaultManager] removeItemAtPath:absolute error:nil];
    NSError *moveError = nil;
    if (![[NSFileManager defaultManager] moveItemAtPath:temporary toPath:absolute error:&moveError]) {
        [[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
        return [self failed:moveError.localizedDescription ?: @"无法保存视频"];
    }
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:absolute error:nil];
    TLEncodeResult *result = [[TLEncodeResult alloc] init];
    result.succeeded = YES;
    result.relativePath = relative;
    result.absolutePath = absolute;
    result.width = output.width;
    result.height = output.height;
    result.frameCount = appended;
    result.sourceCount = (NSInteger)frames.count;
    result.stride = stride;
    result.bytes = [attributes fileSize];
    if (stride > 1) {
        result.message = [NSString stringWithFormat:@"已合成 %ld/%ld 帧，步长 %ld，分辨率 %ld×%ld，视频 %@",
                          (long)appended,
                          (long)frames.count,
                          (long)stride,
                          (long)output.width,
                          (long)output.height,
                          relative];
    } else {
        result.message = [NSString stringWithFormat:@"已合成 %ld 帧，分辨率 %ld×%ld，视频 %@",
                          (long)appended,
                          (long)output.width,
                          (long)output.height,
                          relative];
    }
    return result;
}

@end
