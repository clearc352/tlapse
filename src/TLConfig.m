#import "TLConfig.h"

#import "TLSupport.h"
#import "TLVersion.h"

#import <sys/stat.h>

static NSSet<NSString *> *TLKeySet(NSArray<NSString *> *keys) {
    return [NSSet setWithArray:keys];
}

static BOOL TLUnknownKeys(NSDictionary *dictionary, NSSet<NSString *> *allowed, NSString *path, NSError **error) {
    for (NSString *key in dictionary) {
        if (![allowed containsObject:key]) {
            if (error) {
                *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@ 含有未知字段 %@", path, key]);
            }
            return NO;
        }
    }
    return YES;
}

static BOOL TLDictionary(id value, NSString *path, NSDictionary **outDictionary, NSError **error) {
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@ 必须是对象", path]);
        }
        return NO;
    }
    *outDictionary = value;
    return YES;
}

static BOOL TLOptionalBool(NSDictionary *dictionary, NSString *key, BOOL fallback, NSString *path, BOOL *outValue, NSError **error) {
    id value = dictionary[key];
    if (!value) {
        *outValue = fallback;
        return YES;
    }
    if (![value isKindOfClass:[NSNumber class]]) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.%@ 必须是布尔值", path, key]);
        }
        return NO;
    }
    *outValue = [value boolValue];
    return YES;
}

static BOOL TLOptionalString(NSDictionary *dictionary, NSString *key, NSString *fallback, NSString *path, NSString **outValue, NSError **error) {
    id value = dictionary[key];
    if (!value) {
        *outValue = fallback;
        return YES;
    }
    if (![value isKindOfClass:[NSString class]]) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.%@ 必须是字符串", path, key]);
        }
        return NO;
    }
    *outValue = value;
    return YES;
}

static BOOL TLOptionalNumber(NSDictionary *dictionary, NSString *key, NSString *path, NSNumber **outValue, NSError **error) {
    id value = dictionary[key];
    if (!value) {
        *outValue = nil;
        return YES;
    }
    if (![value isKindOfClass:[NSNumber class]]) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.%@ 必须是数字", path, key]);
        }
        return NO;
    }
    *outValue = value;
    return YES;
}

static BOOL TLSecretPresent(NSString *value) {
    if (value.length == 0) {
        return NO;
    }
    if ([value hasPrefix:@"ENV:"]) {
        return value.length > 4;
    }
    return YES;
}

@implementation TLNightSkip

- (instancetype)initWithEnabled:(BOOL)enabled
                  hasTimeWindow:(BOOL)hasTimeWindow
                    fromMinutes:(NSInteger)fromMinutes
                      toMinutes:(NSInteger)toMinutes
                     brightness:(double)brightness {
    self = [super init];
    if (self) {
        _enabled = enabled;
        _hasTimeWindow = hasTimeWindow;
        _fromMinutes = fromMinutes;
        _toMinutes = toMinutes;
        _brightness = brightness;
    }
    return self;
}

- (BOOL)skipsTimeAtDate:(NSDate *)date timeZone:(NSTimeZone *)timeZone {
    if (!self.enabled || !self.hasTimeWindow) {
        return NO;
    }
    return TLMinutesInWindow(TLMinutesSinceMidnight(date, timeZone), self.fromMinutes, self.toMinutes);
}

@end

@implementation TLProject

