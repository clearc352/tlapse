#import "TLEncode.h"

#import "TLRules.h"
#import "TLSupport.h"

@implementation TLEncodeResult
@end

static BOOL TLDayFolder(NSString *name) {
    if (name.length != 8 || !TLSafePathComponent(name)) {
        return NO;
    }
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    return [name rangeOfCharacterFromSet:digits.invertedSet].location == NSNotFound;
}

static NSString *TLProjectDirectory(NSString *root, NSString *projectID, NSString *kind) {
    if (!TLSafePathComponent(projectID)) {
        return nil;
    }
    return [root stringByAppendingPathComponent:[NSString stringWithFormat:@"projects/%@/%@", projectID, kind]];
}

NSArray<NSString *> *TLListFramePaths(NSString *root, NSString *projectID, NSString *day) {
    NSString *framesRoot = TLProjectDirectory(root, projectID, @"frames");
    if (framesRoot.length == 0) {
        return @[];
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSArray<NSString *> *days = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:framesRoot error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *folder in days) {
        if (!TLDayFolder(folder) || (day.length > 0 && ![folder isEqualToString:day])) {
            continue;
        }
        NSString *directory = [framesRoot stringByAppendingPathComponent:folder];
        NSArray<NSString *> *names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *name in names) {
            if (!TLSafePathComponent(name) || ![name.lowercaseString hasSuffix:@".jpg"]) {
                continue;
            }
            [paths addObject:[directory stringByAppendingPathComponent:name]];
        }
    }
    return paths;
}

NSArray<NSString *> *TLStridedFrames(NSArray<NSString *> *frames, NSInteger stride) {
    if (frames.count == 0) {
        return @[];
    }
    if (stride < 1) {
        stride = 1;
    }
    NSMutableArray<NSString *> *picked = [NSMutableArray array];
    for (NSInteger index = 0; index < (NSInteger)frames.count; index += stride) {
        [picked addObject:frames[(NSUInteger)index]];
    }
    if (picked.lastObject != frames.lastObject) {
        [picked addObject:frames.lastObject];
    }
    return picked;
}

NSString *TLVideoFileName(NSString *projectID, NSString *day, NSString *mode) {
    return [NSString stringWithFormat:@"%@_%@_%@.mp4", projectID, day, mode];
}

NSString *TLVideoRelativePath(NSString *projectID, NSString *day, NSString *mode) {
    return [NSString stringWithFormat:@"projects/%@/videos/%@", projectID, TLVideoFileName(projectID, day, mode)];
}

static NSInteger TLRemoveJPEGFiles(NSString *directory) {
    if (directory.length == 0) {
        return 0;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL exists = NO;
    BOOL isDirectory = NO;
    exists = [manager fileExistsAtPath:directory isDirectory:&isDirectory];
    if (!exists || !isDirectory) {
        return 0;
    }
    NSInteger removed = 0;
    for (NSString *name in [manager contentsOfDirectoryAtPath:directory error:nil]) {
        if (!TLSafePathComponent(name) || ![name.lowercaseString hasSuffix:@".jpg"]) {
            continue;
        }
        if ([manager removeItemAtPath:[directory stringByAppendingPathComponent:name] error:nil]) {
            removed += 1;
        }
    }
    NSArray *left = [manager contentsOfDirectoryAtPath:directory error:nil];
    if (left.count == 0) {
        [manager removeItemAtPath:directory error:nil];
    }
    return removed;
}

static BOOL TLRemoveOneJPEG(NSString *directory, NSString *name) {
    if (directory.length == 0 || !TLSafePathComponent(name) || ![name.lowercaseString hasSuffix:@".jpg"]) {
        return NO;
    }
    NSString *path = [directory stringByAppendingPathComponent:name];
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) {
        return NO;
    }
    if (![manager removeItemAtPath:path error:nil]) {
        return NO;
    }
    NSArray *left = [manager contentsOfDirectoryAtPath:directory error:nil];
    if (left.count == 0) {
        [manager removeItemAtPath:directory error:nil];
    }
    return YES;
}

