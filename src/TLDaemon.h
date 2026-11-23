#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TLDaemon : NSObject
- (int)runWithConfigPath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
