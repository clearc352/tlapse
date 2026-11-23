#import "TLUploader.h"

#import "TLConfig.h"
#import "TLEncode.h"
#import "TLLog.h"
#import "TLRules.h"
#import "TLState.h"
#import "TLSupport.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static const unsigned long long TLTelegramByteLimit = 50ull * 1024ull * 1024ull;
static const NSInteger TLUploadAttemptLimit = 5;

static NSString *TLFormEscape(NSString *text) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [text stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

NSString *TLRedactSecret(NSString *text, NSString *secret) {
    if (text.length == 0 || secret.length == 0) {
        return text ?: @"";
    }
    return [text stringByReplacingOccurrencesOfString:secret withString:@"***"];
}

NSString *TLTelegramMethodURL(NSString *token, NSString *method) {
    if (!TLSecretConfigured(token) || [token rangeOfString:@"/"].location != NSNotFound || [token rangeOfString:@" "].location != NSNotFound) {
        return nil;
    }
    if (!TLSafePathComponent(method)) {
        return nil;
    }
    return [NSString stringWithFormat:@"https://api.telegram.org/bot%@/%@", token, method];
}

NSString *TLWebDAVFileURL(NSString *base, NSString *projectID, NSString *fileName) {
    if (base.length == 0 || ![base.lowercaseString hasPrefix:@"https://"]) {
        return nil;
    }
    if (!TLSafePathComponent(projectID) || !TLSafePathComponent(fileName)) {
        return nil;
    }
    NSString *trimmed = [base hasSuffix:@"/"] ? base : [base stringByAppendingString:@"/"];
    NSString *project = [projectID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: projectID;
    NSString *file = [fileName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: fileName;
    return [NSString stringWithFormat:@"%@%@/%@", trimmed, project, file];
}

static NSData *TLMultipartHeader(NSString *boundary, NSDictionary<NSString *, NSString *> *fields,
                                NSString *fileField, NSString *filename, NSString *mimeType) {
    NSMutableData *header = [NSMutableData data];
    for (NSString *key in [fields.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *part = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", boundary, key, fields[key] ?: @""];
        [header appendData:[part dataUsingEncoding:NSUTF8StringEncoding]];
    }
    NSString *part = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\nContent-Type: %@\r\n\r\n", boundary, fileField, filename, mimeType];
    [header appendData:[part dataUsingEncoding:NSUTF8StringEncoding]];
    return header;
}

static NSData *TLMultipartEnding(NSString *boundary) {
    return [[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding];
}

NSData *TLMultipartBody(NSString *boundary, NSDictionary<NSString *, NSString *> *fields,
                        NSString *fileField, NSString *filename, NSData *fileData, NSString *mimeType) {
    NSMutableData *body = [TLMultipartHeader(boundary, fields, fileField, filename, mimeType) mutableCopy];
    [body appendData:fileData];
    [body appendData:TLMultipartEnding(boundary)];
    return body;
}

// 临时请求体只由本次传输持有；正常返回、失败、取消和异常展开都释放磁盘文件。
@interface TLUploadBodyFile : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic) unsigned long long length;
- (void)cleanup;
@end
@implementation TLUploadBodyFile
- (void)cleanup {
    if (_path && unlink(_path.fileSystemRepresentation) != 0 && errno != ENOENT) {
        TLLogError(@"清理上传临时请求体失败：%s", strerror(errno));
    }
    _path = nil;
}
- (void)dealloc {
    [self cleanup];
}
@end

static BOOL TLWriteUploadBytes(int fd, const void *bytes, size_t length) {
    const unsigned char *cursor = bytes;
    while (length > 0) {
        ssize_t count = write(fd, cursor, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        cursor += count;
        length -= (size_t)count;
    }
    return YES;
}

static TLUploadBodyFile *TLCreateMultipartFile(NSString *path, NSString *boundary,
                                             NSDictionary<NSString *, NSString *> *fields, NSError **error) {
    int source = -1;
    int output = -1;
    TLUploadBodyFile *bodyFile = nil;
    BOOL built = NO;
    @try {
        source = open(path.fileSystemRepresentation, O_RDONLY | O_NONBLOCK);
        struct stat info;
        if (source < 0 || fstat(source, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 || (unsigned long long)info.st_size > TLTelegramByteLimit) {
            if (error) *error = TLError(TLErrorCodeStorage, @"无法读取视频或视频超过 50MiB");
            return nil;
        }
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tlapse-upload-XXXXXX"];
        NSMutableData *name = [[pattern dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [name increaseLengthBy:1];
        output = mkstemp(name.mutableBytes);
        if (output < 0) {
            if (error) *error = TLError(TLErrorCodeStorage, @"无法创建上传临时请求体");
            return nil;
        }
        bodyFile = [[TLUploadBodyFile alloc] init];
        bodyFile.path = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:name.bytes length:strlen(name.bytes)];
        NSData *header = TLMultipartHeader(boundary, fields, @"video", path.lastPathComponent, @"video/mp4");
        NSData *ending = TLMultipartEnding(boundary);
        BOOL ok = TLWriteUploadBytes(output, header.bytes, header.length);
        unsigned long long remaining = (unsigned long long)info.st_size;
        unsigned char buffer[64 * 1024];
        // 固定缓冲区，不随视频大小分配；同时拒绝读取期间截断/增长的源文件。
        while (ok && remaining > 0) {
            ssize_t count = read(source, buffer, (size_t)MIN(remaining, sizeof(buffer)));
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) { ok = NO; break; }
            ok = TLWriteUploadBytes(output, buffer, (size_t)count);
            remaining -= (unsigned long long)count;
        }
        ssize_t extra;
        do { extra = read(source, buffer, 1); } while (extra < 0 && errno == EINTR);
        ok = ok && remaining == 0 && extra == 0 && TLWriteUploadBytes(output, ending.bytes, ending.length);
        int closed = close(output);
        output = -1;
        if (!ok || closed != 0) {
            if (error) *error = TLError(TLErrorCodeStorage, @"构造上传请求体失败或视频在读取期间改变");
            return nil;
        }
        bodyFile.length = header.length + (unsigned long long)info.st_size + ending.length;
        built = YES;
        return bodyFile;
    } @finally {
        if (!built) [bodyFile cleanup];
        if (source >= 0) close(source);
        if (output >= 0) close(output);
    }
}

@interface TLRedirectGuard : NSObject <NSURLSessionTaskDelegate>
@end

@implementation TLRedirectGuard
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session;
    (void)task;
    (void)response;
    if (![request.URL.scheme.lowercaseString isEqualToString:@"https"]) {
        completionHandler(nil);
        return;
    }
    completionHandler(request);
}
@end

@implementation TLUploader {
    TLState *_state;
    NSString *_storageRoot;
    dispatch_queue_t _queue;
    void *_queueKey;
    NSURLSession *_session;
    TLRedirectGuard *_guard;
}

- (instancetype)initWithState:(TLState *)state storageRoot:(NSString *)storageRoot {
    self = [super init];
    if (self) {
        _state = state;
        _storageRoot = [storageRoot copy];
        _queueKey = &_queueKey;
        _queue = dispatch_queue_create("com.ddxyl.tlapsed.upload", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, _queueKey, _queueKey, NULL);
        _guard = [[TLRedirectGuard alloc] init];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 60;
        configuration.timeoutIntervalForResource = 180;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:_guard delegateQueue:nil];
    }
    return self;
}

- (void)sync:(dispatch_block_t)block {
    if (dispatch_get_specific(_queueKey) == _queueKey) {
        block();
    } else {
        dispatch_sync(_queue, block);
    }
}

- (void)updateStorageRoot:(NSString *)storageRoot {
    [self sync:^{
        self->_storageRoot = [storageRoot copy];
    }];
}

- (NSString *)queuePath {
    return [_storageRoot stringByAppendingPathComponent:@"logs/upload-queue.json"];
}

- (NSString *)uploadLogPath {
    return [_storageRoot stringByAppendingPathComponent:@"logs/uploads.log"];
}

- (void)appendUploadLog:(NSString *)message {
    NSString *path = [self uploadLogPath];
    TLEnsureDirectory(path.stringByDeletingLastPathComponent, nil);
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone localTimeZone];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [formatter stringFromDate:[NSDate date]], message ?: @""];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *exception) {
        TLLogError(@"写上传日志失败：%@", exception.name);
    } @finally {
        [handle closeFile];
    }
}

- (NSMutableArray<NSMutableDictionary *> *)loadJobs {
    NSData *data = [NSData dataWithContentsOfFile:[self queuePath]];
    id object = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    NSMutableArray *jobs = [NSMutableArray array];
    NSArray *stored = [object isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)object)[@"jobs"] : nil;
    if ([stored isKindOfClass:[NSArray class]]) {
        for (id item in stored) {
            if ([item isKindOfClass:[NSDictionary class]]) {
                [jobs addObject:[item mutableCopy]];
            }
        }
    }
    return jobs;
}