NSInteger TLRemoveCapturedFrame(NSString *root, NSString *projectID, NSString *day, NSString *name) {
    if (!TLDayFolder(day)) {
        return 0;
    }
    NSInteger removed = 0;
    NSString *frames = [TLProjectDirectory(root, projectID, @"frames") stringByAppendingPathComponent:day];
    NSString *thumbs = [TLProjectDirectory(root, projectID, @"thumbs") stringByAppendingPathComponent:day];
    if (TLRemoveOneJPEG(frames, name)) {
        removed += 1;
    }
    if (TLRemoveOneJPEG(thumbs, name)) {
        removed += 1;
    }
    return removed;
}

NSInteger TLRemoveFrameDay(NSString *root, NSString *projectID, NSString *day) {
    if (!TLDayFolder(day)) {
        return 0;
    }
    NSInteger removed = 0;
    removed += TLRemoveJPEGFiles([TLProjectDirectory(root, projectID, @"frames") stringByAppendingPathComponent:day]);
    removed += TLRemoveJPEGFiles([TLProjectDirectory(root, projectID, @"thumbs") stringByAppendingPathComponent:day]);
    return removed;
}

static NSString *TLCutoffDay(NSDate *now, NSInteger keepDays, NSTimeZone *timeZone) {
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = timeZone ?: [NSTimeZone localTimeZone];
    NSDate *cutoff = [calendar dateByAddingUnit:NSCalendarUnitDay value:-keepDays toDate:now options:0];
    return TLFormatFileDay(cutoff ?: now, calendar.timeZone);
}

NSInteger TLCleanupExpiredFrames(NSString *root, NSString *projectID, NSInteger keepDays, NSDate *now, NSTimeZone *timeZone) {
    if (keepDays < 0) {
        return 0;
    }
    NSString *cutoff = TLCutoffDay(now ?: [NSDate date], keepDays, timeZone);
    NSString *framesRoot = TLProjectDirectory(root, projectID, @"frames");
    NSInteger removed = 0;
    for (NSString *day in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:framesRoot error:nil]) {
        if (!TLDayFolder(day) || [day compare:cutoff] != NSOrderedAscending) {
            continue;
        }
        removed += TLRemoveFrameDay(root, projectID, day);
    }
    return removed;
}

NSString *TLOldestDeletableDay(NSString *root, NSArray<NSString *> *projectIDs, NSString *today) {
    NSString *oldest = nil;
    for (NSString *projectID in projectIDs) {
        NSString *framesRoot = TLProjectDirectory(root, projectID, @"frames");
        for (NSString *day in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:framesRoot error:nil]) {
            if (!TLDayFolder(day) || [day isEqualToString:today]) {
                continue;
            }
            if (!oldest || [day compare:oldest] == NSOrderedAscending) {
                oldest = day;
            }
        }
    }
    return oldest;
}

NSInteger TLReclaimUploadedFrames(NSString *root, NSArray<NSString *> *projectIDs, NSSet<NSString *> *uploadedProjectIDs, NSString *today, double targetFreeGB) {
    if (targetFreeGB <= 0 || uploadedProjectIDs.count == 0) {
        return 0;
    }
    NSMutableArray<NSString *> *uploaded = [NSMutableArray array];
    for (NSString *projectID in projectIDs) {
        if ([uploadedProjectIDs containsObject:projectID]) {
            [uploaded addObject:projectID];
        }
    }
    NSInteger removed = 0;
    for (NSInteger pass = 0; pass < 64; pass++) {
        double freeGB = TLFreeGigabytes(root);
        if (freeGB < 0 || freeGB >= targetFreeGB) {
            break;
        }
        NSString *day = TLOldestDeletableDay(root, uploaded, today);
        if (day.length == 0) {
            break;
        }
        NSInteger passRemoved = 0;
        for (NSString *projectID in uploaded) {
            passRemoved += TLRemoveFrameDay(root, projectID, day);
        }
        if (passRemoved == 0) {
            break;
        }
        removed += passRemoved;
    }
    return removed;
}

NSInteger TLCountFramesOnDay(NSString *root, NSArray<NSString *> *projectIDs, NSString *day) {
    NSInteger count = 0;
    for (NSString *projectID in projectIDs) {
        count += (NSInteger)TLListFramePaths(root, projectID, day).count;
    }
    return count;
}
