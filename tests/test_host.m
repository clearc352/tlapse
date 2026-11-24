#import "TLCapture.h"
#import "TLConfig.h"
#import "TLEncode.h"
#import "TLEncoder.h"
#import "TLImage.h"
#import "TLPhotoRequest.h"
#import "TLRules.h"
#import "TLState.h"
#import "TLSupport.h"
#import "TLUploader.h"
#import "TLVersion.h"
#import "TLWeb.h"
#import "../app/TLClient.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <math.h>

#import <arpa/inet.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>
#import <fcntl.h>

static int gFailures = 0;
static int gPasses = 0;

#define EXPECT(condition, message) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, message); \
            gFailures += 1; \
        } else { \
            gPasses += 1; \
        } \
    } while (0)

static NSDate *TLDate(NSInteger year, NSInteger month, NSInteger day, NSInteger hour, NSInteger minute, NSInteger second, NSTimeZone *timeZone) {
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = timeZone;
    NSDateComponents *parts = [[NSDateComponents alloc] init];
    parts.year = year;
    parts.month = month;
    parts.day = day;
    parts.hour = hour;
    parts.minute = minute;
    parts.second = second;
    return [calendar dateFromComponents:parts];
}

static CGImageRef TLSolidImage(size_t width, size_t height, unsigned char red, unsigned char green, unsigned char blue) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    CGContextSetRGBFillColor(context, red / 255.0, green / 255.0, blue / 255.0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

static NSData *TLJPEGWithOrientation(CGImageRef image, int orientation) {
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
    NSDictionary *properties = @{
        (id)kCGImagePropertyOrientation: @(orientation),
        (id)kCGImageDestinationLossyCompressionQuality: @1.0,
    };
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    BOOL ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return ok ? data : nil;
}

static void TLTestRules(void) {
    EXPECT(TLSanitizeProjectID(@"mungbean") != nil, "mungbean");
    EXPECT(TLSanitizeProjectID(@"A1_b-c") != nil, "mixed id");
    EXPECT(TLSanitizeProjectID(@"../etc") == nil, "reject traversal");
    EXPECT(TLSanitizeProjectID(@"a/b") == nil, "reject slash");
    EXPECT(TLSanitizeProjectID(@"") == nil, "reject empty");
    EXPECT(TLSanitizeProjectID(@"-abc") == nil, "reject leading dash");

    BOOL full = NO;
    TLPixelSize box = TLPixelSizeMake(0, 0);
    EXPECT(TLParseResolution(@"1920x1440", &box, &full) && !full && box.width == 1920 && box.height == 1440, "parse 1920");
    EXPECT(TLParseResolution(@"FULL", &box, &full) && full, "parse full");
    EXPECT(!TLParseResolution(@"1920", &box, &full), "reject bare number");

    TLPixelSize landscape = TLOutputSize(TLPixelSizeMake(3264, 2448), @"1920x1440");
    EXPECT(landscape.width == 1920 && landscape.height == 1440, "landscape fit");
    TLPixelSize portrait = TLOutputSize(TLPixelSizeMake(2448, 3264), @"1920x1440");
    EXPECT(portrait.width == 1440 && portrait.height == 1920, "portrait fit");
    TLPixelSize original = TLOutputSize(TLPixelSizeMake(3264, 2448), @"full");
    EXPECT(original.width == 3264 && original.height == 2448, "full size");
    TLPixelSize small = TLOutputSize(TLPixelSizeMake(100, 100), @"1920x1440");
    EXPECT(small.width == 100 && small.height == 100, "do not upscale");
    TLPixelSize square = TLOutputSize(TLPixelSizeMake(2000, 2000), @"1920x1440");
    EXPECT(square.width == 1440 && square.height == 1440, "square fits short edge");
    TLPixelSize odd = TLOutputSize(TLPixelSizeMake(11, 7), @"full");
    EXPECT(odd.width == 10 && odd.height == 6, "even dimensions");

    BOOL ok = NO;
    EXPECT(TLParseHHMM(@"23:30", &ok) == 23 * 60 + 30 && ok, "23:30");
    EXPECT(TLParseHHMM(@"9:05", &ok) == 9 * 60 + 5 && ok, "9:05");
    TLParseHHMM(@"24:00", &ok);
    EXPECT(!ok, "reject 24:00");
    TLParseHHMM(@"23:60", &ok);
    EXPECT(!ok, "reject 23:60");

    EXPECT(TLMinutesInWindow(22 * 60, 22 * 60, 6 * 60), "window start inclusive");
    EXPECT(TLMinutesInWindow(23 * 60 + 59, 22 * 60, 6 * 60), "late night");
    EXPECT(TLMinutesInWindow(0, 22 * 60, 6 * 60), "midnight");
    EXPECT(TLMinutesInWindow(5 * 60 + 59, 22 * 60, 6 * 60), "before end");
    EXPECT(!TLMinutesInWindow(6 * 60, 22 * 60, 6 * 60), "end exclusive");
    EXPECT(!TLMinutesInWindow(12 * 60, 22 * 60, 6 * 60), "noon");
    EXPECT(TLMinutesInWindow(9 * 60, 9 * 60, 17 * 60), "day window start");
    EXPECT(!TLMinutesInWindow(17 * 60, 9 * 60, 17 * 60), "day window end");
    EXPECT(!TLMinutesInWindow(12 * 60, 8 * 60, 8 * 60), "equal endpoints do not skip");

    BOOL flat = YES;
    EXPECT(TLExifForGravity(0, -1, 0, &flat) == 6 && !flat, "portrait gravity");
    EXPECT(TLExifForGravity(0, 1, 0, &flat) == 8 && !flat, "upside down");
    EXPECT(TLExifForGravity(1, 0, 0, &flat) == 1 && !flat, "home right");
    EXPECT(TLExifForGravity(-1, 0, 0, &flat) == 3 && !flat, "home left");
    EXPECT(TLExifForGravity(0, 0, -1, &flat) == 6 && flat, "flat");
    EXPECT(TLExifForGravity(0, 0, 0, &flat) == 0 && !flat, "unknown gravity");
    EXPECT(TLExifForOrientationMode(TLOrientationModePortrait) == 6, "portrait exif");
    EXPECT(TLExifForOrientationMode(TLOrientationModeLandscapeHomeLeft) == 3, "home left exif");
    TLOrientationMode mode = TLOrientationModeFromString(@"landscapeHomeRight", &ok);
    EXPECT(ok && mode == TLOrientationModeLandscapeHomeRight, "orientation name");
    TLOrientationModeFromString(@"sideways", &ok);
    EXPECT(!ok, "unknown orientation");

    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000000];
    EXPECT(fabs(TLNextCaptureDelay(nil, 300, now) - 5) < 0.001, "initial delay");
    EXPECT(fabs(TLNextCaptureDelay([now dateByAddingTimeInterval:-100], 300, now) - 200) < 0.001, "remaining delay");
    EXPECT(fabs(TLNextCaptureDelay([now dateByAddingTimeInterval:-400], 300, now) - 2) < 0.001, "overdue catch-up");
    EXPECT(TLNextCaptureDelay(now, 300, now) > 290, "just attempted waits a full interval");

    NSTimeZone *utc = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDate *stamp = TLDate(2026, 11, 11, 10, 30, 0, utc);
    EXPECT(TLMinutesSinceMidnight(stamp, utc) == 10 * 60 + 30, "minutes since midnight");
    EXPECT([TLFrameRelativePath(@"mungbean", stamp, utc, NO) isEqualToString:@"projects/mungbean/frames/20261111/103000.jpg"], "frame path");
    EXPECT([TLFrameRelativePath(@"mungbean", stamp, utc, YES) isEqualToString:@"projects/mungbean/thumbs/20261111/103000.jpg"], "thumb path");
    NSString *text = TLFormatTimestamp(stamp, utc);
    NSDate *parsed = TLParseTimestamp(text);
    EXPECT(parsed && fabs([parsed timeIntervalSinceDate:stamp]) < 1, "timestamp roundtrip");
    EXPECT([TLFormatBytes(500) isEqualToString:@"500 B"], "bytes");
    EXPECT([TLFormatBytes(2048) isEqualToString:@"2.0 KB"], "kilobytes");

    EXPECT(TLStorageRootAllowed(@"/var/mobile/Timelapse"), "storage root");
    EXPECT(!TLStorageRootAllowed(@"/var/mobile"), "reject mobile itself");
    EXPECT(!TLStorageRootAllowed(@"/tmp/timelapse"), "reject outside mobile");
    EXPECT(TLFreeGigabytes(@"/tmp") > 0, "free space");
}