- (void)saveJobs:(NSArray *)jobs {
    NSString *path = [self queuePath];
    TLEnsureDirectory(path.stringByDeletingLastPathComponent, nil);
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"jobs": jobs ?: @[]} options:NSJSONWritingPrettyPrinted error:nil];
    if (data) {
        TLWriteDataAtomic(data, path, nil);
    }
}

- (NSDictionary *)daemonSnapshot {
    NSDictionary *snapshot = [_state snapshot];
    NSDictionary *daemon = [snapshot[@"daemon"] isKindOfClass:[NSDictionary class]] ? snapshot[@"daemon"] : @{};
    return daemon;
}

- (NSTimeInterval)requestTimeout {
    return 180;
}

- (BOOL)performRequest:(NSURLRequest *)request status:(NSInteger *)status body:(NSData **)bodyOut error:(NSError **)error {
    return [self performRequest:request fromFile:nil status:status body:bodyOut error:error];
}

- (BOOL)performRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL status:(NSInteger *)status body:(NSData **)bodyOut error:(NSError **)error {
    if (status) *status = 0;
    if (bodyOut) *bodyOut = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    __block NSURLResponse *response = nil;
    __block NSError *taskError = nil;
    NSMutableURLRequest *uploadRequest = [request mutableCopy];
    NSData *payload = uploadRequest.HTTPBody;
    uploadRequest.HTTPBody = nil;
    void (^completion)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *taskResponse, NSError *taskFailure) {
        body = data;
        response = taskResponse;
        taskError = taskFailure;
        dispatch_semaphore_signal(done);
    };
    NSURLSessionUploadTask *task = fileURL
        ? [_session uploadTaskWithRequest:uploadRequest fromFile:fileURL completionHandler:completion]
        : [_session uploadTaskWithRequest:uploadRequest fromData:payload completionHandler:completion];
    BOOL completed = NO;
    @try {
        [task resume];
        completed = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)([self requestTimeout] * NSEC_PER_SEC))) == 0;
        if (!completed) {
            if (error) *error = TLError(TLErrorCodeInternal, @"上传超时");
            return NO;
        }
    } @finally {
        if (!completed) [task cancel];
    }
    NSInteger code = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    if (status) {
        *status = code;
    }
    if (bodyOut) {
        *bodyOut = body;
    }
    if (taskError || code < 200 || code >= 300) {
        NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: taskError.localizedDescription ?: @"上传失败";
        if (error) {
            *error = TLError(TLErrorCodeInternal, text);
        }
        return NO;
    }
    return YES;
}

