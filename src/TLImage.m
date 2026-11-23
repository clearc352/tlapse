#import "TLImage.h"

#import "TLRules.h"
#import "TLSupport.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

static NSData *TLJPEGData(CGImageRef image, double quality) {
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
    if (!destination) {
        return nil;
    }
    NSDictionary *properties = @{
        (id)kCGImageDestinationLossyCompressionQuality: @(quality),
        (id)kCGImagePropertyOrientation: @1,
    };
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    BOOL ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return ok ? data : nil;
}

static CGImageRef TLEvenImage(CGImageRef image) CF_RETURNS_RETAINED {
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    size_t evenWidth = width & ~1u;
    size_t evenHeight = height & ~1u;
    if (evenWidth == width && evenHeight == height) {
        CGImageRetain(image);
        return image;
    }
    if (evenWidth < 2) {
        evenWidth = width;
    }
    if (evenHeight < 2) {
        evenHeight = height;
    }
    CGRect crop = CGRectMake(0, 0, evenWidth, evenHeight);
    return CGImageCreateWithImageInRect(image, crop);
}

static NSData *TLThumbnailJPEG(CGImageRef image) {
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (width < 2 || height < 2) {
        return nil;
    }
    double scale = 1.0;
    size_t longEdge = width > height ? width : height;
    if (longEdge > 320) {
        scale = 320.0 / (double)longEdge;
    }
    size_t thumbWidth = (size_t)llround((double)width * scale) & ~1u;
    size_t thumbHeight = (size_t)llround((double)height * scale) & ~1u;
    if (thumbWidth < 2) {
        thumbWidth = 2;
    }
    if (thumbHeight < 2) {
        thumbHeight = 2;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, thumbWidth, thumbHeight, 8, thumbWidth * 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        return nil;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, thumbWidth, thumbHeight), image);
    CGImageRef thumb = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!thumb) {
        return nil;
    }
    NSData *jpeg = TLJPEGData(thumb, 0.7);
    CGImageRelease(thumb);
    return jpeg;
}

static double TLAverageLuma(CGImageRef image) {
    const size_t width = 32;
    const size_t height = 24;
    unsigned char *buffer = calloc(width * height * 4, 1);
    if (!buffer) {
        return 0;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(buffer, width, height, 8, width * 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(buffer);
        return 0;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    double sum = 0;
    NSUInteger count = width * height;
    for (NSUInteger index = 0; index < count; index++) {
        double red = buffer[index * 4] / 255.0;
        double green = buffer[index * 4 + 1] / 255.0;
        double blue = buffer[index * 4 + 2] / 255.0;
        sum += 0.2126 * red + 0.7152 * green + 0.0722 * blue;
    }
    CGContextRelease(context);
    free(buffer);
    return sum / (double)count;
}

static NSData *TLRewriteOrientation(CGImageSourceRef source, int exif, NSError **error) {
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
    if (!destination) {
        if (error) {
            *error = TLError(TLErrorCodeInternal, @"无法改写照片方向");
        }
        return nil;
    }
    NSDictionary *metadata = @{
        (id)kCGImagePropertyOrientation: @(exif),
        (id)kCGImageDestinationLossyCompressionQuality: @1.0,
    };
    CGImageDestinationAddImageFromSource(destination, source, 0, (__bridge CFDictionaryRef)metadata);
    BOOL ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    if (!ok) {
        if (error) {
            *error = TLError(TLErrorCodeInternal, @"无法改写照片方向");
        }
        return nil;
    }
    return data;
}

static int TLOrientationFromProperties(NSDictionary *properties) {
    NSNumber *orientation = properties[(id)kCGImagePropertyOrientation];
    if (![orientation isKindOfClass:[NSNumber class]]) {
        NSDictionary *tiff = properties[(id)kCGImagePropertyTIFFDictionary];
        if ([tiff isKindOfClass:[NSDictionary class]]) {
            orientation = tiff[(id)kCGImagePropertyOrientation];
        }
    }
    int value = [orientation intValue];
    if (value < 1 || value > 8) {
        return 1;
    }
    return value;
}

int TLJPEGExifOrientation(NSData *jpeg) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (!source) {
        return 1;
    }
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    return TLOrientationFromProperties(properties);
}

TLEncodedImage *TLEncodeJPEG(NSData *sourceData, NSString *resolution, double quality, int overrideExif, NSError **error) {
    if (quality < 0.1) {
        quality = 0.1;
    } else if (quality > 1.0) {
        quality = 1.0;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)sourceData, NULL);
    if (!source) {
        if (error) {
            *error = TLError(TLErrorCodeInternal, @"无法读取照片数据");
        }
        return nil;
    }
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    int sourceExif = TLOrientationFromProperties(properties);
    int appliedExif = (overrideExif >= 1 && overrideExif <= 8) ? overrideExif : sourceExif;
    NSInteger pixelWidth = [properties[(id)kCGImagePropertyPixelWidth] integerValue];
    NSInteger pixelHeight = [properties[(id)kCGImagePropertyPixelHeight] integerValue];
    if (pixelWidth < 2 || pixelHeight < 2) {
        CFRelease(source);
        if (error) {
            *error = TLError(TLErrorCodeInternal, @"照片尺寸无效");
        }
        return nil;
    }
    NSInteger displayWidth = appliedExif >= 5 ? pixelHeight : pixelWidth;
    NSInteger displayHeight = appliedExif >= 5 ? pixelWidth : pixelHeight;
    TLPixelSize output = TLOutputSize(TLPixelSizeMake(displayWidth, displayHeight), resolution);
    NSInteger maxPixel = MAX(output.width, output.height);

    CGImageSourceRef orientedSource = source;
    if (appliedExif != sourceExif) {
        NSData *rewritten = TLRewriteOrientation(source, appliedExif, error);
        CFRelease(source);
        source = NULL;
        if (!rewritten) {
            return nil;
        }
        orientedSource = CGImageSourceCreateWithData((__bridge CFDataRef)rewritten, NULL);
        if (!orientedSource) {
            if (error) {
                *error = TLError(TLErrorCodeInternal, @"无法读取调整方向后的照片");
            }
            return nil;
        }
    }

    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixel),
        (id)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(orientedSource, 0, (__bridge CFDictionaryRef)options);
    CFRelease(orientedSource);
    if (!image) {
        if (error) {
            *error = TLError(TLErrorCodeInternal, @"无法缩放照片");
        }
        return nil;
    }
    CGImageRef evenImage = TLEvenImage(image);
    CGImageRelease(image);
    if (!evenImage) {
        if (error) {
            *error = TLError(TLErrorCodeInternal, @"无法整理照片尺寸");
        }
        return nil;
    }

    NSData *jpeg = TLJPEGData(evenImage, quality);
    NSData *thumbnail = TLThumbnailJPEG(evenImage);
    double luma = TLAverageLuma(evenImage);
    NSInteger width = (NSInteger)CGImageGetWidth(evenImage);
    NSInteger height = (NSInteger)CGImageGetHeight(evenImage);
    CGImageRelease(evenImage);
    if (!jpeg) {
        if (error) {
            *error = TLError(TLErrorCodeInternal, @"无法编码 JPEG");
        }
        return nil;
    }

    TLEncodedImage *encoded = [[TLEncodedImage alloc] init];
    encoded.jpeg = jpeg;
    encoded.thumbnail = thumbnail;
    encoded.width = width;
    encoded.height = height;
    encoded.averageLuma = luma;
    encoded.sourceExif = sourceExif;
    encoded.appliedExif = appliedExif;
    return encoded;
}

@implementation TLEncodedImage
@end