- (instancetype)initWithProjectID:(NSString *)projectID
                             name:(NSString *)name
                          enabled:(BOOL)enabled
                 captureInterval:(NSTimeInterval)captureInterval
                      resolution:(NSString *)resolution
                       lockFocus:(BOOL)lockFocus
                    lockExposure:(BOOL)lockExposure
                lockWhiteBalance:(BOOL)lockWhiteBalance
                     jpegQuality:(double)jpegQuality
                    shutterSound:(BOOL)shutterSound
                   settleSeconds:(NSTimeInterval)settleSeconds
                 orientationMode:(TLOrientationMode)orientationMode
                       nightSkip:(TLNightSkip *)nightSkip
                     encodeEvery:(NSString *)encodeEvery
                encodeEveryDays:(NSInteger)encodeEveryDays
                encodeAtMinutes:(NSInteger)encodeAtMinutes
                      encodeMode:(NSString *)encodeMode
                             fps:(NSInteger)fps
               hasTargetDuration:(BOOL)hasTargetDuration
                targetDuration:(double)targetDuration
                  uploadTargets:(NSArray<NSString *> *)uploadTargets
                 keepFramesDays:(NSInteger)keepFramesDays {
    self = [super init];
    if (self) {
        _projectID = [projectID copy];
        _name = [name copy];
        _enabled = enabled;
        _captureInterval = captureInterval;
        _resolution = [resolution copy];
        _lockFocus = lockFocus;
        _lockExposure = lockExposure;
        _lockWhiteBalance = lockWhiteBalance;
        _jpegQuality = jpegQuality;
        _shutterSound = shutterSound;
        _settleSeconds = settleSeconds;
        _orientationMode = orientationMode;
        _nightSkip = nightSkip;
        _encodeEvery = [encodeEvery copy];
        _encodeEveryDays = encodeEveryDays;
        _encodeAtMinutes = encodeAtMinutes;
        _encodeMode = [encodeMode copy];
        _fps = fps;
        _hasTargetDuration = hasTargetDuration;
        _targetDuration = targetDuration;
        _uploadTargets = [uploadTargets copy];
        _keepFramesDays = keepFramesDays;
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    id every = ([self.encodeEvery isEqualToString:@"daily"] || [self.encodeEvery isEqualToString:@"weekly"])
        ? self.encodeEvery
        : @(self.encodeEveryDays);
    NSMutableDictionary *encode = [@{
        @"every": every,
        @"at": [NSString stringWithFormat:@"%02ld:%02ld", (long)(self.encodeAtMinutes / 60), (long)(self.encodeAtMinutes % 60)],
        @"mode": self.encodeMode,
        @"fps": @(self.fps),
    } mutableCopy];
    if (self.hasTargetDuration) {
        encode[@"targetDuration"] = @(self.targetDuration);
    }
    id nightSkip = @NO;
    if (self.nightSkip.enabled && self.nightSkip.hasTimeWindow && self.nightSkip.brightness == 0 &&
        self.nightSkip.fromMinutes == 22 * 60 && self.nightSkip.toMinutes == 6 * 60) {
        nightSkip = @YES;
    } else if (self.nightSkip.enabled || self.nightSkip.hasTimeWindow || self.nightSkip.brightness > 0) {
        NSMutableDictionary *night = [NSMutableDictionary dictionary];
        night[@"enabled"] = @(self.nightSkip.enabled);
        if (self.nightSkip.hasTimeWindow) {
            night[@"from"] = [NSString stringWithFormat:@"%02ld:%02ld", (long)(self.nightSkip.fromMinutes / 60), (long)(self.nightSkip.fromMinutes % 60)];
            night[@"to"] = [NSString stringWithFormat:@"%02ld:%02ld", (long)(self.nightSkip.toMinutes / 60), (long)(self.nightSkip.toMinutes % 60)];
        }
        if (self.nightSkip.brightness > 0) {
            night[@"brightness"] = @(self.nightSkip.brightness);
        }
        nightSkip = night;
    }
    return @{
        @"id": self.projectID,
        @"name": self.name,
        @"enabled": @(self.enabled),
        @"capture": @{
            @"interval": @(self.captureInterval),
            @"resolution": self.resolution,
            @"lockFocus": @(self.lockFocus),
            @"lockExposure": @(self.lockExposure),
            @"lockWhiteBalance": @(self.lockWhiteBalance),
            @"jpegQuality": @(self.jpegQuality),
            @"shutterSound": @(self.shutterSound),
            @"settleSeconds": @(self.settleSeconds),
            @"orientation": TLOrientationModeString(self.orientationMode),
            @"nightSkip": nightSkip,
        },
        @"encode": encode,
        @"upload": self.uploadTargets ?: @[],
        @"cleanup": @{@"keepFramesDays": @(self.keepFramesDays)},
    };
}

@end

@implementation TLConfig

+ (instancetype)configWithContentsOfFile:(NSString *)path error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) {
        if (error && !*error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"无法读取配置：%@", path]);
        } else if (error && (*error).localizedDescription.length > 0) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"无法读取配置：%@", (*error).localizedDescription]);
        }
        return nil;
    }
    NSError *parseError = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, parseError.localizedDescription ?: @"配置不是 JSON 对象");
        }
        return nil;
    }
    return [self configWithDictionary:json error:error];
}