- (BOOL)telegramAccepted:(NSData *)body status:(NSInteger)status config:(TLConfig *)config retryable:(BOOL *)retryable error:(NSError **)error {
    id json = body.length > 0 ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
    if ([json isKindOfClass:[NSDictionary class]] && [json[@"ok"] boolValue]) {
        return YES;
    }
    NSInteger code = [json isKindOfClass:[NSDictionary class]] ? [json[@"error_code"] integerValue] : status;
    NSString *description = [json isKindOfClass:[NSDictionary class]] && [json[@"description"] isKindOfClass:[NSString class]] ? json[@"description"] : @"Telegram 拒绝了请求";
    if (retryable) {
        *retryable = code == 429 || code >= 500 || status == 0;
    }
    if (error) {
        *error = TLError(TLErrorCodeInternal, [self redactedMessage:description config:config]);
    }
    return NO;
}

- (BOOL)sendText:(NSString *)text config:(TLConfig *)config error:(NSError **)error {
    NSString *urlText = TLTelegramMethodURL(config.telegramBotToken, @"sendMessage");
    if (!config.telegramEnabled || urlText.length == 0 || !TLSecretConfigured(config.telegramChatID)) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, @"Telegram 没有启用或口令仍是占位符");
        }
        return NO;
    }
    NSString *form = [NSString stringWithFormat:@"chat_id=%@&text=%@", TLFormEscape(config.telegramChatID), TLFormEscape(text ?: @"")];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlText]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [form dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSInteger status = 0;
    NSData *responseBody = nil;
    NSError *requestError = nil;
    BOOL transported = [self performRequest:request status:&status body:&responseBody error:&requestError];
    BOOL retryable = NO;
    if (transported && [self telegramAccepted:responseBody status:status config:config retryable:&retryable error:&requestError]) {
        return YES;
    }
    if (error) {
        *error = TLError(TLErrorCodeInternal, [self redactedMessage:requestError.localizedDescription config:config]);
    }
    return NO;
}