static void TLTestConfig(void) {
    NSString *here = [NSString stringWithUTF8String:__FILE__];
    NSString *root = here.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSString *example = [root stringByAppendingPathComponent:@"layout/var/mobile/Timelapse/config.example.json"];
    NSError *error = nil;
    TLConfig *config = [TLConfig configWithContentsOfFile:example error:&error];
    EXPECT(config != nil, error.localizedDescription.UTF8String ?: "example config");
    EXPECT(config.projects.count == 2, "two projects");
    EXPECT(!config.projects[0].enabled && !config.projects[1].enabled, "installed projects stay paused");
    EXPECT(config.projects[0].captureInterval == 300, "mungbean interval");
    EXPECT(config.projects[1].captureInterval == 30, "ants interval");
    EXPECT([config.projects[0].encodeMode isEqualToString:@"cumulative"], "cumulative");
    EXPECT(config.projects[0].encodeAtMinutes == 23 * 60 + 30, "encode at 23:30");
    EXPECT(config.projects[1].encodeAtMinutes == 10, "encode at 00:10");
    EXPECT(config.projects[0].keepFramesDays == 14, "keep days");
    EXPECT(!config.telegramEnabled && !config.webdavEnabled, "uploads off");
    EXPECT([config.storageRoot hasSuffix:@"/mobile/Timelapse"], "storage suffix");
    EXPECT(config.minFreeGB == 5, "min free");
    EXPECT(config.enabledProjectCount == 0, "none enabled");
    TLConfig *roundTrip = [TLConfig configWithDictionary:[config dictionaryRepresentation] error:&error];
    EXPECT(roundTrip != nil, error.localizedDescription.UTF8String ?: "round trip");
    EXPECT(roundTrip.projects[0].captureInterval == 300, "round trip interval");
    EXPECT(roundTrip.projects[0].shutterSound && roundTrip.projects[1].shutterSound, "example shutter stays on");
    EXPECT(roundTrip.projects[0].hasTargetDuration && roundTrip.projects[0].targetDuration == 30, "round trip duration");
    EXPECT(!roundTrip.projects[1].hasTargetDuration, "ants duration omitted");
    EXPECT(!roundTrip.projects[0].nightSkip.enabled, "night stays off");
    EXPECT([roundTrip.serverToken isEqualToString:config.serverToken], "token kept");

    NSDictionary *night = @{
        @"server": @{@"port": @8080, @"token": @"t"},
        @"storage": @{@"root": @"/var/mobile/Timelapse", @"minFreeGB": @1},
        @"projects": @[
            @{
                @"id": @"plant",
                @"name": @"豆苗",
                @"enabled": @YES,
                @"capture": @{
                    @"interval": @60,
                    @"nightSkip": @{@"from": @"22:00", @"to": @"06:00", @"brightness": @0.08}
                }
            }
        ]
    };
    TLConfig *nightConfig = [TLConfig configWithDictionary:night error:&error];
    EXPECT(nightConfig != nil, error.localizedDescription.UTF8String ?: "night config");
    TLNightSkip *skip = nightConfig.projects[0].nightSkip;
    EXPECT(skip.enabled && skip.hasTimeWindow && fabs(skip.brightness - 0.08) < 0.0001, "night object");
    NSTimeZone *utc = [NSTimeZone timeZoneForSecondsFromGMT:0];
    EXPECT([skip skipsTimeAtDate:TLDate(2026, 11, 11, 23, 0, 0, utc) timeZone:utc], "23:00 skipped");
    EXPECT(![skip skipsTimeAtDate:TLDate(2026, 11, 11, 12, 0, 0, utc) timeZone:utc], "noon kept");

    NSMutableDictionary *tooFast = [night mutableCopy];
    NSMutableDictionary *project = [tooFast[@"projects"][0] mutableCopy];
    NSMutableDictionary *capture = [project[@"capture"] mutableCopy];
    capture[@"interval"] = @1;
    project[@"capture"] = capture;
    tooFast[@"projects"] = @[project];
    NSError *fastError = nil;
    EXPECT([TLConfig configWithDictionary:tooFast error:&fastError] == nil, "reject 1 second");
    EXPECT([fastError.localizedDescription containsString:@"interval"], "interval message");

    NSMutableDictionary *duplicate = [night mutableCopy];
    duplicate[@"projects"] = @[night[@"projects"][0], night[@"projects"][0]];
    NSError *duplicateError = nil;
    EXPECT([TLConfig configWithDictionary:duplicate error:&duplicateError] == nil, "duplicate id");

    NSMutableDictionary *unknown = [night mutableCopy];
    unknown[@"extra"] = @YES;
    NSError *unknownError = nil;
    EXPECT([TLConfig configWithDictionary:unknown error:&unknownError] == nil, "unknown key");
    NSError *shutterError = nil;
    TLConfig *muted = [TLConfig configWithDictionary:@{
        @"storage": @{@"root": @"/var/mobile/Timelapse"},
        @"projects": @[@{@"id": @"quiet", @"name": @"安静", @"capture": @{@"shutterSound": @NO}}],
    } error:&shutterError];
    NSDictionary *mutedCapture = [muted.projects.firstObject dictionaryRepresentation][@"capture"];
    EXPECT(muted != nil && !muted.projects.firstObject.shutterSound, shutterError.localizedDescription.UTF8String ?: "shutter can be off");
    EXPECT([mutedCapture[@"shutterSound"] isEqual:@NO], "shutter round trip");
    TLConfig *legacy = [TLConfig configWithDictionary:@{
        @"storage": @{@"root": @"/var/mobile/Timelapse"},
        @"projects": @[@{@"id": @"old", @"name": @"旧项目"}],
    } error:&shutterError];
    EXPECT(legacy.projects.firstObject.shutterSound, "missing shutter stays on");
}