+ (instancetype)configWithDictionary:(NSDictionary *)dictionary error:(NSError **)error {
    if (!TLUnknownKeys(dictionary,
                       TLKeySet(@[@"server", @"storage", @"uploads", @"projects"]),
                       @"配置",
                       error)) {
        return nil;
    }
    TLConfig *config = [[TLConfig alloc] init];
    if (![config loadDictionary:dictionary error:error]) {
        return nil;
    }
    return config;
}

- (BOOL)loadDictionary:(NSDictionary *)dictionary error:(NSError **)error {
    NSDictionary *server = nil;
    id serverValue = dictionary[@"server"] ?: @{};
    if (!TLDictionary(serverValue, @"server", &server, error)) {
        return NO;
    }
    if (!TLUnknownKeys(server, TLKeySet(@[@"port", @"token"]), @"server", error)) {
        return NO;
    }
    NSNumber *portNumber = nil;
    if (!TLOptionalNumber(server, @"port", @"server", &portNumber, error)) {
        return NO;
    }
    _serverPort = portNumber ? portNumber.integerValue : 8080;
    if (_serverPort < 1 || _serverPort > 65535) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, @"server.port 必须在 1 到 65535 之间");
        }
        return NO;
    }
    NSString *token = nil;
    if (!TLOptionalString(server, @"token", @"change-me", @"server", &token, error)) {
        return NO;
    }
    _serverToken = token;

    NSDictionary *storage = nil;
    id storageValue = dictionary[@"storage"] ?: @{};
    if (!TLDictionary(storageValue, @"storage", &storage, error)) {
        return NO;
    }
    if (!TLUnknownKeys(storage, TLKeySet(@[@"root", @"minFreeGB"]), @"storage", error)) {
        return NO;
    }
    NSString *root = nil;
    if (!TLOptionalString(storage, @"root", TLDefaultStorageRoot, @"storage", &root, error)) {
        return NO;
    }
    if (!TLStorageRootAllowed(root)) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, @"storage.root 必须位于 /var/mobile/ 下面");
        }
        return NO;
    }
    _storageRoot = root.stringByStandardizingPath;
    NSNumber *minFree = nil;
    if (!TLOptionalNumber(storage, @"minFreeGB", @"storage", &minFree, error)) {
        return NO;
    }
    _minFreeGB = minFree ? minFree.doubleValue : 5.0;
    if (_minFreeGB < 0 || _minFreeGB > 1024) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, @"storage.minFreeGB 必须在 0 到 1024 之间");
        }
        return NO;
    }

    if (![self loadUploads:dictionary[@"uploads"] ?: @{} error:error]) {
        return NO;
    }
    return [self loadProjects:dictionary[@"projects"] ?: @[] error:error];
}

- (BOOL)loadUploads:(id)value error:(NSError **)error {
    NSDictionary *uploads = nil;
    if (!TLDictionary(value, @"uploads", &uploads, error)) {
        return NO;
    }
    if (!TLUnknownKeys(uploads, TLKeySet(@[@"telegram", @"webdav"]), @"uploads", error)) {
        return NO;
    }
    NSDictionary *telegram = nil;
    id telegramValue = uploads[@"telegram"] ?: @{};
    if (!TLDictionary(telegramValue, @"uploads.telegram", &telegram, error)) {
        return NO;
    }
    if (!TLUnknownKeys(telegram, TLKeySet(@[@"enabled", @"botToken", @"chatId"]), @"uploads.telegram", error)) {
        return NO;
    }
    BOOL telegramEnabled = NO;
    NSString *botToken = nil;
    NSString *chatID = nil;
    if (!TLOptionalBool(telegram, @"enabled", NO, @"uploads.telegram", &telegramEnabled, error) ||
        !TLOptionalString(telegram, @"botToken", @"", @"uploads.telegram", &botToken, error) ||
        !TLOptionalString(telegram, @"chatId", @"", @"uploads.telegram", &chatID, error)) {
        return NO;
    }
    if (telegramEnabled && (!TLSecretPresent(botToken) || !TLSecretPresent(chatID))) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, @"启用 Telegram 时必须填写 botToken 和 chatId");
        }
        return NO;
    }
    _telegramEnabled = telegramEnabled;
    _telegramBotToken = botToken;
    _telegramChatID = chatID;

    NSDictionary *webdav = nil;
    id webdavValue = uploads[@"webdav"] ?: @{};
    if (!TLDictionary(webdavValue, @"uploads.webdav", &webdav, error)) {
        return NO;
    }
    if (!TLUnknownKeys(webdav, TLKeySet(@[@"enabled", @"url", @"user", @"password"]), @"uploads.webdav", error)) {
        return NO;
    }
    BOOL webdavEnabled = NO;
    NSString *url = nil;
    NSString *user = nil;
    NSString *password = nil;
    if (!TLOptionalBool(webdav, @"enabled", NO, @"uploads.webdav", &webdavEnabled, error) ||
        !TLOptionalString(webdav, @"url", @"", @"uploads.webdav", &url, error) ||
        !TLOptionalString(webdav, @"user", @"", @"uploads.webdav", &user, error) ||
        !TLOptionalString(webdav, @"password", @"", @"uploads.webdav", &password, error)) {
        return NO;
    }
    if (webdavEnabled && !TLSecretPresent(url)) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, @"启用 WebDAV 时必须填写 url");
        }
        return NO;
    }
    _webdavEnabled = webdavEnabled;
    _webdavURL = url;
    _webdavUser = user;
    _webdavPassword = password;
    return YES;
}