- (BOOL)retryableStatus:(NSInteger)status error:(NSError *)error {
    if (error && status == 0) {
        return YES;
    }
    return status == 429 || status >= 500;
}

- (NSString *)uploadPath:(NSString *)path project:(TLProject *)project target:(NSString *)target config:(TLConfig *)config retryable:(BOOL *)retryable {
    if (retryable) {
        *retryable = NO;
    }
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes fileSize];
    NSString *fileName = path.lastPathComponent;
    if ([target isEqualToString:@"telegram"]) {
        if (!config.telegramEnabled) {
            return @"telegram 未启用";
        }
        if (!TLSecretConfigured(config.telegramBotToken) || !TLSecretConfigured(config.telegramChatID)) {
            return @"telegram 口令仍是占位符，没有读取环境变量";
        }
        if (size > TLTelegramByteLimit) {
            return @"telegram 跳过：视频超过 50MB";
        }
        NSString *urlText = TLTelegramMethodURL(config.telegramBotToken, @"sendVideo");
        if (urlText.length == 0) {
            return @"telegram 口令无法用于请求";
        }
        NSString *boundary = [NSUUID UUID].UUIDString;
        NSString *caption = [NSString stringWithFormat:@"%@ %@", project.name ?: project.projectID, fileName];
        NSError *error = nil;
        // 所有者的析构会 unlink，必须明确持有到同步传输（含取消）返回之后。
        __attribute__((objc_precise_lifetime)) TLUploadBodyFile *bodyFile = TLCreateMultipartFile(path, boundary, @{ @"chat_id": config.telegramChatID, @"caption": caption }, &error);
        if (!bodyFile) {
            return [NSString stringWithFormat:@"telegram 失败：%@", error.localizedDescription];
        }
        NSInteger status = 0;
        NSData *responseBody = nil;
        BOOL transported = NO;
        @try {
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlText]];
            request.HTTPMethod = @"POST";
            [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
            [request setValue:[NSString stringWithFormat:@"%llu", bodyFile.length] forHTTPHeaderField:@"Content-Length"];
            transported = [self performRequest:request fromFile:[NSURL fileURLWithPath:bodyFile.path] status:&status body:&responseBody error:&error];
        } @finally {
            // 不依赖 ARC 异常清理开关；异常继续向上抛出前也必须删除私密请求体。
            [bodyFile cleanup];
        }
        BOOL retry = NO;
        NSError *telegramError = nil;
        BOOL accepted = transported && [self telegramAccepted:responseBody status:status config:config retryable:&retry error:&telegramError];
        if (!accepted) {
            if (transported) {
                error = telegramError;
            } else {
                retry = [self retryableStatus:status error:error];
            }
            if (retryable) {
                *retryable = retry;
            }
            return [NSString stringWithFormat:@"telegram 失败：%@", [self redactedMessage:error.localizedDescription config:config]];
        }
        [_state updateProject:project.projectID values:@{TLStateLastUploadAt: TLFormatTimestamp([NSDate date], [NSTimeZone localTimeZone]), TLStateLastUploadError: @""} error:nil];
        [self appendUploadLog:[NSString stringWithFormat:@"%@ telegram %@ 成功", project.projectID, fileName]];
        TLLogInfo(@"%@：已上传到 Telegram %@", project.projectID, fileName);
        return @"telegram 已上传";
    }
    if ([target isEqualToString:@"webdav"]) {
        if (!config.webdavEnabled) {
            return @"webdav 未启用";
        }
        NSString *urlText = TLWebDAVFileURL(config.webdavURL, project.projectID, fileName);
        if (urlText.length == 0) {
            return @"webdav 需要 https 地址";
        }
        if ((config.webdavUser.length > 0 && !TLSecretConfigured(config.webdavUser)) || (config.webdavPassword.length > 0 && !TLSecretConfigured(config.webdavPassword))) {
            return @"webdav 口令仍是占位符，没有读取环境变量";
        }
        if (size > 200ull * 1024ull * 1024ull) {
            return @"webdav 跳过：视频超过 200MB";
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlText]];
        request.HTTPMethod = @"PUT";
        if (config.webdavUser.length > 0 || config.webdavPassword.length > 0) {
            NSString *pair = [NSString stringWithFormat:@"%@:%@", config.webdavUser ?: @"", config.webdavPassword ?: @""];
            NSString *basic = [[pair dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
            [request setValue:[@"Basic " stringByAppendingString:basic] forHTTPHeaderField:@"Authorization"];
        }
        [request setValue:@"video/mp4" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[NSString stringWithFormat:@"%llu", size] forHTTPHeaderField:@"Content-Length"];
        NSInteger status = 0;
        NSError *error = nil;
        BOOL ok = [self performRequest:request fromFile:[NSURL fileURLWithPath:path] status:&status body:NULL error:&error];
        if (!ok) {
            if (retryable) {
                *retryable = [self retryableStatus:status error:error];
            }
            return [NSString stringWithFormat:@"webdav 失败：%@", [self redactedMessage:error.localizedDescription config:config]];
        }
        [_state updateProject:project.projectID values:@{TLStateLastUploadAt: TLFormatTimestamp([NSDate date], [NSTimeZone localTimeZone]), TLStateLastUploadError: @""} error:nil];
        [self appendUploadLog:[NSString stringWithFormat:@"%@ webdav %@ 成功", project.projectID, fileName]];
        TLLogInfo(@"%@：已上传到 WebDAV %@", project.projectID, fileName);
        return @"webdav 已上传";
    }
    return [NSString stringWithFormat:@"%@ 不是支持的上传目标", target ?: @""];
}

