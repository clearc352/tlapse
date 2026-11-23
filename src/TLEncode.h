#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TLEncodeResult : NSObject
@property (nonatomic) BOOL succeeded;
@property (nonatomic) BOOL empty;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy, nullable) NSString *relativePath;
@property (nonatomic, copy, nullable) NSString *absolutePath;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) NSInteger frameCount;
@property (nonatomic) NSInteger sourceCount;
@property (nonatomic) NSInteger stride;
@property (nonatomic) NSInteger removedFrames;
@property (nonatomic) unsigned long long bytes;
@end

NSArray<NSString *> *TLListFramePaths(NSString *root, NSString *projectID, NSString *_Nullable day);
NSArray<NSString *> *TLStridedFrames(NSArray<NSString *> *frames, NSInteger stride);
NSString *TLVideoFileName(NSString *projectID, NSString *day, NSString *mode);
NSString *TLVideoRelativePath(NSString *projectID, NSString *day, NSString *mode);
NSInteger TLCleanupExpiredFrames(NSString *root, NSString *projectID, NSInteger keepDays, NSDate *now, NSTimeZone *timeZone);
NSInteger TLReclaimUploadedFrames(NSString *root, NSArray<NSString *> *projectIDs, NSSet<NSString *> *uploadedProjectIDs, NSString *today, double targetFreeGB);
NSInteger TLCountFramesOnDay(NSString *root, NSArray<NSString *> *projectIDs, NSString *day);
NSString *_Nullable TLOldestDeletableDay(NSString *root, NSArray<NSString *> *projectIDs, NSString *today);
NSInteger TLRemoveFrameDay(NSString *root, NSString *projectID, NSString *day);
NSInteger TLRemoveCapturedFrame(NSString *root, NSString *projectID, NSString *day, NSString *name);

NS_ASSUME_NONNULL_END