- (BOOL)loadProjects:(id)value error:(NSError **)error {
    if (![value isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, @"projects 必须是数组");
        }
        return NO;
    }
    NSMutableArray<TLProject *> *projects = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSUInteger index = 0;
    for (id entry in (NSArray *)value) {
        NSString *path = [NSString stringWithFormat:@"projects[%lu]", (unsigned long)index];
        NSDictionary *dictionary = nil;
        if (!TLDictionary(entry, path, &dictionary, error)) {
            return NO;
        }
        TLProject *project = [self projectFromDictionary:dictionary path:path error:error];
        if (!project) {
            return NO;
        }
        if ([seen containsObject:project.projectID]) {
            if (error) {
                *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"项目 id 重复：%@", project.projectID]);
            }
            return NO;
        }
        [seen addObject:project.projectID];
        [projects addObject:project];
        index += 1;
    }
    _projects = [projects copy];
    return YES;
}

- (TLProject *)projectFromDictionary:(NSDictionary *)dictionary path:(NSString *)path error:(NSError **)error {
    if (!TLUnknownKeys(dictionary,
                       TLKeySet(@[@"id", @"name", @"enabled", @"capture", @"encode", @"upload", @"cleanup"]),
                       path,
                       error)) {
        return nil;
    }
    NSString *projectID = nil;
    NSString *name = nil;
    if (!TLOptionalString(dictionary, @"id", @"", path, &projectID, error) ||
        !TLOptionalString(dictionary, @"name", @"", path, &name, error)) {
        return nil;
    }
    projectID = TLSanitizeProjectID(projectID);
    if (!projectID) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.id 只能包含字母、数字、下划线和减号", path]);
        }
        return nil;
    }
    if (name.length == 0 || name.length > 80) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.name 不能为空，且不超过 80 个字符", path]);
        }
        return nil;
    }
    BOOL enabled = NO;
    if (!TLOptionalBool(dictionary, @"enabled", NO, path, &enabled, error)) {
        return nil;
    }

    NSDictionary *capture = nil;
    id captureValue = dictionary[@"capture"] ?: @{};
    if (!TLDictionary(captureValue, [path stringByAppendingString:@".capture"], &capture, error)) {
        return nil;
    }
    NSString *capturePath = [path stringByAppendingString:@".capture"];
    if (!TLUnknownKeys(capture,
                       TLKeySet(@[@"interval", @"resolution", @"lockFocus", @"lockExposure", @"lockWhiteBalance", @"jpegQuality", @"shutterSound", @"settleSeconds", @"orientation", @"nightSkip"]),
                       capturePath,
                       error)) {
        return nil;
    }
    NSNumber *intervalNumber = nil;
    NSString *resolution = nil;
    BOOL lockFocus = YES;
    BOOL lockExposure = YES;
    BOOL lockWhiteBalance = YES;
    NSNumber *qualityNumber = nil;
    BOOL shutterSound = YES;
    NSNumber *settleNumber = nil;
    NSString *orientationName = nil;
    if (!TLOptionalNumber(capture, @"interval", capturePath, &intervalNumber, error) ||
        !TLOptionalString(capture, @"resolution", @"1920x1440", capturePath, &resolution, error) ||
        !TLOptionalBool(capture, @"lockFocus", YES, capturePath, &lockFocus, error) ||
        !TLOptionalBool(capture, @"lockExposure", YES, capturePath, &lockExposure, error) ||
        !TLOptionalBool(capture, @"lockWhiteBalance", YES, capturePath, &lockWhiteBalance, error) ||
        !TLOptionalNumber(capture, @"jpegQuality", capturePath, &qualityNumber, error) ||
        !TLOptionalBool(capture, @"shutterSound", YES, capturePath, &shutterSound, error) ||
        !TLOptionalNumber(capture, @"settleSeconds", capturePath, &settleNumber, error) ||
        !TLOptionalString(capture, @"orientation", @"auto", capturePath, &orientationName, error)) {
        return nil;
    }
    NSTimeInterval interval = intervalNumber ? intervalNumber.doubleValue : 300;
    if (interval < TLMinimumCaptureInterval() || interval > 24 * 60 * 60) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.interval 必须在 5 到 86400 秒之间", capturePath]);
        }
        return nil;
    }
    if (!TLParseResolution(resolution, NULL, NULL)) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.resolution 必须是 full 或 宽x高", capturePath]);
        }
        return nil;
    }
    double quality = qualityNumber ? qualityNumber.doubleValue : 0.85;
    if (quality < 0.1 || quality > 1.0) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.jpegQuality 必须在 0.1 到 1 之间", capturePath]);
        }
        return nil;
    }
    NSTimeInterval settle = settleNumber ? settleNumber.doubleValue : 1.5;
    if (settle < 0.3 || settle > 5.0) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.settleSeconds 必须在 0.3 到 5 之间", capturePath]);
        }
        return nil;
    }
    BOOL orientationOK = NO;
    TLOrientationMode orientation = TLOrientationModeFromString(orientationName, &orientationOK);
    if (!orientationOK) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.orientation 不支持 %@", capturePath, orientationName]);
        }
        return nil;
    }
    TLNightSkip *nightSkip = [self nightSkipFromValue:capture[@"nightSkip"] path:capturePath error:error];
    if (!nightSkip) {
        return nil;
    }

    NSDictionary *encode = nil;
    id encodeValue = dictionary[@"encode"] ?: @{};
    NSString *encodePath = [path stringByAppendingString:@".encode"];
    if (!TLDictionary(encodeValue, encodePath, &encode, error)) {
        return nil;
    }
    if (!TLUnknownKeys(encode,
                       TLKeySet(@[@"every", @"at", @"mode", @"fps", @"targetDuration"]),
                       encodePath,
                       error)) {
        return nil;
    }
    id everyValue = encode[@"every"] ?: @"daily";
    NSString *encodeEvery = nil;
    NSInteger encodeEveryDays = 0;
    if ([everyValue isKindOfClass:[NSString class]]) {
        encodeEvery = everyValue;
        if ([encodeEvery isEqualToString:@"daily"]) {
            encodeEveryDays = 1;
        } else if ([encodeEvery isEqualToString:@"weekly"]) {
            encodeEveryDays = 7;
        } else {
            if (error) {
                *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.every 只支持 daily、weekly 或天数", encodePath]);
            }
            return nil;
        }
    } else if ([everyValue isKindOfClass:[NSNumber class]]) {
        encodeEveryDays = [everyValue integerValue];
        if (encodeEveryDays < 1 || encodeEveryDays > 366) {
            if (error) {
                *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.every 天数必须在 1 到 366 之间", encodePath]);
            }
            return nil;
        }
        encodeEvery = [NSString stringWithFormat:@"%ldd", (long)encodeEveryDays];
    } else {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.every 必须是字符串或数字", encodePath]);
        }
        return nil;
    }
    NSString *atText = nil;
    NSString *mode = nil;
    NSNumber *fpsNumber = nil;
    NSNumber *durationNumber = nil;
    if (!TLOptionalString(encode, @"at", @"23:30", encodePath, &atText, error) ||
        !TLOptionalString(encode, @"mode", @"daily", encodePath, &mode, error) ||
        !TLOptionalNumber(encode, @"fps", encodePath, &fpsNumber, error) ||
        !TLOptionalNumber(encode, @"targetDuration", encodePath, &durationNumber, error)) {
        return nil;
    }
    BOOL atOK = NO;
    NSInteger atMinutes = TLParseHHMM(atText, &atOK);
    if (!atOK) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.at 必须是 HH:MM", encodePath]);
        }
        return nil;
    }
    if (![mode isEqualToString:@"daily"] && ![mode isEqualToString:@"cumulative"]) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.mode 只支持 daily 或 cumulative", encodePath]);
        }
        return nil;
    }
    NSInteger fps = fpsNumber ? fpsNumber.integerValue : 30;
    if (fps != 24 && fps != 30 && fps != 60) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.fps 只支持 24、30 或 60", encodePath]);
        }
        return nil;
    }
    BOOL hasDuration = durationNumber != nil;
    double duration = durationNumber.doubleValue;
    if (hasDuration && (duration <= 0 || duration > 600)) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.targetDuration 必须在 0 到 600 秒之间", encodePath]);
        }
        return nil;
    }

    id uploadValue = dictionary[@"upload"] ?: @[];
    if (![uploadValue isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.upload 必须是数组", path]);
        }
        return nil;
    }
    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    for (id target in (NSArray *)uploadValue) {
        if (![target isKindOfClass:[NSString class]] ||
            !([target isEqualToString:@"telegram"] || [target isEqualToString:@"webdav"])) {
            if (error) {
                *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.upload 只支持 telegram 和 webdav", path]);
            }
            return nil;
        }
        if (![targets containsObject:target]) {
            [targets addObject:target];
        }
    }

    NSDictionary *cleanup = nil;
    id cleanupValue = dictionary[@"cleanup"] ?: @{};
    NSString *cleanupPath = [path stringByAppendingString:@".cleanup"];
    if (!TLDictionary(cleanupValue, cleanupPath, &cleanup, error)) {
        return nil;
    }
    if (!TLUnknownKeys(cleanup, TLKeySet(@[@"keepFramesDays"]), cleanupPath, error)) {
        return nil;
    }
    NSNumber *keepNumber = nil;
    if (!TLOptionalNumber(cleanup, @"keepFramesDays", cleanupPath, &keepNumber, error)) {
        return nil;
    }
    NSInteger keepDays = keepNumber ? keepNumber.integerValue : 14;
    if (keepDays < 0 || keepDays > 3650) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.keepFramesDays 必须在 0 到 3650 之间", cleanupPath]);
        }
        return nil;
    }

    return [[TLProject alloc] initWithProjectID:projectID
                                           name:name
                                        enabled:enabled
                               captureInterval:interval
                                    resolution:resolution
                                     lockFocus:lockFocus
                                  lockExposure:lockExposure
                              lockWhiteBalance:lockWhiteBalance
                                   jpegQuality:quality
                                  shutterSound:shutterSound
                                 settleSeconds:settle
                               orientationMode:orientation
                                     nightSkip:nightSkip
                                   encodeEvery:encodeEvery
                              encodeEveryDays:encodeEveryDays
                              encodeAtMinutes:atMinutes
                                    encodeMode:mode
                                           fps:fps
                             hasTargetDuration:hasDuration
                              targetDuration:duration
                                uploadTargets:targets
                               keepFramesDays:keepDays];
}