- (NSString *)redactedMessage:(NSString *)message config:(TLConfig *)config {
    NSString *text = message ?: @"上传失败";
    NSMutableIndexSet *privateRanges = [NSMutableIndexSet indexSet];
    // 在原文中收集并合并所有凭据区间，避免先替换短凭据后留下长凭据的片段。
    for (NSString *secret in @[config.telegramBotToken ?: @"", config.telegramChatID ?: @"", config.webdavUser ?: @"", config.webdavPassword ?: @""]) {
        if (secret.length == 0) continue;
        NSUInteger start = 0;
        while (start < text.length) {
            NSRange match = [text rangeOfString:secret options:NSLiteralSearch range:NSMakeRange(start, text.length - start)];
            if (match.location == NSNotFound) break;
            [privateRanges addIndexesInRange:match];
            start = match.location + 1;
        }
    }
    NSMutableString *safe = [text mutableCopy];
    [privateRanges enumerateRangesWithOptions:NSEnumerationReverse usingBlock:^(NSRange range, BOOL *stop) {
        (void)stop;
        [safe replaceCharactersInRange:range withString:@"***"];
    }];
    // 必须先完整脱敏再截断，否则跨截断边界的凭据前缀会泄漏。
    return safe.length > 180 ? [safe substringToIndex:180] : safe;
}

