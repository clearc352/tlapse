#import <Foundation/Foundation.h>

@class TLConfig;
@class TLProject;
@class TLState;

NS_ASSUME_NONNULL_BEGIN

NSString *_Nullable TLTelegramMethodURL(NSString *token, NSString *method);
NSString *_Nullable TLWebDAVFileURL(NSString *base, NSString *projectID, NSString *fileName);
NSString *TLRedactSecret(NSString *text, NSString *secret);
NSData *TLMultipartBody(NSString *boundary,
                        NSDictionary<NSString *, NSString *> *fields,
                        NSString *fileField,
                        NSString *filename,
                        NSData *fileData,
                        NSString *mimeType);

@interface TLUploader : NSObject
- (instancetype)initWithState:(TLState *)state storageRoot:(NSString *)storageRoot;
- (void)updateStorageRoot:(NSString *)storageRoot;
- (NSString *)uploadFileAtPath:(NSString *)path project:(TLProject *)project config:(TLConfig *)config;
- (void)drainWithConfig:(TLConfig *)config;
- (void)sendHeartbeatIfNeededWithConfig:(TLConfig *)config;
- (void)sendAlertForKey:(NSString *)key message:(NSString *)message cooldown:(NSTimeInterval)cooldown config:(TLConfig *)config;
- (NSString *)recordFailureForProject:(NSString *)projectID fileName:(NSString *)fileName target:(NSString *)target message:(NSString *)message;
- (NSInteger)pendingCount;
@end

NS_ASSUME_NONNULL_END
