#import <Foundation/Foundation.h>

@class TLProject;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TLCaptureOutcome) {
    TLCaptureOutcomeSaved = 0,
    TLCaptureOutcomeSkippedNight,
    TLCaptureOutcomeSkippedDark,
    TLCaptureOutcomeSkippedStorage,
    TLCaptureOutcomeFailed,
};

@interface TLCaptureResult : NSObject
@property (nonatomic) TLCaptureOutcome outcome;
@property (nonatomic, copy, nullable) NSString *message;
@property (nonatomic, copy, nullable) NSString *relativePath;
@property (nonatomic, copy, nullable) NSString *absolutePath;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) unsigned long long bytes;
@property (nonatomic) double averageLuma;
@property (nonatomic) int sourceExif;
@property (nonatomic) int appliedExif;
@property (nonatomic, copy, nullable) NSDate *capturedAt;
@end

@interface TLCapture : NSObject
- (TLCaptureResult *)captureProject:(TLProject *)project
                         storageRoot:(NSString *)storageRoot
                           minFreeGB:(double)minFreeGB
                              manual:(BOOL)manual
                     willOpenCamera:(void (^ _Nullable)(void))willOpenCamera;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