- (NSString *)recordRetryFailure:(NSString *)projectID fileName:(NSString *)fileName target:(NSString *)target message:(NSString *)message config:(TLConfig *)config {
    NSString *safe = [self redactedMessage:message config:config];
    NSString *outcome = [self recordFailureOnQueue:projectID fileName:fileName target:target message:safe];
    if ([outcome isEqualToString:@"exhausted"]) {
        NSString *key = [NSString stringWithFormat:@"upload-%@-%@", projectID, target];
        NSString *alert = [NSString stringWithFormat:@"%@：%@ %@ 上传总共失败 5 次，已停止重试。%@", projectID, target, fileName, safe];
        // 告警沿用小文本通道，不重新进入视频上传/重试队列。
        [self sendAlertForKey:key message:alert cooldown:60 * 60 config:config];
    }
    return outcome;
}

- (void)recordPermanentFailure:(NSString *)projectID fileName:(NSString *)fileName target:(NSString *)target message:(NSString *)message config:(TLConfig *)config {
    NSString *safe = [self redactedMessage:message config:config];
    [self removeJobOnQueue:projectID fileName:fileName target:target];
    [_state updateProject:projectID values:@{TLStateLastUploadError: safe} error:nil];
    TLLogError(@"%@：%@", projectID, safe);
    [self appendUploadLog:[NSString stringWithFormat:@"%@：%@", projectID, safe]];
}

- (NSString *)recordFailureForProject:(NSString *)projectID fileName:(NSString *)fileName target:(NSString *)target message:(NSString *)message {
    __block NSString *outcome = @"queued";
    [self sync:^{
        outcome = [self recordFailureOnQueue:projectID fileName:fileName target:target message:message];
    }];
    return outcome;
}

- (NSString *)recordFailureOnQueue:(NSString *)projectID fileName:(NSString *)fileName target:(NSString *)target message:(NSString *)message {
    NSMutableArray *jobs = [self loadJobs];
    NSMutableDictionary *job = nil;
    for (NSMutableDictionary *existing in jobs) {
        if ([existing[@"project"] isEqualToString:projectID] && [existing[@"file"] isEqualToString:fileName] && [existing[@"target"] isEqualToString:target]) {
            job = existing;
            break;
        }
    }
    if (!job) {
        job = [NSMutableDictionary dictionary];
        job[@"project"] = projectID ?: @"";
        job[@"file"] = fileName ?: @"";
        job[@"target"] = target ?: @"";
        job[@"attempts"] = @0;
        [jobs addObject:job];
    }
    NSInteger attempts = [job[@"attempts"] integerValue] + 1;
    job[@"attempts"] = @(attempts);
    job[@"lastError"] = message ?: @"";
    if (attempts >= TLUploadAttemptLimit) {
        [jobs removeObject:job];
        [self saveJobs:jobs];
        NSString *line = [NSString stringWithFormat:@"%@：%@ 上传失败 %ld 次后停止。%@", projectID, target, (long)attempts, message ?: @""];
        TLLogError(@"%@", line);
        [self appendUploadLog:line];
        [_state updateProject:projectID values:@{TLStateLastUploadError: message ?: @"上传失败"} error:nil];
        return @"exhausted";
    }
    NSDate *next = [NSDate dateWithTimeIntervalSinceNow:TLUploadRetryDelay(attempts)];
    job[@"nextAt"] = TLFormatTimestamp(next, [NSTimeZone localTimeZone]);
    [self saveJobs:jobs];
    [_state updateProject:projectID values:@{TLStateLastUploadError: message ?: @"上传失败"} error:nil];
    return @"queued";
}