- (TLNightSkip *)nightSkipFromValue:(id)value path:(NSString *)path error:(NSError **)error {
    if (!value || [value isKindOfClass:[NSNumber class]]) {
        BOOL enabled = value ? [value boolValue] : NO;
        return [[TLNightSkip alloc] initWithEnabled:enabled
                                      hasTimeWindow:enabled
                                        fromMinutes:22 * 60
                                          toMinutes:6 * 60
                                         brightness:0];
    }
    NSDictionary *dictionary = nil;
    NSString *nightPath = [path stringByAppendingString:@".nightSkip"];
    if (!TLDictionary(value, nightPath, &dictionary, error)) {
        return nil;
    }
    if (!TLUnknownKeys(dictionary, TLKeySet(@[@"enabled", @"from", @"to", @"brightness"]), nightPath, error)) {
        return nil;
    }
    BOOL enabled = YES;
    NSString *fromText = nil;
    NSString *toText = nil;
    NSNumber *brightnessNumber = nil;
    if (!TLOptionalBool(dictionary, @"enabled", YES, nightPath, &enabled, error) ||
        !TLOptionalString(dictionary, @"from", @"", nightPath, &fromText, error) ||
        !TLOptionalString(dictionary, @"to", @"", nightPath, &toText, error) ||
        !TLOptionalNumber(dictionary, @"brightness", nightPath, &brightnessNumber, error)) {
        return nil;
    }
    BOOL hasWindow = fromText.length > 0 || toText.length > 0;
    NSInteger fromMinutes = 0;
    NSInteger toMinutes = 0;
    if (hasWindow) {
        if (fromText.length == 0 || toText.length == 0) {
            if (error) {
                *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@ 的 from 和 to 必须同时填写", nightPath]);
            }
            return nil;
        }
        BOOL fromOK = NO;
        BOOL toOK = NO;
        fromMinutes = TLParseHHMM(fromText, &fromOK);
        toMinutes = TLParseHHMM(toText, &toOK);
        if (!fromOK || !toOK) {
            if (error) {
                *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@ 的时间必须是 HH:MM", nightPath]);
            }
            return nil;
        }
    }
    double brightness = brightnessNumber ? brightnessNumber.doubleValue : 0;
    if (brightness < 0 || brightness > 1) {
        if (error) {
            *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@.brightness 必须在 0 到 1 之间", nightPath]);
        }
        return nil;
    }
    return [[TLNightSkip alloc] initWithEnabled:enabled
                                  hasTimeWindow:hasWindow
                                    fromMinutes:fromMinutes
                                      toMinutes:toMinutes
                                     brightness:brightness];
}

