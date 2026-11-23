#import <Foundation/Foundation.h>

#import "TLRules.h"

NS_ASSUME_NONNULL_BEGIN

@interface TLNightSkip : NSObject
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL hasTimeWindow;
@property (nonatomic, readonly) NSInteger fromMinutes;
@property (nonatomic, readonly) NSInteger toMinutes;
@property (nonatomic, readonly) double brightness;
- (BOOL)skipsTimeAtDate:(NSDate *)date timeZone:(NSTimeZone *)timeZone;
@end

@interface TLProject : NSObject
@property (nonatomic, readonly, copy) NSString *projectID;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) NSTimeInterval captureInterval;
@property (nonatomic, readonly, copy) NSString *resolution;
@property (nonatomic, readonly) BOOL lockFocus;
@property (nonatomic, readonly) BOOL lockExposure;
@property (nonatomic, readonly) BOOL lockWhiteBalance;
@property (nonatomic, readonly) double jpegQuality;
@property (nonatomic, readonly) BOOL shutterSound;
@property (nonatomic, readonly) NSTimeInterval settleSeconds;
@property (nonatomic, readonly) TLOrientationMode orientationMode;
@property (nonatomic, readonly, strong) TLNightSkip *nightSkip;
@property (nonatomic, readonly, copy) NSString *encodeEvery;
@property (nonatomic, readonly) NSInteger encodeEveryDays;
@property (nonatomic, readonly) NSInteger encodeAtMinutes;
@property (nonatomic, readonly, copy) NSString *encodeMode;
@property (nonatomic, readonly) NSInteger fps;
@property (nonatomic, readonly) BOOL hasTargetDuration;
@property (nonatomic, readonly) double targetDuration;
@property (nonatomic, readonly, copy) NSArray<NSString *> *uploadTargets;
@property (nonatomic, readonly) NSInteger keepFramesDays;
- (NSDictionary *)dictionaryRepresentation;
@end

@interface TLConfig : NSObject
@property (nonatomic, readonly) NSInteger serverPort;
@property (nonatomic, readonly, copy) NSString *serverToken;
@property (nonatomic, readonly, copy) NSString *storageRoot;
@property (nonatomic, readonly) double minFreeGB;
@property (nonatomic, readonly) BOOL telegramEnabled;
@property (nonatomic, readonly, copy) NSString *telegramBotToken;
@property (nonatomic, readonly, copy) NSString *telegramChatID;
@property (nonatomic, readonly) BOOL webdavEnabled;
@property (nonatomic, readonly, copy) NSString *webdavURL;
@property (nonatomic, readonly, copy) NSString *webdavUser;
@property (nonatomic, readonly, copy) NSString *webdavPassword;
@property (nonatomic, readonly, copy) NSArray<TLProject *> *projects;

+ (nullable instancetype)configWithContentsOfFile:(NSString *)path error:(NSError **)error;
+ (nullable instancetype)configWithDictionary:(NSDictionary *)dictionary error:(NSError **)error;
+ (BOOL)updateFileAtPath:(NSString *)path
                  mutate:(NS_NOESCAPE BOOL (^)(NSMutableDictionary *root, NSError **error))mutate
                   error:(NSError **)error;
- (NSDictionary *)dictionaryRepresentation;
- (nullable TLProject *)projectWithID:(NSString *)projectID;
- (NSInteger)enabledProjectCount;
@end

NS_ASSUME_NONNULL_END
