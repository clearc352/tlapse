#import <Foundation/Foundation.h>

#import "TLLog.h"
#import "TLSupport.h"

#import <string.h>

NS_ASSUME_NONNULL_BEGIN

// 仅处理同步提交；submit 借用下方精确持有的设置，不能异步保存该参数。
// 回调、等待和摄像头生命周期仍由 TLCapture 管理。
static inline BOOL TLSubmitPhotoRequest(BOOL shutterSound,
                                       NSString *projectID,
                                       id (^makeSettings)(void),
                                       void (^submit)(__unsafe_unretained id settings),
                                       NSError ** _Nullable error) {
    __attribute__((objc_precise_lifetime)) id settings = nil;
    NSMethodSignature *signature = nil;
    NSInvocation *invocation = nil;
    @try {
        settings = makeSettings();
        if (!shutterSound) {
            SEL setter = NSSelectorFromString(@"setShutterSound:");
            signature = [settings respondsToSelector:setter]
                ? [settings methodSignatureForSelector:setter] : nil;
            if (signature.numberOfArguments != 3 || signature.methodReturnLength != 0 ||
                strcmp([signature getArgumentTypeAtIndex:2], @encode(unsigned int)) != 0) {
                if (error) {
                    *error = TLError(TLErrorCodeCamera, @"系统没有可用的静音拍摄设置，已拒绝有声拍摄");
                }
                return NO;
            }
            unsigned int silent = 0;
            invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.target = settings;
            invocation.selector = setter;
            [invocation setArgument:&silent atIndex:2];
            [invocation invoke];
        }
        submit(settings);
        if (!shutterSound) {
            TLLogInfo(@"%@：已提交静音拍摄请求", projectID);
        }
        return YES;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: @"拍照请求被拒绝";
        if (error) {
            *error = TLError(TLErrorCodeCamera, shutterSound ? reason :
                [NSString stringWithFormat:@"静音拍照失败，未回退有声：%@", reason]);
        }
        return NO;
    } @finally {
        // 不依赖 -fobjc-arc-exceptions，拒绝/异常路径也显式释放精确持有者。
        invocation.target = nil;
        invocation = nil;
        signature = nil;
        settings = nil;
    }
}

NS_ASSUME_NONNULL_END