- (TLProject *)projectWithID:(NSString *)projectID {
    for (TLProject *project in self.projects) {
        if ([project.projectID isEqualToString:projectID]) {
            return project;
        }
    }
    return nil;
}

- (NSInteger)enabledProjectCount {
    NSInteger count = 0;
    for (TLProject *project in self.projects) {
        if (project.enabled) {
            count += 1;
        }
    }
    return count;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *projects = [NSMutableArray array];
    for (TLProject *project in self.projects) {
        [projects addObject:[project dictionaryRepresentation]];
    }
    return @{
        @"server": @{
            @"port": @(self.serverPort),
            @"token": self.serverToken ?: @"",
        },
        @"storage": @{
            @"root": self.storageRoot ?: TLDefaultStorageRoot,
            @"minFreeGB": @(self.minFreeGB),
        },
        @"uploads": @{
            @"telegram": @{
                @"enabled": @(self.telegramEnabled),
                @"botToken": self.telegramBotToken ?: @"",
                @"chatId": self.telegramChatID ?: @"",
            },
            @"webdav": @{
                @"enabled": @(self.webdavEnabled),
                @"url": self.webdavURL ?: @"",
                @"user": self.webdavUser ?: @"",
                @"password": self.webdavPassword ?: @"",
            },
        },
        @"projects": projects,
    };
}

+ (BOOL)updateFileAtPath:(NSString *)path
                  mutate:(NS_NOESCAPE BOOL (^)(NSMutableDictionary *root, NSError **error))mutate
                   error:(NSError **)error {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });
    [lock lock];
    BOOL ok = [self replaceFileAtPath:path mutate:mutate error:error];
    [lock unlock];
    return ok;
}

+ (BOOL)replaceFileAtPath:(NSString *)path
                   mutate:(BOOL (^)(NSMutableDictionary *root, NSError **error))mutate
                    error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) {
        if (error && !*error) {
            *error = TLError(TLErrorCodeConfig, @"无法读取配置");
        }
        return NO;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error];
    if (![json isKindOfClass:[NSMutableDictionary class]]) {
        if (error && !*error) {
            *error = TLError(TLErrorCodeConfig, @"配置不是 JSON 对象");
        }
        return NO;
    }
    if (!mutate(json, error)) {
        return NO;
    }
    if (![TLConfig configWithDictionary:json error:error]) {
        return NO;
    }
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:json options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys) error:error];
    if (!encoded || !TLWriteDataAtomic(encoded, path, error)) {
        return NO;
    }
    chmod(path.fileSystemRepresentation, 0600);
    return YES;
}

@end