static void TLTestStateAndFiles(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSError *error = nil;
    EXPECT(TLEnsureDirectory(directory, &error), "temp directory");
    NSString *first = [directory stringByAppendingPathComponent:@"a.jpg"];
    EXPECT(TLWriteDataAtomic([@"one" dataUsingEncoding:NSUTF8StringEncoding], first, &error), "write first");
    NSString *unique = TLUniqueFilePath(first);
    EXPECT([unique.lastPathComponent isEqualToString:@"a_2.jpg"], "unique suffix");

    NSString *statePath = [directory stringByAppendingPathComponent:@"state.json"];
    TLState *state = [[TLState alloc] initWithPath:statePath];
    NSDate *when = [NSDate dateWithTimeIntervalSince1970:1700000000];
    EXPECT(([state updateProject:@"mungbean" values:@{
        TLStateFrameCount: @3,
        TLStateLastCaptureAt: TLFormatTimestamp(when, [NSTimeZone localTimeZone]),
        TLStateLastFile: @"projects/mungbean/frames/20261111/103000.jpg"
    } error:&error]), "write state");
    EXPECT(([state updateDaemon:@{@"pid": @42, @"version": @"0.1.0"} error:&error]), "write daemon");
    TLState *reloaded = [[TLState alloc] initWithPath:statePath];
    EXPECT([reloaded integerForProject:@"mungbean" key:TLStateFrameCount] == 3, "frame count");
    EXPECT([reloaded stringForProject:@"mungbean" key:TLStateLastFile].length > 0, "last file");
    NSDate *readBack = [reloaded dateForProject:@"mungbean" key:TLStateLastCaptureAt];
    EXPECT(readBack && fabs([readBack timeIntervalSinceDate:when]) < 1, "state date");
    NSDictionary *daemon = reloaded.snapshot[@"daemon"];
    EXPECT([daemon[@"pid"] integerValue] == 42, "daemon pid preserved");

    EXPECT(TLWriteDataAtomic([@"{" dataUsingEncoding:NSUTF8StringEncoding], statePath, &error), "corrupt state");
    TLState *recovered = [[TLState alloc] initWithPath:statePath];
    EXPECT(recovered.snapshot.count == 0, "corrupt state recovers");
    EXPECT([recovered updateProject:@"mungbean" values:@{TLStateFrameCount: @1} error:&error], "write after recover");
    EXPECT([recovered integerForProject:@"mungbean" key:TLStateFrameCount] == 1, "count after recover");

    TLCaptureResult *saved = [[TLCaptureResult alloc] init];
    saved.outcome = TLCaptureOutcomeSaved;
    saved.relativePath = @"projects/mungbean/frames/20261111/103001.jpg";
    saved.capturedAt = when;
    EXPECT([recovered recordCaptureResult:saved projectID:@"mungbean"] == 0, "record success");
    EXPECT([recovered integerForProject:@"mungbean" key:TLStateFrameCount] == 2, "increment frame");
    EXPECT([recovered integerForProject:@"mungbean" key:TLStateConsecutiveFailures] == 0, "clear failures");

    TLCaptureResult *failed = [[TLCaptureResult alloc] init];
    failed.outcome = TLCaptureOutcomeFailed;
    failed.message = @"摄像头超时";
    EXPECT([recovered recordCaptureResult:failed projectID:@"mungbean"] == 1, "first failure");
    EXPECT([recovered recordCaptureResult:failed projectID:@"mungbean"] == 2, "second failure");
    EXPECT([[recovered stringForProject:@"mungbean" key:TLStateLastError] isEqualToString:@"摄像头超时"], "last error");
}

static void TLTestImages(void) {
    CGImageRef wide = TLSolidImage(320, 240, 255, 255, 255);
    NSData *jpeg = TLJPEGWithOrientation(wide, 1);
    CGImageRelease(wide);
    EXPECT(TLJPEGExifOrientation(jpeg) == 1, "exif 1");
    NSError *error = nil;
    TLEncodedImage *scaled = TLEncodeJPEG(jpeg, @"160x120", 0.85, 0, &error);
    EXPECT(scaled != nil, error.localizedDescription.UTF8String ?: "encode");
    EXPECT(scaled.width == 160 && scaled.height == 120, "downscale 4:3");
    EXPECT(scaled.averageLuma > 0.9, "white luma");

    CGImageRef blackImage = TLSolidImage(32, 24, 0, 0, 0);
    NSData *blackJPEG = TLJPEGWithOrientation(blackImage, 1);
    CGImageRelease(blackImage);
    TLEncodedImage *black = TLEncodeJPEG(blackJPEG, @"full", 0.85, 0, &error);
    EXPECT(black.averageLuma < 0.05, "black luma");

    CGImageRef landscape = TLSolidImage(40, 20, 10, 180, 10);
    NSData *turned = TLJPEGWithOrientation(landscape, 6);
    CGImageRelease(landscape);
    EXPECT(TLJPEGExifOrientation(turned) == 6, "stored exif 6");
    TLEncodedImage *rotated = TLEncodeJPEG(turned, @"full", 0.9, 0, &error);
    EXPECT(rotated != nil, error.localizedDescription.UTF8String ?: "rotate");
    EXPECT(rotated.width == 20 && rotated.height == 40, "orientation 6 swaps edges");
    EXPECT(rotated.appliedExif == 6, "applied exif");

    TLEncodedImage *forced = TLEncodeJPEG(jpeg, @"full", 0.9, 6, &error);
    EXPECT(forced.width < forced.height, "override orientation swaps a landscape frame");
}

static struct sockaddr_in TLIPv4(const char *text) {
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    inet_pton(AF_INET, text, &address.sin_addr);
    return address;
}

static NSData *TLRawHTTPData(uint16_t port, NSString *request) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return nil;
    }
    struct timeval timeout = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in address = TLIPv4("127.0.0.1");
    address.sin_port = htons(port);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return nil;
    }
    const char *bytes = request.UTF8String;
    size_t length = strlen(bytes);
    size_t sent = 0;
    while (sent < length) {
        ssize_t count = write(fd, bytes + sent, length - sent);
        if (count <= 0) {
            break;
        }
        sent += (size_t)count;
    }
    NSMutableData *data = [NSMutableData data];
    while (data.length < 64 * 1024 * 1024) {
        uint8_t buffer[4096];
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count <= 0) {
            break;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    close(fd);
    return data;
}

static NSString *TLRawHTTP(uint16_t port, NSString *request) {
    return [[NSString alloc] initWithData:TLRawHTTPData(port, request) encoding:NSUTF8StringEncoding];
}

static NSString *TLWebCall(uint16_t port, NSString *method, NSString *path, NSString *json, NSString *cookie, BOOL mark) {
    NSMutableString *request = [NSMutableString string];
    [request appendFormat:@"%@ %@ HTTP/1.1\r\nHost: 127.0.0.1:%u\r\n", method, path, port];
    if (mark) {
        [request appendString:@"X-Tlapse-Request: 1\r\n"];
    }
    if (cookie.length > 0) {
        [request appendFormat:@"Cookie: %@\r\n", cookie];
    }
    NSData *body = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (body) {
        [request appendFormat:@"Content-Type: application/json\r\nContent-Length: %lu\r\n", (unsigned long)body.length];
    }
    [request appendString:@"Connection: close\r\n\r\n"];
    if (json) {
        [request appendString:json];
    }
    return TLRawHTTP(port, request);
}

static NSString *TLSessionCookie(NSString *response) {
    NSRange start = [response rangeOfString:@"tlapse_session="];
    if (start.location == NSNotFound) {
        return nil;
    }
    NSString *rest = [response substringFromIndex:start.location];
    NSRange end = [rest rangeOfString:@";"];
    if (end.location == NSNotFound) {
        return nil;
    }
    return [rest substringToIndex:end.location];
}

