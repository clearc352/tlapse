#import <Foundation/Foundation.h>

@class TLConfig;
@class TLEncoder;
@class TLProject;
@class TLState;
@class TLUploader;
@class TLCaptureResult;

NS_ASSUME_NONNULL_BEGIN

typedef TLCaptureResult * _Nonnull (^TLScheduledCapture)(TLProject *project, void (^ _Nullable willOpenCamera)(void));

@interface TLScheduler : NSObject
- (instancetype)initWithState:(TLState *)state
                  cameraQueue:(dispatch_queue_t)cameraQueue
                      capture:(TLScheduledCapture)capture
                      encoder:(TLEncoder *_Nullable)encoder
                     uploader:(TLUploader *_Nullable)uploader;
- (void)applyConfig:(TLConfig *)config;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
