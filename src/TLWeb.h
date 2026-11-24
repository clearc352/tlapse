#import <Foundation/Foundation.h>
#import <sys/socket.h>

#import "TLCapture.h"

@class TLConfig;
@class TLEncoder;
@class TLProject;
@class TLScheduler;
@class TLState;
@class TLUploader;

NS_ASSUME_NONNULL_BEGIN

BOOL TLWebTokenAcceptable(NSString *token);
BOOL TLWebConstantTimeEqual(NSString *left, NSString *right);
BOOL TLWebHostAllowed(NSString *hostHeader, NSArray<NSString *> *addresses, uint16_t port);
BOOL TLWebSocketAddressUsable(NSString *interfaceName, const struct sockaddr *address, BOOL loopbackOnly);
NSString *_Nullable TLWebSafePath(NSString *root, NSArray<NSString *> *components);

typedef TLCaptureResult *_Nullable (^TLWebSnap)(TLProject *project);

@interface TLWebServer : NSObject
- (instancetype)initWithConfigPath:(NSString *)path state:(TLState *)state snap:(TLWebSnap _Nullable)snap;
- (BOOL)applyConfig:(TLConfig *)config error:(NSError **)error;
- (BOOL)startLoopbackForTests:(TLConfig *)config error:(NSError **)error;
- (void)stop;
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly, copy) NSArray<NSString *> *listenAddresses;
@property (nonatomic, copy, nullable) NSString *indexFileOverride;
@property (nonatomic, strong, nullable) TLEncoder *encoder;
@property (nonatomic, weak, nullable) TLScheduler *scheduler;
@property (nonatomic, strong, nullable) TLUploader *uploader;
@end

NS_ASSUME_NONNULL_END