static NSDictionary *TLClientCall(TLClient *client, NSString *method, NSString *path, NSDictionary *body, NSError **error) {
    __block BOOL done = NO;
    __block NSDictionary *result = nil;
    __block NSError *failure = nil;
    [client request:method path:path body:body timeout:2 reply:^(NSDictionary *payload, NSError *requestError) {
        result = payload;
        failure = requestError;
        done = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    EXPECT(done, "native client invokes completion on main queue");
    *error = failure;
    return result;
}

static void TLTestNativeClient(uint16_t port) {
    NSURL *defaultURL = [TLClient serverURLForAddress:@" 127.0.0.1 "];
    EXPECT([defaultURL.absoluteString isEqualToString:@"http://127.0.0.1:8080"], "native default port");
    EXPECT([TLClient serverURLForAddress:@"http://user@localhost"] == nil, "native rejects URL credentials");
    EXPECT([TLClient serverURLForAddress:@"http://localhost/api?token=ignored"] == nil, "native requires server origin");
    EXPECT([TLPathSegment(@"a/b?x=#") isEqualToString:@"a%2Fb%3Fx%3D%23"], "native escapes path segments");
    NSURL *url = [TLClient serverURLForAddress:[NSString stringWithFormat:@"127.0.0.1:%u", port]];
    TLClient *client = [[TLClient alloc] initWithServer:url];
    NSError *error = nil;
    TLClientCall(client, @"GET", @"/api/projects", nil, &error);
    EXPECT([error.domain isEqualToString:TLHTTPErrorDomain] && error.code == 401, "native detects unauthenticated response");
    NSDictionary *login = TLClientCall(client, @"POST", @"/api/login", @{@"token": @"correct-horse-battery"}, &error);
    EXPECT(!error && [login[@"ok"] boolValue], "native logs in with JSON and request header");
    NSURL *mediaURL = [client URLForPath:@"/api/projects/plant/media/videos/example.mp4"];
    EXPECT([[client cookiesForURL:mediaURL].firstObject.name isEqualToString:@"tlapse_session"], "native exposes applicable session to AVKit");
    TLClient *otherClient = [[TLClient alloc] initWithServer:url];
    EXPECT(![otherClient cookiesForURL:url].count, "native does not share session between logins");
    [otherClient invalidate];
    NSDictionary *projects = TLClientCall(client, @"GET", @"/api/projects", nil, &error);
    EXPECT(!error && [projects[@"projects"][0][@"id"] isEqualToString:@"plant"], "native lists projects with session cookie");
    NSDictionary *update = TLClientCall(client, @"POST", @"/api/projects/plant/pause", nil, &error);
    EXPECT(!error && [update[@"enabled"] isEqual:@NO], "native sends header and cookie on bodyless commands");
    NSDictionary *logout = TLClientCall(client, @"POST", @"/api/logout", nil, &error);
    EXPECT(!error && [logout[@"ok"] boolValue], "native logs out");
    TLClientCall(client, @"GET", @"/api/projects", nil, &error);
    EXPECT([error.domain isEqualToString:TLHTTPErrorDomain] && error.code == 401, "native session ends on logout");
    [client invalidate];
}

static void TLTestWeb(void) {
    struct sockaddr_in lan = TLIPv4("192.168.1.20");
    struct sockaddr_in publicAddress = TLIPv4("8.8.8.8");
    struct sockaddr_in carrier = TLIPv4("10.8.0.4");
    struct sockaddr_in tailscale = TLIPv4("100.64.1.1");
    struct sockaddr_in outsideCGNAT = TLIPv4("100.128.0.1");
    struct sockaddr_in hotspot = TLIPv4("172.20.10.2");
    struct sockaddr_in notPrivate172 = TLIPv4("172.32.0.1");
    struct sockaddr_in loopback = TLIPv4("127.0.0.1");
    EXPECT(TLWebSocketAddressUsable(@"en0", (struct sockaddr *)&lan, NO), "wifi private");
    EXPECT(!TLWebSocketAddressUsable(@"en0", (struct sockaddr *)&lan, YES), "tests stay on loopback");
    EXPECT(!TLWebSocketAddressUsable(@"en0", (struct sockaddr *)&publicAddress, NO), "reject public address");
    EXPECT(!TLWebSocketAddressUsable(@"pdp_ip0", (struct sockaddr *)&carrier, NO), "skip cellular");
    EXPECT(TLWebSocketAddressUsable(@"utun4", (struct sockaddr *)&tailscale, NO), "tailscale");
    EXPECT(!TLWebSocketAddressUsable(@"utun4", (struct sockaddr *)&outsideCGNAT, NO), "outside cgnat");
    EXPECT(TLWebSocketAddressUsable(@"bridge100", (struct sockaddr *)&hotspot, NO), "hotspot");
    EXPECT(!TLWebSocketAddressUsable(@"bridge100", (struct sockaddr *)&notPrivate172, NO), "172.32 is public");
    EXPECT(TLWebSocketAddressUsable(@"lo0", (struct sockaddr *)&loopback, YES), "loopback");
    EXPECT(!TLWebTokenAcceptable(@"change-me"), "default token stays closed");
    EXPECT(!TLWebTokenAcceptable(@"short-token-1"), "token shorter than 16");
    EXPECT(TLWebTokenAcceptable(@"correct-horse-battery"), "usable token");
    EXPECT(TLWebConstantTimeEqual(@"abc", @"abc"), "equal secret");
    EXPECT(!TLWebConstantTimeEqual(@"abc", @"abd"), "different secret");
    EXPECT(TLWebHostAllowed(@"127.0.0.1:8080", @[@"127.0.0.1"], 8080), "numeric host");
    EXPECT(TLWebHostAllowed(@"iPhone.local", @[@"10.0.0.8"], 8080), "mdns host");
    EXPECT(!TLWebHostAllowed(@"evil.example:8080", @[@"10.0.0.8"], 8080), "reject public name");
    EXPECT(!TLWebHostAllowed(@"10.0.0.8:9", @[@"10.0.0.8"], 8080), "reject other port");
    NSString *safe = TLWebSafePath(@"/tmp/tlapse-root", @[@"projects", @"plant", @"frames", @"20261111", @"120000.jpg"]);
    EXPECT([safe hasSuffix:@"/projects/plant/frames/20261111/120000.jpg"], "safe frame path");
    EXPECT(TLWebSafePath(@"/tmp/tlapse-root", @[@"..", @"secret"]) == nil, "reject traversal");

    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *configPath = [directory stringByAppendingPathComponent:@"config.json"];
    NSString *indexPath = [directory stringByAppendingPathComponent:@"index.html"];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    [@"<title>console-ok</title>" writeToFile:indexPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *document = @{
        @"server": @{@"port": @8080, @"token": @"correct-horse-battery"},
        @"storage": @{@"root": @"/var/mobile/Timelapse", @"minFreeGB": @1},
        @"projects": @[@{@"id": @"plant", @"name": @"豆苗", @"enabled": @NO, @"capture": @{@"interval": @60}}]
    };
    NSData *configData = [NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingPrettyPrinted error:&error];
    EXPECT(configData != nil && [configData writeToFile:configPath atomically:YES], "write web config");
    TLConfig *config = [TLConfig configWithContentsOfFile:configPath error:&error];
    TLState *state = [[TLState alloc] initWithPath:[directory stringByAppendingPathComponent:@"state.json"]];
    TLWebServer *server = [[TLWebServer alloc] initWithConfigPath:configPath state:state snap:^TLCaptureResult *(TLProject *project) {
        TLCaptureResult *result = [[TLCaptureResult alloc] init];
        result.outcome = TLCaptureOutcomeSaved;
        result.message = [NSString stringWithFormat:@"已测试 %@", project.projectID];
        result.relativePath = @"projects/plant/frames/20261111/120000.jpg";
        result.capturedAt = [NSDate date];
        return result;
    }];
    server.indexFileOverride = indexPath;
    EXPECT([server startLoopbackForTests:config error:&error], error.localizedDescription.UTF8String ?: "start console");
    EXPECT(server.port > 0, "ephemeral port");
    for (NSString *listener in server.listenAddresses) {
        EXPECT([listener hasPrefix:@"127.0.0.1:"] || [listener hasPrefix:@"[::1]:"], "only loopback");
    }
    uint16_t port = server.port;
    TLTestNativeClient(port);
    NSString *index = TLWebCall(port, @"GET", @"/", nil, nil, NO);
    EXPECT([index containsString:@" 200 "] && [index containsString:@"console-ok"], "index");
    NSString *evil = TLRawHTTP(port, [NSString stringWithFormat:@"GET /api/status HTTP/1.1\r\nHost: evil.example:%u\r\nConnection: close\r\n\r\n", port]);
    EXPECT([evil containsString:@" 403 "], "public host rejected");
    NSString *anonymous = TLWebCall(port, @"GET", @"/api/status?token=correct-horse-battery", nil, nil, NO);
    EXPECT([anonymous containsString:@" 401 "], "query token ignored");
    NSString *bearer = TLRawHTTP(port, [NSString stringWithFormat:@"GET /api/status HTTP/1.1\r\nHost: 127.0.0.1:%u\r\nAuthorization: Bearer correct-horse-battery\r\nConnection: close\r\n\r\n", port]);
    NSString *expectedVersion = [NSString stringWithFormat:@"\"version\":\"%@\"", TLAPSED_VERSION_STRING];
    EXPECT([bearer containsString:expectedVersion], "bearer status");
    NSString *login = TLWebCall(port, @"POST", @"/api/login", @"{\"token\":\"correct-horse-battery\"}", nil, YES);
    NSString *cookie = TLSessionCookie(login);
    EXPECT([login containsString:@" 200 "] && cookie.length > 0, "login cookie");
    NSString *unmarked = TLWebCall(port, @"POST", @"/api/projects/plant/resume", nil, cookie, NO);
    EXPECT([unmarked containsString:@" 403 "], "mutation needs header");
    NSString *resumed = TLWebCall(port, @"POST", @"/api/projects/plant/resume", nil, cookie, YES);
    EXPECT([resumed containsString:@" 200 "], "resume");
    TLConfig *reloaded = [TLConfig configWithContentsOfFile:configPath error:&error];
    EXPECT(reloaded.projects[0].enabled, "resume written");
    NSString *activeContent = TLWebCall(port, @"DELETE", @"/api/projects/plant/content", nil, cookie, YES);
    EXPECT([activeContent containsString:@" 409 "], "enabled project content cannot be deleted");
    NSString *created = TLWebCall(port, @"POST", @"/api/projects", @"{\"id\":\"sprout\",\"name\":\"新芽\"}", cookie, YES);
    EXPECT([created containsString:@" 200 "], "create project");
    NSString *listed = TLWebCall(port, @"GET", @"/api/projects", nil, cookie, NO);
    EXPECT([listed containsString:@"sprout"], "list includes sprout");
    NSString *snap = TLWebCall(port, @"POST", @"/api/projects/plant/snap", nil, cookie, YES);
    EXPECT([snap containsString:@"已测试 plant"], "snap");
    NSString *quiet = TLWebCall(port, @"PUT", @"/api/projects/plant", @"{\"capture\":{\"shutterSound\":false,\"jpegQuality\":0.5},\"encode\":{\"targetDuration\":null}}", cookie, YES);
    EXPECT([quiet containsString:@" 200 "], "save shutter and quality");
    TLConfig *patched = [TLConfig configWithContentsOfFile:configPath error:&error];
    EXPECT(patched.projects[0].shutterSound == NO && fabs(patched.projects[0].jpegQuality - 0.5) < 0.001, "shutter and quality written");
    EXPECT(!patched.projects[0].hasTargetDuration, "null removes target duration");
    NSString *missingFrame = TLWebCall(port, @"DELETE", @"/api/projects/plant/frames/20261111/120000.jpg", nil, cookie, YES);
    EXPECT([missingFrame containsString:@" 404 "], "missing frame delete");
    NSString *capabilities = TLWebCall(port, @"GET", @"/api/status", nil, cookie, NO);
    EXPECT([capabilities containsString:@"\"encode\":false"] && [capabilities containsString:@"\"upload\":false"], "disabled capabilities are JSON booleans");
    NSString *videos = TLWebCall(port, @"GET", @"/api/projects/plant/videos", nil, cookie, NO);
    EXPECT([videos containsString:@"\"encodeEnabled\":false"], "video capability is JSON boolean");
    NSString *encode = TLWebCall(port, @"POST", @"/api/projects/plant/encode", nil, cookie, YES);
    EXPECT([encode containsString:@" 501 "], "encode deferred");
    [server stop];

    NSMutableDictionary *weakDocument = [document mutableCopy];
    weakDocument[@"server"] = @{@"port": @8080, @"token": @"change-me"};
    NSString *weakPath = [directory stringByAppendingPathComponent:@"weak.json"];
    NSData *weakData = [NSJSONSerialization dataWithJSONObject:weakDocument options:0 error:nil];
    [weakData writeToFile:weakPath atomically:YES];
    TLConfig *weak = [TLConfig configWithContentsOfFile:weakPath error:&error];
    TLWebServer *closed = [[TLWebServer alloc] initWithConfigPath:weakPath state:state snap:nil];
    EXPECT([closed startLoopbackForTests:weak error:&error], "weak token does not crash");
    EXPECT(closed.port == 0 && closed.listenAddresses.count == 0, "weak token does not listen");
    [closed stop];

    TLWebServer *limited = [[TLWebServer alloc] initWithConfigPath:configPath state:state snap:nil];
    EXPECT([limited startLoopbackForTests:config error:&error], "rate limit server");
    BOOL sawLock = NO;
    for (NSInteger attempt = 0; attempt < 8; attempt++) {
        NSString *rejected = TLWebCall(limited.port, @"POST", @"/api/login", @"{\"token\":\"wrong-horse-battery\"}", nil, YES);
        if ([rejected containsString:@" 429 "]) {
            sawLock = YES;
        }
    }
    EXPECT(sawLock, "lock after repeated passwords");
    NSString *stillLocked = TLWebCall(limited.port, @"POST", @"/api/login", @"{\"token\":\"correct-horse-battery\"}", nil, YES);
    EXPECT([stillLocked containsString:@" 429 "], "correct password stays locked");
    [limited stop];
}

#include "test_web_files.inc"

static BOOL TLWriteJPEGFile(NSString *path, CGImageRef image) {
    NSData *data = TLJPEGWithOrientation(image, 1);
    if (data.length == 0) {
        return NO;
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    return [data writeToFile:path atomically:YES];
}

static CGImageRef TLSplitImage(size_t width, size_t height) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    CGContextSetRGBFillColor(context, 0, 0, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height / 2.0));
    CGContextSetRGBFillColor(context, 1, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, height / 2.0, width, height / 2.0));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

static void TLSamplePixel(CGImageRef image, double nx, double ny, unsigned char rgba[4]) {
    memset(rgba, 0, 4);
    if (!image) {
        return;
    }
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0) {
        return;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(rgba, 1, 1, 8, 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        return;
    }
    CGFloat imageWidth = (CGFloat)width;
    CGFloat imageHeight = (CGFloat)height;
    CGFloat sampleX = nx * imageWidth;
    CGFloat sampleY = (1.0 - ny) * imageHeight;
    CGContextDrawImage(context, CGRectMake(0.5 - sampleX, 0.5 - sampleY, imageWidth, imageHeight), image);
    CGContextRelease(context);
}

static TLProject *TLTestProject(NSDictionary *encode) {
    NSError *error = nil;
    TLConfig *config = [TLConfig configWithDictionary:@{
        @"storage": @{@"root": @"/var/mobile/Timelapse"},
        @"projects": @[@{
            @"id": @"plant",
            @"name": @"测试",
            @"enabled": @NO,
            @"encode": encode,
        }],
    } error:&error];
    EXPECT(config.projects.count == 1, error.localizedDescription.UTF8String ?: "test project");
    return config.projects.firstObject;
}

static void TLTestEncodeAndUpload(void) {
    NSTimeZone *utc = [NSTimeZone timeZoneWithName:@"UTC"];
    EXPECT(TLEncodeStride(1000, 30, YES, 30) == 2, "1000 frames stride 2");
    EXPECT(TLEncodeStride(10, 30, NO, 0) == 1, "no target uses every frame");
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSInteger index = 0; index < 1000; index++) {
        [names addObject:[NSString stringWithFormat:@"f%04ld", (long)index]];
    }
    NSArray<NSString *> *picked = TLStridedFrames(names, 2);
    EXPECT(picked.count == 501, "stride includes the last frame");
    EXPECT([picked.firstObject isEqualToString:@"f0000"] && [picked.lastObject isEqualToString:@"f0999"], "stride endpoints");

    TLPixelSize fitted = TLEncodeOutputSize(TLPixelSizeMake(3264, 2448));
    EXPECT(fitted.width == 1920 && fitted.height == 1440, "long edge 1920");
    TLPixelSize nativeSize = TLEncodeOutputSize(TLPixelSizeMake(100, 50));
    EXPECT(nativeSize.width == 100 && nativeSize.height == 50, "do not upscale video");
    TLPixelSize even = TLEncodeOutputSize(TLPixelSizeMake(11, 7));
    EXPECT(even.width == 10 && even.height == 6, "video dimensions even");

    NSInteger at = 23 * 60 + 30;
    NSDate *morning = TLDate(2026, 11, 12, 10, 0, 0, utc);
    NSDate *slot = nil;
    NSTimeInterval delay = TLNextEncodeDelay(nil, nil, 1, at, morning, utc, &slot);
    EXPECT(fabs(delay - 15) < 1, "missed daily slot catches up");
    EXPECT(fabs([slot timeIntervalSinceDate:TLDate(2026, 11, 11, 23, 30, 0, utc)]) < 1, "catch-up slot is yesterday");

    NSDate *beforeSlot = TLDate(2026, 11, 12, 23, 0, 0, utc);
    delay = TLNextEncodeDelay(TLDate(2026, 11, 11, 23, 30, 0, utc), nil, 1, at, beforeSlot, utc, &slot);
    EXPECT(fabs(delay - 30 * 60) < 1, "finished yesterday waits until tonight");
    EXPECT(fabs([slot timeIntervalSinceDate:TLDate(2026, 11, 11, 23, 30, 0, utc)]) < 1, "pending slot stays yesterday");

    NSDate *afterSlot = TLDate(2026, 11, 12, 23, 40, 0, utc);
    delay = TLNextEncodeDelay(TLDate(2026, 11, 11, 23, 30, 0, utc), nil, 1, at, afterSlot, utc, &slot);
    EXPECT(fabs(delay - 15) < 1, "today slot is due");
    EXPECT(fabs([slot timeIntervalSinceDate:TLDate(2026, 11, 12, 23, 30, 0, utc)]) < 1, "due slot is today");

    delay = TLNextEncodeDelay(TLDate(2026, 11, 12, 23, 30, 0, utc), TLDate(2026, 11, 12, 23, 30, 0, utc), 1, at, afterSlot, utc, &slot);
    EXPECT(fabs(delay - (23 * 60 * 60 + 50 * 60)) < 1, "success waits until tomorrow");

    delay = TLNextEncodeDelay(nil, TLDate(2026, 11, 12, 23, 35, 0, utc), 1, at, afterSlot, utc, &slot);
    EXPECT(fabs(delay - 25 * 60) < 1, "recent failure waits out 30 minutes");

    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = utc;
    NSDate *origin = TLDate(2020, 1, 1, 0, 0, 0, utc);
    NSDate *probe = TLDate(2026, 11, 12, 0, 0, 0, utc);
    NSInteger dayOffset = [calendar components:NSCalendarUnitDay fromDate:origin toDate:probe options:0].day;
    NSInteger phase = dayOffset % 7;
    if (phase < 0) {
        phase += 7;
    }
    NSDate *matchedDay = [calendar dateByAddingUnit:NSCalendarUnitDay value:-phase toDate:probe options:0];
    NSDate *weeklySlot = [calendar dateByAddingUnit:NSCalendarUnitMinute value:at toDate:matchedDay options:0];
    if ([weeklySlot compare:morning] == NSOrderedDescending) {
        weeklySlot = [calendar dateByAddingUnit:NSCalendarUnitDay value:-7 toDate:weeklySlot options:0];
    }
    delay = TLNextEncodeDelay(nil, nil, 7, at, morning, utc, &slot);
    EXPECT(fabs(delay - 15) < 1, "weekly catch-up");
    EXPECT(fabs([slot timeIntervalSinceDate:weeklySlot]) < 1, "weekly slot follows 2020-01-01");
    delay = TLNextEncodeDelay(weeklySlot, weeklySlot, 7, at, morning, utc, &slot);
    EXPECT(delay > 6 * 24 * 60 * 60, "next weekly slot is more than six days away");

    EXPECT(!TLSecretConfigured(@"ENV:TG_TOKEN"), "ENV prefix is not a secret");
    EXPECT(!TLSecretConfigured(@"   "), "blank secret");
    EXPECT(TLSecretConfigured(@"123456:ABC_def"), "real token");
    EXPECT(TLTelegramMethodURL(@"ENV:TG_TOKEN", @"sendVideo") == nil, "ENV token builds no URL");
    EXPECT(TLTelegramMethodURL(@"bad token", @"sendVideo") == nil, "token with a space");
    EXPECT([TLTelegramMethodURL(@"123456:ABC_def", @"sendVideo") isEqualToString:@"https://api.telegram.org/bot123456:ABC_def/sendVideo"], "telegram method url");
    EXPECT(TLWebDAVFileURL(@"http://dav.example/a/", @"plant", @"clip.mp4") == nil, "webdav rejects http");
    EXPECT([TLWebDAVFileURL(@"https://dav.example/a", @"plant", @"plant_20261112_daily.mp4") isEqualToString:@"https://dav.example/a/plant/plant_20261112_daily.mp4"], "webdav joins https path");

    EXPECT(TLUploadRetryDelay(1) == 30, "retry 30s");
    EXPECT(TLUploadRetryDelay(2) == 120, "retry 2m");
    EXPECT(TLUploadRetryDelay(3) == 480, "retry 8m");
    EXPECT(TLUploadRetryDelay(4) == 1800, "retry 30m");
    EXPECT(TLUploadRetryDelay(5) == 7200, "retry 2h");
    EXPECT([TLRedactSecret(@"see SECRET and SECRET", @"SECRET") isEqualToString:@"see *** and ***"], "redact secret");
    NSData *multipart = TLMultipartBody(@"BOUND",
                                        @{@"b": @"2", @"a": @"1"},
                                        @"video",
                                        @"clip.mp4",
                                        [@"xyz" dataUsingEncoding:NSUTF8StringEncoding],
                                        @"video/mp4");
    NSString *form = [[NSString alloc] initWithData:multipart encoding:NSUTF8StringEncoding];
    NSRange fieldA = [form rangeOfString:@"name=\"a\""];
    NSRange fieldB = [form rangeOfString:@"name=\"b\""];
    NSRange filePart = [form rangeOfString:@"filename=\"clip.mp4\""];
    EXPECT(fieldA.location != NSNotFound && fieldB.location != NSNotFound && fieldA.location < fieldB.location && fieldB.location < filePart.location, "multipart order");
    EXPECT([form containsString:@"xyz"], "multipart file bytes");

    NSString *queueRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:queueRoot withIntermediateDirectories:YES attributes:nil error:nil];
    TLState *queueState = [[TLState alloc] initWithPath:[queueRoot stringByAppendingPathComponent:@"state.json"]];
    TLUploader *uploader = [[TLUploader alloc] initWithState:queueState storageRoot:queueRoot];
    for (NSInteger attempt = 0; attempt < 4; attempt++) {
        EXPECT([[uploader recordFailureForProject:@"plant" fileName:@"clip.mp4" target:@"telegram" message:@"暂时失败"] isEqualToString:@"queued"], "failure stays queued");
    }
    EXPECT([uploader pendingCount] == 1, "one pending upload");
    EXPECT([[uploader recordFailureForProject:@"plant" fileName:@"clip.mp4" target:@"telegram" message:@"暂时失败"] isEqualToString:@"exhausted"], "fifth failure stops");
    EXPECT([uploader pendingCount] == 0, "exhausted job leaves the queue");

    NSString *frameRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    CGImageRef solid = TLSolidImage(8, 8, 20, 30, 40);
    NSArray<NSString *> *kept = @[
        @"projects/plant/frames/20261029/000000.jpg",
        @"projects/plant/frames/20261112/000000.jpg",
        @"projects/ants/frames/20261111/000000.jpg",
        @"projects/ants/frames/20261112/000000.jpg",
        @"projects/up/frames/20200101/000000.jpg",
        @"projects/up/frames/20261112/000000.jpg",
        @"projects/skip/frames/20200101/000000.jpg",
    ];
    BOOL wroteFrames = TLWriteJPEGFile([frameRoot stringByAppendingPathComponent:@"projects/plant/frames/20200101/000000.jpg"], solid);
    wroteFrames = TLWriteJPEGFile([frameRoot stringByAppendingPathComponent:@"projects/plant/thumbs/20200101/000000.jpg"], solid) && wroteFrames;
    for (NSString *relative in kept) {
        wroteFrames = TLWriteJPEGFile([frameRoot stringByAppendingPathComponent:relative], solid) && wroteFrames;
    }
    CGImageRelease(solid);
    EXPECT(wroteFrames, "write cleanup fixtures");
    NSDate *cleanupNow = TLDate(2026, 11, 12, 12, 0, 0, utc);
    NSInteger removed = TLCleanupExpiredFrames(frameRoot, @"plant", 14, cleanupNow, utc);
    EXPECT(removed == 2, "delete frame and thumb older than 14 days");
    EXPECT(![[NSFileManager defaultManager] fileExistsAtPath:[frameRoot stringByAppendingPathComponent:@"projects/plant/frames/20200101"]], "old day folder gone");
    EXPECT([[NSFileManager defaultManager] fileExistsAtPath:[frameRoot stringByAppendingPathComponent:@"projects/plant/frames/20261029/000000.jpg"]], "boundary day stays");
    EXPECT([[NSFileManager defaultManager] fileExistsAtPath:[frameRoot stringByAppendingPathComponent:@"projects/plant/frames/20261112/000000.jpg"]], "today stays");
    NSInteger droppedYesterday = TLCleanupExpiredFrames(frameRoot, @"ants", 0, cleanupNow, utc);
    EXPECT(droppedYesterday == 1, "keep 0 drops days before today");
    EXPECT([[NSFileManager defaultManager] fileExistsAtPath:[frameRoot stringByAppendingPathComponent:@"projects/ants/frames/20261112/000000.jpg"]], "keep 0 still keeps today");
    NSInteger reclaimed = TLReclaimUploadedFrames(frameRoot, @[@"up", @"skip"], [NSSet setWithObject:@"up"], @"20261112", 1000000);
    EXPECT(reclaimed == 1, "low space reclaims an uploaded day");
    EXPECT(![[NSFileManager defaultManager] fileExistsAtPath:[frameRoot stringByAppendingPathComponent:@"projects/up/frames/20200101/000000.jpg"]], "uploaded old day removed");
    EXPECT([[NSFileManager defaultManager] fileExistsAtPath:[frameRoot stringByAppendingPathComponent:@"projects/up/frames/20261112/000000.jpg"]], "today is not reclaimed");
    EXPECT([[NSFileManager defaultManager] fileExistsAtPath:[frameRoot stringByAppendingPathComponent:@"projects/skip/frames/20200101/000000.jpg"]], "project without an upload is kept");

    NSString *videoRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *videoDay = TLFormatFileDay([NSDate date], [NSTimeZone localTimeZone]);
    CGImageRef split = TLSplitImage(64, 48);
    NSString *firstFrame = [videoRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"projects/plant/frames/%@/000000.jpg", videoDay]];
    NSString *secondFrame = [videoRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"projects/plant/frames/%@/000001.jpg", videoDay]];
    EXPECT(TLWriteJPEGFile(firstFrame, split) && TLWriteJPEGFile(secondFrame, split), "write encode frames");
    CGImageRelease(split);
    TLProject *project = TLTestProject(@{@"every": @"daily", @"at": @"23:30", @"mode": @"daily", @"fps": @30});
    TLEncoder *encoder = [[TLEncoder alloc] init];
    TLEncodeResult *encoded = [encoder encodeProject:project storageRoot:videoRoot date:[NSDate date] timeZone:[NSTimeZone localTimeZone]];
    EXPECT(encoded.succeeded, encoded.message.UTF8String ?: "encode two frames");
    EXPECT(encoded.frameCount == 2 && encoded.width == 64 && encoded.height == 48, "encoded size");
    EXPECT([[NSFileManager defaultManager] fileExistsAtPath:encoded.absolutePath], "mp4 written");
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:encoded.absolutePath] options:nil];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.requestedTimeToleranceBefore = kCMTimeZero;
    generator.requestedTimeToleranceAfter = kCMTimeZero;
    NSError *imageError = nil;
    CGImageRef frame = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    frame = [generator copyCGImageAtTime:CMTimeMake(0, 30) actualTime:NULL error:&imageError];
