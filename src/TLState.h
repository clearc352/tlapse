#import <Foundation/Foundation.h>

@class TLCaptureResult;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TLStateLastAttemptAt;
extern NSString *const TLStateLastCaptureAt;
extern NSString *const TLStateFrameCount;
extern NSString *const TLStateLastFile;
extern NSString *const TLStateLastError;
extern NSString *const TLStateConsecutiveFailures;
extern NSString *const TLStateLastEncodeAt;
extern NSString *const TLStateLastEncodeAttemptAt;
extern NSString *const TLStateLastEncodeFile;
extern NSString *const TLStateLastEncodeError;
extern NSString *const TLStateLastUploadAt;
extern NSString *const TLStateLastUploadError;

@interface TLState : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (NSDictionary *)snapshot;
- (nullable NSDate *)dateForProject:(NSString *)projectID key:(NSString *)key;
- (NSInteger)integerForProject:(NSString *)projectID key:(NSString *)key;
- (nullable NSString *)stringForProject:(NSString *)projectID key:(NSString *)key;
- (BOOL)updateProject:(NSString *)projectID values:(NSDictionary *)values error:(NSError **)error;
- (BOOL)updateDaemon:(NSDictionary *)values error:(NSError **)error;
- (NSInteger)recordCaptureResult:(TLCaptureResult *)result projectID:(NSString *)projectID;
@end

NS_ASSUME_NONNULL_END
