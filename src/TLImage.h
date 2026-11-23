#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TLEncodedImage : NSObject
@property (nonatomic, copy) NSData *jpeg;
@property (nonatomic, copy, nullable) NSData *thumbnail;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) double averageLuma;
@property (nonatomic) int sourceExif;
@property (nonatomic) int appliedExif;
@end

int TLJPEGExifOrientation(NSData *jpeg);
TLEncodedImage *_Nullable TLEncodeJPEG(NSData *source,
                                       NSString *resolution,
                                       double quality,
                                       int overrideExif,
                                       NSError **error);

NS_ASSUME_NONNULL_END
