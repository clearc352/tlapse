#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    NSInteger width;
    NSInteger height;
} TLPixelSize;

TLPixelSize TLPixelSizeMake(NSInteger width, NSInteger height);

typedef NS_ENUM(NSInteger, TLOrientationMode) {
    TLOrientationModeAuto = 0,
    TLOrientationModeRaw = 1,
    TLOrientationModePortrait = 2,
    TLOrientationModePortraitUpsideDown = 3,
    TLOrientationModeLandscapeHomeRight = 4,
    TLOrientationModeLandscapeHomeLeft = 5,
};

NSString *_Nullable TLSanitizeProjectID(NSString *projectID);
BOOL TLParseResolution(NSString *text, TLPixelSize *_Nullable outBox, BOOL *_Nullable outFull);
TLPixelSize TLOutputSize(TLPixelSize orientedImage, NSString *resolution);

NSInteger TLParseHHMM(NSString *text, BOOL *ok);
BOOL TLMinutesInWindow(NSInteger nowMinutes, NSInteger fromMinutes, NSInteger toMinutes);
NSInteger TLMinutesSinceMidnight(NSDate *date, NSTimeZone *timeZone);

TLOrientationMode TLOrientationModeFromString(NSString *_Nullable text, BOOL *ok);
NSString *TLOrientationModeString(TLOrientationMode mode);
int TLExifForOrientationMode(TLOrientationMode mode);
int TLExifForGravity(double x, double y, double z, BOOL *flat);

NSTimeInterval TLCaptureInitialDelay(void);
NSTimeInterval TLCaptureCatchUpDelay(void);
NSTimeInterval TLMinimumCaptureInterval(void);
NSTimeInterval TLNextCaptureDelay(NSDate *_Nullable lastAttempt, NSTimeInterval interval, NSDate *now);

NSString *TLFormatTimestamp(NSDate *date, NSTimeZone *timeZone);
NSDate *_Nullable TLParseTimestamp(NSString *text);
NSString *TLFormatFileDay(NSDate *date, NSTimeZone *timeZone);
NSString *TLFormatFileTime(NSDate *date, NSTimeZone *timeZone);
NSString *TLFrameRelativePath(NSString *projectID, NSDate *date, NSTimeZone *timeZone, BOOL thumbnail);

NSString *TLFormatBytes(unsigned long long bytes);
NSString *TLFormatGigabytes(double gigabytes);

BOOL TLSafePathComponent(NSString *component);
NSInteger TLEncodeStride(NSInteger frameCount, NSInteger fps, BOOL hasTargetDuration, double targetDuration);
TLPixelSize TLEncodeOutputSize(TLPixelSize image);
NSTimeInterval TLNextEncodeDelay(NSDate *_Nullable lastSuccess,
                                 NSDate *_Nullable lastAttempt,
                                 NSInteger everyDays,
                                 NSInteger atMinutes,
                                 NSDate *now,
                                 NSTimeZone *timeZone,
                                 NSDate *_Nullable *_Nullable slotOut);
NSTimeInterval TLUploadRetryDelay(NSInteger failedAttempts);
BOOL TLSecretConfigured(NSString *value);

NS_ASSUME_NONNULL_END
