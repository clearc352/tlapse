#import <Foundation/Foundation.h>

#import "TLEncode.h"

@class TLProject;

NS_ASSUME_NONNULL_BEGIN

@interface TLEncoder : NSObject
- (TLEncodeResult *)encodeProject:(TLProject *)project
                       storageRoot:(NSString *)storageRoot
                              date:(NSDate *)date
                          timeZone:(NSTimeZone *)timeZone;
@end

NS_ASSUME_NONNULL_END
