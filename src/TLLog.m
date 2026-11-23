#import "TLLog.h"

#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <unistd.h>

static dispatch_queue_t TLLogQueue;
static int TLLogFD = -1;

static dispatch_queue_t TLSharedLogQueue(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        TLLogQueue = dispatch_queue_create("com.ddxyl.tlapsed.log", DISPATCH_QUEUE_SERIAL);
    });
    return TLLogQueue;
}

static void TLTrimLogIfNeeded(NSString *path) {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes fileSize];
    const unsigned long long limit = 2ull * 1024ull * 1024ull;
    const unsigned long long keep = 256ull * 1024ull;
    if (size < limit || size <= keep) {
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        return;
    }
    @try {
        [handle seekToFileOffset:size - keep];
        NSData *tail = [handle readDataToEndOfFile];
        NSData *newline = [NSData dataWithBytes:"\n" length:1];
        NSRange firstNewline = [tail rangeOfData:newline options:0 range:NSMakeRange(0, tail.length)];
        if (firstNewline.location != NSNotFound && NSMaxRange(firstNewline) < tail.length) {
            tail = [tail subdataWithRange:NSMakeRange(NSMaxRange(firstNewline), tail.length - NSMaxRange(firstNewline))];
        }
        [tail writeToFile:path atomically:YES];
    } @catch (NSException *exception) {
        (void)exception;
    }
}

void TLLogSetup(NSString *filePath) {
    dispatch_sync(TLSharedLogQueue(), ^{
        if (TLLogFD >= 0) {
            close(TLLogFD);
            TLLogFD = -1;
        }
        if (filePath.length == 0) {
            return;
        }
        NSString *directory = filePath.stringByDeletingLastPathComponent;
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        TLTrimLogIfNeeded(filePath);
        TLLogFD = open(filePath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    });
}

static void TLWriteAll(int fd, const char *bytes, size_t length) {
    size_t written = 0;
    while (written < length) {
        ssize_t count = write(fd, bytes + written, length - written);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return;
        }
        written += (size_t)count;
    }
}

static void TLLogLine(NSString *level, NSString *message) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone localTimeZone];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n", [formatter stringFromDate:[NSDate date]], level, message];
    fputs(line.UTF8String, stderr);
    fflush(stderr);
    dispatch_sync(TLSharedLogQueue(), ^{
        if (TLLogFD >= 0) {
            TLWriteAll(TLLogFD, line.UTF8String, strlen(line.UTF8String));
        }
    });
}

static void TLLogFormat(NSString *level, NSString *format, va_list args) {
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    TLLogLine(level, message);
}

void TLLogInfo(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    TLLogFormat(@"info", format, args);
    va_end(args);
}

void TLLogError(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    TLLogFormat(@"error", format, args);
    va_end(args);
}
