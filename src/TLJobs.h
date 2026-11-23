#import <Foundation/Foundation.h>

@class TLConfig;
@class TLEncoder;
@class TLEncodeResult;
@class TLProject;
@class TLState;
@class TLUploader;

NS_ASSUME_NONNULL_BEGIN

TLEncodeResult *TLPerformEncodeJob(TLEncoder *encoder,
                                  TLUploader *_Nullable uploader,
                                  TLState *_Nullable state,
                                  TLConfig *config,
                                  TLProject *project,
                                  NSDate *_Nullable date,
                                  NSTimeZone *_Nullable timeZone);

NS_ASSUME_NONNULL_END
