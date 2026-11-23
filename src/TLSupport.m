#import "TLSupport.h"

#import <math.h>

#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

#import <errno.h>
#import <fcntl.h>
#import <pwd.h>
#import <sys/file.h>
#import <unistd.h>

NSString *const TLErrorDomain = @"com.ddxyl.tlapsed";

NSError *TLError(TLErrorCode code, NSString *message) {
    return [NSError errorWithDomain:TLErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"未知错误"}];
}

TLBatteryReading TLReadBattery(void) {
    TLBatteryReading reading = {NO, 0, NO, NO, 0};
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) {
        return reading;
    }
    CFArrayRef list = IOPSCopyPowerSourcesList(blob);
    if (list) {
        CFIndex count = CFArrayGetCount(list);
        for (CFIndex index = 0; index < count; index++) {
            CFDictionaryRef description = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, index));
            if (!description) {
                continue;
            }
            NSDictionary *info = (__bridge NSDictionary *)description;
            NSNumber *current = info[@kIOPSCurrentCapacityKey];
            NSNumber *max = info[@kIOPSMaxCapacityKey];
            if (![current isKindOfClass:[NSNumber class]] || ![max isKindOfClass:[NSNumber class]] || max.doubleValue <= 0) {
                continue;
            }
            reading.valid = YES;
            reading.percent = (NSInteger)llround(current.doubleValue / max.doubleValue * 100.0);
            NSString *state = [info[@kIOPSPowerSourceStateKey] isKindOfClass:[NSString class]] ? info[@kIOPSPowerSourceStateKey] : @"";
            NSNumber *charging = info[@kIOPSIsChargingKey];
            reading.charging = [charging boolValue] || [state isEqualToString:@kIOPSACPowerValue];
            NSNumber *temperature = info[@"Temperature"];
            if ([temperature isKindOfClass:[NSNumber class]]) {
                double raw = temperature.doubleValue;
                double celsius = raw;
                if (raw >= 2500 && raw <= 4000) {
                    celsius = raw / 10.0 - 273.15;
                } else if (raw > 80 && raw <= 800) {
                    celsius = raw / 10.0;
                }
                if (celsius >= 0 && celsius <= 80) {
                    reading.hasTemperature = YES;
                    reading.celsius = round(celsius * 10.0) / 10.0;
                }
            }
            break;
        }
        CFRelease(list);
    }
    CFRelease(blob);
    return reading;
}

BOOL TLStorageRootAllowed(NSString *root) {
    if (root.length == 0 || ![root hasPrefix:@"/"]) {
        return NO;
    }
    NSString *standardized = root.stringByStandardizingPath;
    NSArray<NSString *> *bases = @[@"/var/mobile/", @"/private/var/mobile/"];
    for (NSString *base in bases) {
        if ([standardized hasPrefix:base] && standardized.length > base.length) {
            return YES;
        }
    }
    return NO;
}

BOOL TLEnsureDirectory(NSString *path, NSError **error) {
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([manager fileExistsAtPath:path]) {
        BOOL directory = NO;
        if ([manager fileExistsAtPath:path isDirectory:&directory] && directory) {
            return YES;
        }
        if (error) {
            *error = TLError(TLErrorCodeStorage, [NSString stringWithFormat:@"路径不是目录：%@", path]);
        }
        return NO;
    }
    return [manager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:error];
}

BOOL TLWriteDataAtomic(NSData *data, NSString *path, NSError **error) {
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (!TLEnsureDirectory(directory, error)) {
        return NO;
    }
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

NSString *TLUniqueFilePath(NSString *path) {
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:path]) {
        return path;
    }
    NSString *directory = path.stringByDeletingLastPathComponent;
    NSString *base = path.lastPathComponent.stringByDeletingPathExtension;
    NSString *extension = path.pathExtension;
    for (NSInteger index = 2; index < 1000; index++) {
        NSString *name = extension.length > 0
            ? [NSString stringWithFormat:@"%@_%ld.%@", base, (long)index, extension]
            : [NSString stringWithFormat:@"%@_%ld", base, (long)index];
        NSString *candidate = [directory stringByAppendingPathComponent:name];
        if (![manager fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return path;
}

double TLFreeGigabytes(NSString *path) {
    NSError *error = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:path error:&error];
    if (!attributes) {
        return -1;
    }
    unsigned long long freeBytes = [attributes[NSFileSystemFreeSize] unsignedLongLongValue];
    return (double)freeBytes / (1024.0 * 1024.0 * 1024.0);
}

static BOOL TLChownTree(NSString *root, uid_t uid, gid_t gid, NSError **error) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:root];
    NSDirectoryEnumerator *enumerator = [manager enumeratorAtPath:root];
    for (NSString *relative in enumerator) {
        [paths addObject:[root stringByAppendingPathComponent:relative]];
    }
    for (NSString *path in paths) {
        if (chown(path.fileSystemRepresentation, uid, gid) != 0) {
            if (error) {
                *error = TLError(TLErrorCodeStorage, [NSString stringWithFormat:@"无法把 %@ 交给 mobile：%s", path, strerror(errno)]);
            }
            return NO;
        }
    }
    return YES;
}

BOOL TLDropToMobileUser(NSString *storageRoot, NSError **error) {
    NSString *logs = [storageRoot stringByAppendingPathComponent:@"logs"];
    NSString *projects = [storageRoot stringByAppendingPathComponent:@"projects"];
    if (!TLEnsureDirectory(logs, error) || !TLEnsureDirectory(projects, error)) {
        return NO;
    }
    if (geteuid() != 0) {
        return YES;
    }
    struct passwd *mobile = getpwnam("mobile");
    if (!mobile) {
        fprintf(stderr, "找不到 mobile 用户，继续以 root 运行。\n");
        return YES;
    }
    if (!TLChownTree(storageRoot, mobile->pw_uid, mobile->pw_gid, error)) {
        return NO;
    }
    if (setgid(mobile->pw_gid) != 0 || setuid(mobile->pw_uid) != 0) {
        if (error) {
            *error = TLError(TLErrorCodeInternal, [NSString stringWithFormat:@"切换到 mobile 失败：%s", strerror(errno)]);
        }
        return NO;
    }
    return YES;
}

@implementation TLFileLock {
    int _fd;
    BOOL _held;
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        NSString *directory = path.stringByDeletingLastPathComponent;
        if (directory.length > 0) {
            [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        }
        _fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR, 0644);
    }
    return self;
}

- (void)dealloc {
    [self unlock];
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
}

- (BOOL)lockWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (_fd < 0) {
        if (error) {
            *error = TLError(TLErrorCodeStorage, @"无法创建锁文件");
        }
        return NO;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (YES) {
        if (flock(_fd, LOCK_EX | LOCK_NB) == 0) {
            _held = YES;
            return YES;
        }
        if (errno != EWOULDBLOCK && errno != EAGAIN) {
            if (error) {
                *error = TLError(TLErrorCodeStorage, [NSString stringWithFormat:@"文件锁失败：%s", strerror(errno)]);
            }
            return NO;
        }
        if (timeout >= 0 && [deadline timeIntervalSinceNow] <= 0) {
            if (error) {
                *error = TLError(TLErrorCodeBusy, @"等待文件锁超时");
            }
            return NO;
        }
        [NSThread sleepForTimeInterval:0.05];
    }
}

- (void)unlock {
    if (_held && _fd >= 0) {
        flock(_fd, LOCK_UN);
        _held = NO;
    }
}

@end