#pragma clang diagnostic pop
    EXPECT(frame != NULL, imageError.localizedDescription.UTF8String ?: "read encoded frame");
    unsigned char top[4] = {0};
    unsigned char bottom[4] = {0};
    TLSamplePixel(frame, 0.5, 0.15, top);
    TLSamplePixel(frame, 0.5, 0.85, bottom);
    EXPECT(top[0] > 200 && top[1] < 40 && top[2] < 40, "encoded top stays red");
    EXPECT(bottom[2] > 200 && bottom[0] < 40 && bottom[1] < 40, "encoded bottom stays blue");
    if (frame) {
        CGImageRelease(frame);
    }
    TLEncodeResult *empty = [encoder encodeProject:project storageRoot:[videoRoot stringByAppendingString:@"-missing"] date:[NSDate date] timeZone:[NSTimeZone localTimeZone]];
    EXPECT(empty.empty && !empty.succeeded && [empty.message containsString:@"没有可合成的照片"], "empty encode");

    [[NSFileManager defaultManager] removeItemAtPath:queueRoot error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:frameRoot error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:videoRoot error:nil];
}

static void TLTestRemoveFrame(void) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *frame = [root stringByAppendingPathComponent:@"projects/plant/frames/20261111/120000.jpg"];
    NSString *thumb = [root stringByAppendingPathComponent:@"projects/plant/thumbs/20261111/120000.jpg"];
    NSString *keep = [root stringByAppendingPathComponent:@"projects/plant/frames/20261111/120001.jpg"];
    [[NSFileManager defaultManager] createDirectoryAtPath:frame.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:thumb.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    EXPECT([@"frame" writeToFile:frame atomically:YES encoding:NSUTF8StringEncoding error:nil], "write frame");
    EXPECT([@"thumb" writeToFile:thumb atomically:YES encoding:NSUTF8StringEncoding error:nil], "write thumb");
    EXPECT([@"keep" writeToFile:keep atomically:YES encoding:NSUTF8StringEncoding error:nil], "write neighbor");
    EXPECT(TLRemoveCapturedFrame(root, @"plant", @"20261111", @"120000.jpg") == 2, "remove frame and thumb");
    EXPECT(![[NSFileManager defaultManager] fileExistsAtPath:frame], "frame file gone");
    EXPECT(![[NSFileManager defaultManager] fileExistsAtPath:thumb.stringByDeletingLastPathComponent], "empty thumb day removed");
    EXPECT([[NSFileManager defaultManager] fileExistsAtPath:keep], "neighbor frame stays");
    EXPECT(TLRemoveCapturedFrame(root, @"plant", @"20261111", @"../120000.jpg") == 0, "reject traversal name");
    EXPECT(TLRemoveCapturedFrame(root, @"plant", @"20261111", @"note.txt") == 0, "reject non jpeg");
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
}

