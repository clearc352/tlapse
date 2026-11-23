#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void TLLogSetup(NSString *_Nullable filePath);
void TLLogInfo(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void TLLogError(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

NS_ASSUME_NONNULL_END