- (NSInteger)pendingCount {
    __block NSInteger count = 0;
    [self sync:^{
        count = (NSInteger)[self loadJobs].count;
    }];
    return count;
}

- (NSString *)uploadFileAtPath:(NSString *)path project:(TLProject *)project config:(TLConfig *)config {
    __block NSString *summary = @"";
    [self sync:^{
        summary = [self uploadOnQueue:path project:project config:config targets:project.uploadTargets];
    }];
    return summary;
}

- (NSString *)uploadOnQueue:(NSString *)path project:(TLProject *)project config:(TLConfig *)config targets:(NSArray<NSString *> *)targets {
    if (targets.count == 0) {
        return @"未配置上传目标";
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return @"视频文件不存在";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *fileName = path.lastPathComponent;
    for (NSString *target in targets) {
        BOOL retryable = NO;
        NSString *line = [self uploadPath:path project:project target:target config:config retryable:&retryable];
        if ([line containsString:@"失败"] && retryable) {
            NSString *outcome = [self recordRetryFailure:project.projectID fileName:fileName target:target message:line config:config];
            if ([outcome isEqualToString:@"queued"]) {
                line = [line stringByAppendingString:@"，已进入重试队列"];
            }
        } else if ([line containsString:@"失败"]) {
            [self recordPermanentFailure:project.projectID fileName:fileName target:target message:line config:config];
        } else {
            [self removeJobOnQueue:project.projectID fileName:fileName target:target];
        }
        [parts addObject:line ?: @"上传没有返回结果"];
    }
    return [parts componentsJoinedByString:@"；"];
}

- (void)removeJobOnQueue:(NSString *)projectID fileName:(NSString *)fileName target:(NSString *)target {
    NSMutableArray *jobs = [self loadJobs];
    NSIndexSet *indexes = [jobs indexesOfObjectsPassingTest:^BOOL(NSMutableDictionary *job, NSUInteger index, BOOL *stop) {
        (void)index;
        (void)stop;
        return [job[@"project"] isEqualToString:projectID] && [job[@"file"] isEqualToString:fileName] && [job[@"target"] isEqualToString:target];
    }];
    if (indexes.count == 0) {
        return;
    }
    [jobs removeObjectsAtIndexes:indexes];
    [self saveJobs:jobs];
}

- (void)drainWithConfig:(TLConfig *)config {
    [self sync:^{
        NSMutableArray *jobs = [self loadJobs];
        NSArray *snapshot = [jobs copy];
        NSDate *now = [NSDate date];
        for (NSDictionary *job in snapshot) {
            NSDate *next = TLParseTimestamp([job[@"nextAt"] isKindOfClass:[NSString class]] ? job[@"nextAt"] : @"");
            if (next && [next compare:now] == NSOrderedDescending) {
                continue;
            }
            NSString *projectID = [job[@"project"] isKindOfClass:[NSString class]] ? job[@"project"] : @"";
            NSString *fileName = [job[@"file"] isKindOfClass:[NSString class]] ? job[@"file"] : @"";
            NSString *target = [job[@"target"] isKindOfClass:[NSString class]] ? job[@"target"] : @"";
            TLProject *project = [config projectWithID:projectID];
            NSString *path = nil;
            if (project && TLSafePathComponent(fileName)) {
                path = [self->_storageRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"projects/%@/videos/%@", projectID, fileName]];
            }
            if (!project || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                [self removeJobOnQueue:projectID fileName:fileName target:target];
                TLLogError(@"%@：放弃上传 %@，视频或项目已经不在", projectID, fileName);
                continue;
            }
            BOOL retryable = NO;
            NSString *line = [self uploadPath:path project:project target:target config:config retryable:&retryable];
            if ([line containsString:@"失败"] && retryable) {
                [self recordRetryFailure:projectID fileName:fileName target:target message:line config:config];
            } else if ([line containsString:@"失败"]) {
                [self recordPermanentFailure:projectID fileName:fileName target:target message:line config:config];
            } else {
                [self removeJobOnQueue:projectID fileName:fileName target:target];
            }
        }
    }];
}

