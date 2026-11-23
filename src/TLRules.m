#import "TLRules.h"

#import <math.h>

static NSDateFormatter *TLMakeFormatter(NSString *format, NSTimeZone *timeZone) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = timeZone ?: [NSTimeZone localTimeZone];
    formatter.dateFormat = format;
    return formatter;
}

static BOOL TLDigitsOnly(NSString *text) {
    if (text.length == 0) {
        return NO;
    }
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    return [text rangeOfCharacterFromSet:digits.invertedSet].location == NSNotFound;
}

static NSInteger TLEvenDimension(NSInteger value) {
    if (value < 2) {
        return 2;
    }
    return value & ~1;
}

TLPixelSize TLPixelSizeMake(NSInteger width, NSInteger height) {
    TLPixelSize size;
    size.width = width;
    size.height = height;
    return size;
}

NSString *TLSanitizeProjectID(NSString *projectID) {
    if (projectID.length == 0 || projectID.length > 64) {
        return nil;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    if ([projectID rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
        return nil;
    }
    unichar first = [projectID characterAtIndex:0];
    if (first == '-' || first == '_') {
        return nil;
    }
    return projectID;
}

BOOL TLParseResolution(NSString *text, TLPixelSize *outBox, BOOL *outFull) {
    NSString *normalized = [[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([normalized isEqualToString:@"full"] || [normalized isEqualToString:@"original"]) {
        if (outFull) {
            *outFull = YES;
        }
        return YES;
    }
    NSArray<NSString *> *parts = [normalized componentsSeparatedByString:@"x"];
    if (parts.count != 2 || !TLDigitsOnly(parts[0]) || !TLDigitsOnly(parts[1])) {
        return NO;
    }
    NSInteger width = parts[0].integerValue;
    NSInteger height = parts[1].integerValue;
    if (width < 2 || height < 2 || width > 20000 || height > 20000) {
        return NO;
    }
    if (outFull) {
        *outFull = NO;
    }
    if (outBox) {
        *outBox = TLPixelSizeMake(width, height);
    }
    return YES;
}

TLPixelSize TLOutputSize(TLPixelSize orientedImage, NSString *resolution) {
    TLPixelSize source = TLPixelSizeMake(TLEvenDimension(orientedImage.width), TLEvenDimension(orientedImage.height));
    BOOL full = NO;
    TLPixelSize box = TLPixelSizeMake(0, 0);
    if (!TLParseResolution(resolution, &box, &full) || full) {
        return source;
    }
    NSInteger imageLong = MAX(source.width, source.height);
    NSInteger imageShort = MIN(source.width, source.height);
    NSInteger boxLong = MAX(box.width, box.height);
    NSInteger boxShort = MIN(box.width, box.height);
    if (imageLong < 1 || imageShort < 1) {
        return source;
    }
    double scale = (double)boxLong / (double)imageLong;
    if ((double)imageShort * scale > (double)boxShort) {
        scale = (double)boxShort / (double)imageShort;
    }
    if (scale > 1.0) {
        scale = 1.0;
    }
    return TLPixelSizeMake(TLEvenDimension((NSInteger)llround(source.width * scale)),
                            TLEvenDimension((NSInteger)llround(source.height * scale)));
}

NSInteger TLParseHHMM(NSString *text, BOOL *ok) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@":"];
    if (parts.count != 2 || !TLDigitsOnly(parts[0]) || !TLDigitsOnly(parts[1])) {
        if (ok) {
            *ok = NO;
        }
        return 0;
    }
    NSInteger hour = parts[0].integerValue;
    NSInteger minute = parts[1].integerValue;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
        if (ok) {
            *ok = NO;
        }
        return 0;
    }
    if (ok) {
        *ok = YES;
    }
    return hour * 60 + minute;
}

BOOL TLMinutesInWindow(NSInteger nowMinutes, NSInteger fromMinutes, NSInteger toMinutes) {
    nowMinutes %= 24 * 60;
    if (nowMinutes < 0) {
        nowMinutes += 24 * 60;
    }
    if (fromMinutes == toMinutes) {
        return NO;
    }
    if (fromMinutes < toMinutes) {
        return nowMinutes >= fromMinutes && nowMinutes < toMinutes;
    }
    return nowMinutes >= fromMinutes || nowMinutes < toMinutes;
}

NSInteger TLMinutesSinceMidnight(NSDate *date, NSTimeZone *timeZone) {
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = timeZone ?: [NSTimeZone localTimeZone];
    NSDateComponents *parts = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
    return parts.hour * 60 + parts.minute;
}

TLOrientationMode TLOrientationModeFromString(NSString *text, BOOL *ok) {
    NSString *name = text.length > 0 ? text : @"auto";
    NSDictionary<NSString *, NSNumber *> *modes = @{
        @"auto": @(TLOrientationModeAuto),
        @"raw": @(TLOrientationModeRaw),
        @"portrait": @(TLOrientationModePortrait),
        @"portraitupsidedown": @(TLOrientationModePortraitUpsideDown),
        @"landscapehomeright": @(TLOrientationModeLandscapeHomeRight),
        @"landscapehomeleft": @(TLOrientationModeLandscapeHomeLeft),
    };
    NSNumber *value = modes[name.lowercaseString];
    if (!value) {
        if (ok) {
            *ok = NO;
        }
        return TLOrientationModeAuto;
    }
    if (ok) {
        *ok = YES;
    }
    return (TLOrientationMode)value.integerValue;
}

NSString *TLOrientationModeString(TLOrientationMode mode) {
    switch (mode) {
        case TLOrientationModeAuto:
            return @"auto";
        case TLOrientationModeRaw:
            return @"raw";
        case TLOrientationModePortrait:
            return @"portrait";
        case TLOrientationModePortraitUpsideDown:
            return @"portraitUpsideDown";
        case TLOrientationModeLandscapeHomeRight:
            return @"landscapeHomeRight";
        case TLOrientationModeLandscapeHomeLeft:
            return @"landscapeHomeLeft";
    }
    return @"auto";
}

int TLExifForOrientationMode(TLOrientationMode mode) {
    switch (mode) {
        case TLOrientationModePortrait:
            return 6;
        case TLOrientationModePortraitUpsideDown:
            return 8;
        case TLOrientationModeLandscapeHomeRight:
            return 1;
        case TLOrientationModeLandscapeHomeLeft:
            return 3;
        case TLOrientationModeAuto:
        case TLOrientationModeRaw:
            return 0;
    }
    return 0;
}

int TLExifForGravity(double x, double y, double z, BOOL *flat) {
    double magnitude = sqrt(x * x + y * y + z * z);
    if (magnitude < 0.5) {
        if (flat) {
            *flat = NO;
        }
        return 0;
    }
    if (fabs(z) > 0.85 && fabs(z) >= fabs(x) && fabs(z) >= fabs(y)) {
        if (flat) {
            *flat = YES;
        }
        return 6;
    }
    if (flat) {
        *flat = NO;
    }
    if (fabs(y) >= fabs(x)) {
        return y <= 0 ? 6 : 8;
    }
    return x > 0 ? 1 : 3;
}

NSTimeInterval TLCaptureInitialDelay(void) {
    return 5.0;
}

NSTimeInterval TLCaptureCatchUpDelay(void) {
    return 2.0;
}

NSTimeInterval TLMinimumCaptureInterval(void) {
    return 5.0;
}

NSTimeInterval TLNextCaptureDelay(NSDate *lastAttempt, NSTimeInterval interval, NSDate *now) {
    if (!lastAttempt) {
        return TLCaptureInitialDelay();
    }
    NSTimeInterval elapsed = [now timeIntervalSinceDate:lastAttempt];
    if (elapsed < 0) {
        elapsed = 0;
    }
    NSTimeInterval remaining = interval - elapsed;
    if (remaining > 1.0) {
        return remaining;
    }
    return TLCaptureCatchUpDelay();
}

NSString *TLFormatTimestamp(NSDate *date, NSTimeZone *timeZone) {
    return [TLMakeFormatter(@"yyyy-MM-dd'T'HH:mm:ssZ", timeZone) stringFromDate:date];
}

NSDate *TLParseTimestamp(NSString *text) {
    if (text.length == 0) {
        return nil;
    }
    return [TLMakeFormatter(@"yyyy-MM-dd'T'HH:mm:ssZ", [NSTimeZone localTimeZone]) dateFromString:text];
}

NSString *TLFormatFileDay(NSDate *date, NSTimeZone *timeZone) {
    return [TLMakeFormatter(@"yyyyMMdd", timeZone) stringFromDate:date];
}

NSString *TLFormatFileTime(NSDate *date, NSTimeZone *timeZone) {
    return [TLMakeFormatter(@"HHmmss", timeZone) stringFromDate:date];
}

NSString *TLFrameRelativePath(NSString *projectID, NSDate *date, NSTimeZone *timeZone, BOOL thumbnail) {
    NSString *kind = thumbnail ? @"thumbs" : @"frames";
    return [NSString stringWithFormat:@"projects/%@/%@/%@/%@.jpg",
            projectID,
            kind,
            TLFormatFileDay(date, timeZone),
            TLFormatFileTime(date, timeZone)];
}

NSString *TLFormatBytes(unsigned long long bytes) {
    if (bytes < 1024ull) {
        return [NSString stringWithFormat:@"%llu B", bytes];
    }
    if (bytes < 1024ull * 1024ull) {
        return [NSString stringWithFormat:@"%.1f KB", (double)bytes / 1024.0];
    }
    if (bytes < 1024ull * 1024ull * 1024ull) {
        return [NSString stringWithFormat:@"%.1f MB", (double)bytes / (1024.0 * 1024.0)];
    }
    return [NSString stringWithFormat:@"%.1f GB", (double)bytes / (1024.0 * 1024.0 * 1024.0)];
}

NSString *TLFormatGigabytes(double gigabytes) {
    return [NSString stringWithFormat:@"%.1f GB", gigabytes];
}

BOOL TLSafePathComponent(NSString *component) {
    if (component.length == 0 || component.length > 96) {
        return NO;
    }
    if ([component hasPrefix:@"."] || [component isEqualToString:@"."] || [component isEqualToString:@".."]) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
    return [component rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

NSInteger TLEncodeStride(NSInteger frameCount, NSInteger fps, BOOL hasTargetDuration, double targetDuration) {
    if (frameCount <= 1 || !hasTargetDuration || targetDuration <= 0 || fps <= 0) {
        return 1;
    }
    NSInteger desired = (NSInteger)llround(targetDuration * (double)fps);
    if (desired < 1) {
        desired = 1;
    }
    if (frameCount <= desired) {
        return 1;
    }
    return (frameCount + desired - 1) / desired;
}

TLPixelSize TLEncodeOutputSize(TLPixelSize image) {
    NSInteger width = image.width;
    NSInteger height = image.height;
    if (width < 2) {
        width = 2;
    }
    if (height < 2) {
        height = 2;
    }
    double longEdge = width > height ? (double)width : (double)height;
    if (longEdge > 1920.0) {
        double scale = 1920.0 / longEdge;
        width = (NSInteger)llround((double)width * scale);
        height = (NSInteger)llround((double)height * scale);
    }
    if (width % 2) {
        width -= 1;
    }
    if (height % 2) {
        height -= 1;
    }
    if (width < 2) {
        width = 2;
    }
    if (height < 2) {
        height = 2;
    }
    return TLPixelSizeMake(width, height);
}

static NSCalendar *TLEncodeCalendar(NSTimeZone *timeZone) {
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = timeZone ?: [NSTimeZone localTimeZone];
    return calendar;
}

static BOOL TLEncodeDayMatches(NSDate *day, NSInteger everyDays, NSCalendar *calendar) {
    if (everyDays <= 1) {
        return YES;
    }
    NSDateComponents *originParts = [[NSDateComponents alloc] init];
    originParts.year = 2020;
    originParts.month = 1;
    originParts.day = 1;
    NSDate *origin = [calendar dateFromComponents:originParts];
    NSDateComponents *diff = [calendar components:NSCalendarUnitDay fromDate:origin toDate:[calendar startOfDayForDate:day] options:0];
    NSInteger days = diff.day;
    NSInteger mod = days % everyDays;
    if (mod < 0) {
        mod += everyDays;
    }
    return mod == 0;
}

static NSDate *TLDateAtMinutes(NSDate *day, NSInteger minutes, NSCalendar *calendar) {
    NSDate *start = [calendar startOfDayForDate:day];
    return [calendar dateByAddingUnit:NSCalendarUnitMinute value:minutes toDate:start options:0];
}

NSTimeInterval TLNextEncodeDelay(NSDate *lastSuccess,
                                 NSDate *lastAttempt,
                                 NSInteger everyDays,
                                 NSInteger atMinutes,
                                 NSDate *now,
                                 NSTimeZone *timeZone,
                                 NSDate **slotOut) {
    if (everyDays < 1) {
        everyDays = 1;
    }
    if (atMinutes < 0 || atMinutes >= 24 * 60) {
        atMinutes = 23 * 60 + 30;
    }
    NSCalendar *calendar = TLEncodeCalendar(timeZone);
    NSDate *slot = nil;
    for (NSInteger back = 0; back <= everyDays; back++) {
        NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay value:-back toDate:now options:0];
        if (!TLEncodeDayMatches(day, everyDays, calendar)) {
            continue;
        }
        NSDate *candidate = TLDateAtMinutes(day, atMinutes, calendar);
        if ([candidate compare:now] != NSOrderedDescending) {
            slot = candidate;
            break;
        }
    }
    NSDate *next = nil;
    for (NSInteger forward = 0; forward <= everyDays + 1; forward++) {
        NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay value:forward toDate:now options:0];
        if (!TLEncodeDayMatches(day, everyDays, calendar)) {
            continue;
        }
        NSDate *candidate = TLDateAtMinutes(day, atMinutes, calendar);
        if ([candidate compare:now] == NSOrderedDescending) {
            next = candidate;
            break;
        }
    }
    if (slotOut) {
        *slotOut = slot;
    }
    if (!next) {
        next = [now dateByAddingTimeInterval:24 * 60 * 60];
    }
    BOOL slotDone = slot && lastSuccess && [lastSuccess compare:slot] != NSOrderedAscending;
    if (slot && !slotDone) {
        if (lastAttempt && [lastAttempt compare:slot] != NSOrderedAscending) {
            NSTimeInterval since = [now timeIntervalSinceDate:lastAttempt];
            if (since < 30 * 60) {
                NSTimeInterval remaining = 30 * 60 - since;
                return remaining < 1 ? 1 : remaining;
            }
        }
        return 15;
    }
    NSTimeInterval delay = [next timeIntervalSinceDate:now];
    return delay < 1 ? 1 : delay;
}

NSTimeInterval TLUploadRetryDelay(NSInteger failedAttempts) {
    static const NSTimeInterval delays[] = {30, 120, 480, 1800, 7200};
    NSInteger index = failedAttempts - 1;
    if (index < 0) {
        index = 0;
    }
    if (index > 4) {
        index = 4;
    }
    return delays[index];
}

BOOL TLSecretConfigured(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) {
        return NO;
    }
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || [trimmed hasPrefix:@"ENV:"]) {
        return NO;
    }
    NSCharacterSet *breaks = [NSCharacterSet newlineCharacterSet];
    return [trimmed rangeOfCharacterFromSet:breaks].location == NSNotFound;
}