#include "test_runtime.m"

@interface TLTestPhotoSettings : NSObject
@property (nonatomic) unsigned int shutterSound;
@property (nonatomic) BOOL highResolution;
@property (nonatomic) BOOL rejectSetter;
@end

@implementation TLTestPhotoSettings
- (void)setShutterSound:(unsigned int)value {
    if (_rejectSetter) {
        [NSException raise:NSInvalidArgumentException format:@"You are not authorized to use custom shutter sounds"];
    }
    _shutterSound = value;
}
@end

@interface TLTestBadPhotoSettings : NSObject
@property (nonatomic) NSUInteger setterCalls;
- (void)setShutterSound:(unsigned long long)value;
@end

@implementation TLTestBadPhotoSettings
- (void)setShutterSound:(unsigned long long)value {
    (void)value;
    self.setterCalls++;
}
@end

static void TLTestPhotoRequest(void) {
    NSString *denied = @"*** -[AVCapturePhotoOutput capturePhotoWithSettings:delegate:] You are not authorized to use custom shutter sounds";
    for (NSInteger scenario = 0; scenario < 9; scenario++) {
        __block NSUInteger submitted = 0;
        NSMutableArray *settingsMade = [NSMutableArray array];
        NSMutableArray<NSNumber *> *soundsSubmitted = [NSMutableArray array];
        NSError *error = nil;
        BOOL ok = TLSubmitPhotoRequest(scenario == 0 || scenario == 4, @"photo-fixture", ^id {
            id settings = nil;
            if (scenario == 2) {
                settings = [[NSObject alloc] init];
            } else if (scenario == 8) {
                settings = [[TLTestBadPhotoSettings alloc] init];
            } else {
                TLTestPhotoSettings *photo = [[TLTestPhotoSettings alloc] init];
                photo.shutterSound = 1108;
                photo.highResolution = YES;
                photo.rejectSetter = scenario == 7 && settingsMade.count == 0;
                settings = photo;
            }
            [settingsMade addObject:settings];
            return settings;
        }, ^(__unsafe_unretained id settings) {
            submitted++;
            if (scenario == 2 || scenario == 8) {
                return;
            }
            __unsafe_unretained TLTestPhotoSettings *photo = settings;
            [soundsSubmitted addObject:@(photo.shutterSound)];
            EXPECT(photo.highResolution, "photo submission preserves factory configuration");
            if (scenario == 3) {
                [NSException raise:NSInvalidArgumentException format:@"%@", denied];
            }
            if (scenario == 4 || scenario == 5) {
                [NSException raise:NSInvalidArgumentException format:@"camera disconnected"];
            }
            if (scenario == 6) {
                [NSException raise:NSInvalidArgumentException format:@"custom shutter sound not supported"];
            }
        }, &error);
        EXPECT(settingsMade.count == 1, "strict photo policy never creates a default fallback");
        if (scenario == 2 || scenario == 7 || scenario == 8) {
            EXPECT(submitted == 0, "unsupported settings or denied setter never submit an audible request");
            EXPECT(soundsSubmitted.count == 0, "silent preflight failure never reaches submission");
        } else {
            EXPECT(settingsMade.count == 1 && submitted == 1, "ordinary request submits once");
        }
        BOOL expectedSuccess = scenario == 0 || scenario == 1;
        EXPECT(ok == expectedSuccess, "photo submission result reflects accepted request or final rejection");
        if (!expectedSuccess) {
            EXPECT(error.code == TLErrorCodeCamera, "photo submission failure preserves camera error");
            if (scenario == 4) {
                EXPECT([error.localizedDescription isEqualToString:@"camera disconnected"], "audible camera error is unchanged");
            } else {
                EXPECT([error.localizedDescription containsString:@"静音"] &&
                       [error.localizedDescription containsString:@"有声"], "silent error explains the refused audible fallback");
            }
            if (scenario == 3 || scenario == 7) {
                EXPECT([error.localizedDescription containsString:@"not authorized"], "authorization error is not hidden");
            } else if (scenario == 5) {
                EXPECT([error.localizedDescription containsString:@"camera disconnected"], "ordinary silent camera error is preserved");
            } else if (scenario == 6) {
                EXPECT([error.localizedDescription containsString:@"not supported"], "unsupported error is preserved");
            }
        } else {
            EXPECT(error == nil, "accepted request does not report a failure");
        }
        if (scenario == 0) {
            EXPECT([soundsSubmitted isEqualToArray:@[@1108]], "normal shutter setting is untouched");
        } else if (scenario != 4 && submitted) {
            EXPECT([soundsSubmitted isEqualToArray:@[@0]], "silent requests never submit a nonzero sound");
        }
        if (scenario == 8) {
            EXPECT(((TLTestBadPhotoSettings *)settingsMade.firstObject).setterCalls == 0, "bad setter ABI is rejected before invocation");
        }
    }
    for (NSUInteger scenario = 0; scenario < 3; scenario++) {
        __block __weak TLTestPhotoSettings *created = nil;
        __block NSUInteger submitted = 0;
        @autoreleasepool {
            BOOL ok = TLSubmitPhotoRequest(NO, @"photo-lifetime", ^id {
                TLTestPhotoSettings *settings = [[TLTestPhotoSettings alloc] init];
                settings.shutterSound = 1108;
                settings.rejectSetter = scenario == 2;
                created = settings;
                return settings;
            }, ^(__unsafe_unretained id settings) {
                (void)settings;
                submitted++;
                if (scenario == 1) [NSException raise:NSInvalidArgumentException format:@"%@", denied];
            }, nil);
            EXPECT(ok == (scenario == 0), "lifetime fixture preserves strict acceptance result");
            EXPECT(submitted == (scenario == 2 ? 0u : 1u), "lifetime fixture has no default retry");
        }
        EXPECT(created == nil, "accepted and rejected settings do not leak without ARC exceptions");
    }
}

int main(void) {
    @autoreleasepool {
        TLTestRules();
        TLTestConfig();
        TLTestStateAndFiles();
        TLTestImages();
        TLTestWeb();
        TLTestWebFiles();
        TLTestRemoveFrame();
        TLTestEncodeAndUpload();
        TLTestRuntime();
        TLTestPhotoRequest();
        fprintf(stdout, "%d passed, %d failed\n", gPasses, gFailures);
        return gFailures == 0 ? 0 : 1;
    }
}