- (void)sendHeartbeatIfNeededWithConfig:(TLConfig *)config {
    [self sync:^{
        if (!config.telegramEnabled || !TLSecretConfigured(config.telegramBotToken) || !TLSecretConfigured(config.telegramChatID)) {
            return;
        }
        NSDate *now = [NSDate date];
        NSTimeZone *zone = [NSTimeZone localTimeZone];
        NSString *today = TLFormatFileDay(now, zone);
        NSDictionary *daemon = [self daemonSnapshot];
        if ([daemon[@"heartbeatDay"] isEqualToString:today]) {
            return;
        }
        NSDate *attemptAt = TLParseTimestamp([daemon[@"heartbeatAttemptAt"] isKindOfClass:[NSString class]] ? daemon[@"heartbeatAttemptAt"] : @"");
        if ([daemon[@"heartbeatAttemptDay"] isEqualToString:today] && attemptAt && -[attemptAt timeIntervalSinceNow] < 30 * 60) {
            return;
        }
        [self->_state updateDaemon:@{
            @"heartbeatAttemptDay": today,
            @"heartbeatAttemptAt": TLFormatTimestamp(now, zone),
        } error:nil];
        NSMutableArray<NSString *> *projectIDs = [NSMutableArray array];
        for (TLProject *project in config.projects) {
            [projectIDs addObject:project.projectID];
        }
        NSInteger frames = TLCountFramesOnDay(self->_storageRoot, projectIDs, today);
        double freeGB = TLFreeGigabytes(self->_storageRoot);
        NSString *freeText = freeGB >= 0 ? TLFormatGigabytes(freeGB) : @"未知";
        TLBatteryReading battery = TLReadBattery();
        NSString *heat = battery.valid && battery.hasTemperature ? [NSString stringWithFormat:@"，电池 %.1f°C", battery.celsius] : @"";
        NSString *text = [NSString stringWithFormat:@"tlapse 今日 %ld 张，剩余 %@%@", (long)frames, freeText, heat];
        NSError *error = nil;
        if ([self sendText:text config:config error:&error]) {
            [self->_state updateDaemon:@{@"heartbeatDay": today} error:nil];
            TLLogInfo(@"已发送每日心跳：%@", text);
            [self appendUploadLog:[@"心跳 " stringByAppendingString:text]];
        } else {
            TLLogError(@"每日心跳发送失败：%@", [self redactedMessage:error.localizedDescription config:config]);
        }
    }];
}

- (void)sendAlertForKey:(NSString *)key message:(NSString *)message cooldown:(NSTimeInterval)cooldown config:(TLConfig *)config {
    if (key.length == 0 || message.length == 0) {
        return;
    }
    [self sync:^{
        NSString *stateKey = [@"alert." stringByAppendingString:key];
        NSString *previous = [self daemonSnapshot][stateKey];
        NSDate *last = [previous isKindOfClass:[NSString class]] ? TLParseTimestamp(previous) : nil;
        if (last && -[last timeIntervalSinceNow] < cooldown) {
            return;
        }
        TLLogError(@"%@", message);
        [self->_state updateDaemon:@{stateKey: TLFormatTimestamp([NSDate date], [NSTimeZone localTimeZone])} error:nil];
        if (config.telegramEnabled && TLSecretConfigured(config.telegramBotToken) && TLSecretConfigured(config.telegramChatID)) {
            NSError *error = nil;
            if (![self sendText:message config:config error:&error]) {
                TLLogError(@"告警推送失败：%@", [self redactedMessage:error.localizedDescription config:config]);
            }
        }
    }];
}

@end
