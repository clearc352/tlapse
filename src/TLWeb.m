#import "TLWeb.h"

#import "TLConfig.h"
#import "TLEncode.h"
#import "TLEncoder.h"
#import "TLJobs.h"
#import "TLLog.h"
#import "TLRules.h"
#import "TLState.h"
#import "TLSupport.h"
#import "TLUploader.h"
#import "TLVersion.h"

#import <arpa/inet.h>
#import <ctype.h>
#import <errno.h>
#import <stdlib.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netdb.h>
#import <netinet/in.h>
#import <signal.h>
#import <string.h>
#import <sys/stat.h>
#import <limits.h>
#import <unistd.h>

#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

static const NSUInteger TLWebMaxHeaderBytes = 8192;
static const NSUInteger TLWebMaxBodyBytes = 65536;
static const NSUInteger TLWebMaxImageBytes = 20 * 1024 * 1024;
static const NSInteger TLWebMaxAttempts = 8;
static const NSTimeInterval TLWebLockoutSeconds = 300;
static const NSTimeInterval TLWebSessionSeconds = 12 * 60 * 60;

BOOL TLWebConstantTimeEqual(NSString *left, NSString *right) {
    NSData *a = [left dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSData *b = [right dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSUInteger count = MAX(a.length, b.length);
    uint8_t diff = (uint8_t)(a.length != b.length);
    const uint8_t *ab = a.bytes;
    const uint8_t *bb = b.bytes;
    for (NSUInteger index = 0; index < count; index++) {
        uint8_t leftByte = index < a.length ? ab[index] : 0;
        uint8_t rightByte = index < b.length ? bb[index] : 0;
        diff |= leftByte ^ rightByte;
    }
    return diff == 0;
}

BOOL TLWebTokenAcceptable(NSString *token) {
    if (token.length < 16 || token.length > 128) {
        return NO;
    }
    if ([token caseInsensitiveCompare:@"change-me"] == NSOrderedSame) {
        return NO;
    }
    NSCharacterSet *controls = [NSCharacterSet controlCharacterSet];
    if ([token rangeOfCharacterFromSet:controls].location != NSNotFound) {
        return NO;
    }
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    if ([token stringByTrimmingCharactersInSet:whitespace].length != token.length) {
        return NO;
    }
    return YES;
}

static BOOL TLIPv4Usable(uint32_t hostOrder, BOOL loopbackOnly) {
    if ((hostOrder & 0xff000000u) == 0x7f000000u) {
        return YES;
    }
    if (loopbackOnly) {
        return NO;
    }
    if ((hostOrder & 0xff000000u) == 0x0a000000u) {
        return YES;
    }
    if ((hostOrder & 0xffff0000u) == 0xc0a80000u) {
        return YES;
    }
    if ((hostOrder & 0xffff0000u) == 0xa9fe0000u) {
        return YES;
    }
    if (hostOrder >= 0xac100000u && hostOrder <= 0xac1fffffu) {
        return YES;
    }
    if (hostOrder >= 0x64400000u && hostOrder <= 0x647fffffu) {
        return YES;
    }
    return NO;
}

static BOOL TLIPv6Usable(const uint8_t address[16], BOOL loopbackOnly) {
    static const uint8_t loopback[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    if (memcmp(address, loopback, 16) == 0) {
        return YES;
    }
    if (loopbackOnly) {
        return NO;
    }
    return (address[0] & 0xfe) == 0xfc;
}

BOOL TLWebSocketAddressUsable(NSString *interfaceName, const struct sockaddr *address, BOOL loopbackOnly) {
    if (interfaceName.length == 0 || !address) {
        return NO;
    }
    BOOL nameOK = [interfaceName hasPrefix:@"lo"];
    if (!loopbackOnly) {
        nameOK = nameOK || [interfaceName hasPrefix:@"en"] || [interfaceName hasPrefix:@"bridge"] ||
                 [interfaceName hasPrefix:@"utun"] || [interfaceName hasPrefix:@"ipsec"];
    }
    if (!nameOK || [interfaceName hasPrefix:@"awdl"] || [interfaceName hasPrefix:@"pdp"]) {
        return NO;
    }
    if (address->sa_family == AF_INET) {
        const struct sockaddr_in *ipv4 = (const struct sockaddr_in *)address;
        return TLIPv4Usable(ntohl(ipv4->sin_addr.s_addr), loopbackOnly);
    }
    if (address->sa_family == AF_INET6) {
        const struct sockaddr_in6 *ipv6 = (const struct sockaddr_in6 *)address;
        return TLIPv6Usable(ipv6->sin6_addr.s6_addr, loopbackOnly);
    }
    return NO;
}

BOOL TLWebHostAllowed(NSString *hostHeader, NSArray<NSString *> *addresses, uint16_t port) {
    NSString *host = [hostHeader stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (host.length == 0 || host.length > 255 || [host containsString:@"/"] || [host containsString:@" "] || [host containsString:@"\\"]) {
        return NO;
    }
    NSString *name = host;
    NSString *portText = nil;
    if ([host hasPrefix:@"["]) {
        NSRange end = [host rangeOfString:@"]"];
        if (end.location == NSNotFound) {
            return NO;
        }
        name = [host substringWithRange:NSMakeRange(1, end.location - 1)];
        NSString *rest = [host substringFromIndex:NSMaxRange(end)];
        if ([rest hasPrefix:@":"]) {
            portText = [rest substringFromIndex:1];
        } else if (rest.length > 0) {
            return NO;
        }
    } else {
        NSArray<NSString *> *pieces = [host componentsSeparatedByString:@":"];
        if (pieces.count == 2) {
            name = pieces[0];
            portText = pieces[1];
        } else if (pieces.count != 1) {
            return NO;
        }
    }
    if (name.length == 0 || [name containsString:@".."]) {
        return NO;
    }
    if (portText) {
        NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
        if (portText.length == 0 || portText.length > 5 || [portText rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound) {
            return NO;
        }
        if (portText.integerValue != port) {
            return NO;
        }
    }
    if ([name caseInsensitiveCompare:@"localhost"] == NSOrderedSame) {
        return YES;
    }
    if ([name.lowercaseString hasSuffix:@".local"]) {
        return YES;
    }
    for (NSString *address in addresses) {
        if ([name caseInsensitiveCompare:address] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

static BOOL TLPathComponent(NSString *component) {
    if (component.length == 0 || component.length > 96) {
        return NO;
    }
    if ([component hasPrefix:@"."] || [component isEqualToString:@"."] || [component isEqualToString:@".."]) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
    return [component rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

NSString *TLWebSafePath(NSString *root, NSArray<NSString *> *components) {
    if (root.length == 0 || components.count == 0) {
        return nil;
    }
    NSString *combined = root;
    for (NSString *component in components) {
        if (!TLPathComponent(component)) {
            return nil;
        }
        combined = [combined stringByAppendingPathComponent:component];
    }
    NSString *standardRoot = root.stringByStandardizingPath;
    NSString *standard = combined.stringByStandardizingPath;
    NSString *prefix = [standardRoot hasSuffix:@"/"] ? standardRoot : [standardRoot stringByAppendingString:@"/"];
    if (![standard hasPrefix:prefix]) {
        return nil;
    }
    return standard;
}

static NSString *TLPercentDecode(NSString *text, BOOL plusIsSpace) {
    if (!text) {
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    const char *bytes = text.UTF8String;
    if (!bytes) {
        return nil;
    }
    size_t length = strlen(bytes);
    for (size_t index = 0; index < length; index++) {
        unsigned char value = 0;
        if (bytes[index] == '%') {
            if (index + 2 >= length || !isxdigit((unsigned char)bytes[index + 1]) || !isxdigit((unsigned char)bytes[index + 2])) {
                return nil;
            }
            char hex[3] = {bytes[index + 1], bytes[index + 2], 0};
            value = (unsigned char)strtol(hex, NULL, 16);
            if (value == 0) {
                return nil;
            }
            index += 2;
        } else if (plusIsSpace && bytes[index] == '+') {
            value = ' ';
        } else {
            value = (unsigned char)bytes[index];
        }
        [data appendBytes:&value length:1];
    }
    NSString *decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!decoded || [decoded containsString:@"/"] || [decoded containsString:@"\\"]) {
        return nil;
    }
    return decoded;
}

static NSString *TLHex(const uint8_t *bytes, size_t count) {
    static const char alphabet[] = "0123456789abcdef";
    char text[65];
    if (count > 32) {
        return nil;
    }
    for (size_t index = 0; index < count; index++) {
        text[index * 2] = alphabet[bytes[index] >> 4];
        text[index * 2 + 1] = alphabet[bytes[index] & 0x0f];
    }
    text[count * 2] = 0;
    return [NSString stringWithUTF8String:text];
}

static NSString *TLNewSessionID(void) {
    uint8_t bytes[32];
    arc4random_buf(bytes, sizeof(bytes));
    return TLHex(bytes, sizeof(bytes));
}

@interface TLWebResponse : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSString *type;
@property (nonatomic, strong) NSData *body;
@property (nonatomic, copy, nullable) NSString *cookie;
@property (nonatomic, copy, nullable) NSString *fileName;
@property (nonatomic) int fileFD;
@property (nonatomic) unsigned long long fileOffset;
@property (nonatomic) unsigned long long fileLength;
@property (nonatomic) BOOL headOnly;
@property (nonatomic, copy) NSString *contentRange;
@property (nonatomic) BOOL acceptsRanges;
@end

@implementation TLWebResponse
- (instancetype)init {
    self = [super init];
    if (self) { _fileFD = -1; }
    return self;
}
- (void)dealloc {
    if (_fileFD >= 0) { close(_fileFD); }
}
@end

// 从已打开的根目录逐级查找，拒绝符号链接，避免校验路径后再打开产生逃逸窗口。
static int TLOpenWebFile(NSString *root, NSArray<NSString *> *components) {
    if (!TLWebSafePath(root, components)) { return -1; }
    int directory = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (directory < 0) { return -1; }
    for (NSUInteger i = 0; i < components.count; i++) {
        BOOL last = i + 1 == components.count;
        int next = openat(directory, components[i].fileSystemRepresentation,
                          O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (last ? 0 : O_DIRECTORY));
        close(directory);
        if (next < 0) { return -1; }
        directory = next;
    }
    struct stat info;
    if (fstat(directory, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0) {
        close(directory);
        return -1;
    }
    return directory;
}

static BOOL TLRangeNumber(NSString *text, unsigned long long *number) {
    const char *bytes = text.UTF8String;
    if (!bytes || !bytes[0]) { return NO; }
    unsigned long long value = 0;
    for (const char *p = bytes; *p; p++) {
        if (*p < '0' || *p > '9' || value > (ULLONG_MAX - (*p - '0')) / 10) { return NO; }
        value = value * 10 + (*p - '0');
    }
    *number = value;
    return YES;
}

// 只接受一个字节区间；畸形、多区间和越界请求统一返回 416，不拼接错误字节。
static BOOL TLVideoRange(NSString *range, unsigned long long size,
                         unsigned long long *offset, unsigned long long *length) {
    if (![range hasPrefix:@"bytes="] || size == 0) { return NO; }
    NSArray<NSString *> *parts = [[range substringFromIndex:6] componentsSeparatedByString:@"-"];
    if (parts.count != 2) { return NO; }
    unsigned long long start = 0, end = 0;
    if ([parts[0] length] == 0) {
        if (!TLRangeNumber(parts[1], &end) || end == 0) { return NO; }
        *length = MIN(end, size);
        *offset = size - *length;
        return YES;
    }
    if (!TLRangeNumber(parts[0], &start) || start >= size) { return NO; }
    if ([parts[1] length] == 0) { end = size - 1; }
    else if (!TLRangeNumber(parts[1], &end) || end < start) { return NO; }
    end = MIN(end, size - 1);
    *offset = start;
    *length = end - start + 1;
    return YES;
}

@interface TLWebListener : NSObject
@property (nonatomic) int fd;
@property (nonatomic, strong) dispatch_source_t source;
@end

@implementation TLWebListener
@end

@interface TLWebServer ()
@property (nonatomic, copy) NSString *configPath;
@property (nonatomic, strong) TLState *state;
@property (nonatomic, copy, nullable) TLWebSnap snap;
@property (nonatomic, strong, nullable) TLConfig *config;
@property (nonatomic) BOOL loopbackOnly;
@property (nonatomic) BOOL ephemeral;
@property (nonatomic) uint16_t port;
@property (nonatomic, copy) NSArray<NSString *> *listenAddresses;
@property (nonatomic, copy) NSArray<NSString *> *hostAddresses;
@property (nonatomic) BOOL stopped;
@property (nonatomic) BOOL warnedWeakToken;
@property (nonatomic) BOOL warnedNoAddress;
@property (nonatomic) BOOL warnedPrivilegedPort;
@property (nonatomic, strong) dispatch_queue_t listenQueue;
@property (nonatomic, strong) dispatch_queue_t connectionQueue;
@property (nonatomic, strong) dispatch_source_t refreshTimer;
@property (nonatomic, strong) NSMutableArray<TLWebListener *> *listeners;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *sessions;
@property (nonatomic, strong) NSMutableArray<NSString *> *sessionOrder;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *attempts;
@property (nonatomic, strong) NSLock *stateLock;
@property (nonatomic, strong) dispatch_semaphore_t slots;
@property (nonatomic, copy) NSString *boundSignature;
@end

@implementation TLWebServer

- (instancetype)initWithConfigPath:(NSString *)path state:(TLState *)state snap:(TLWebSnap)snap {
    self = [super init];
    if (self) {
        _configPath = [path copy];
        _state = state;
        _snap = [snap copy];
        _listenQueue = dispatch_queue_create("com.ddxyl.tlapsed.web.listen", DISPATCH_QUEUE_SERIAL);
        _connectionQueue = dispatch_queue_create("com.ddxyl.tlapsed.web.connection", DISPATCH_QUEUE_CONCURRENT);
        _listeners = [NSMutableArray array];
        _sessions = [NSMutableDictionary dictionary];
        _sessionOrder = [NSMutableArray array];
        _attempts = [NSMutableDictionary dictionary];
        _stateLock = [[NSLock alloc] init];
        _slots = dispatch_semaphore_create(12);
        _listenAddresses = @[];
        _hostAddresses = @[];
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            signal(SIGPIPE, SIG_IGN);
        });
    }
    return self;
}

- (BOOL)applyConfig:(TLConfig *)config error:(NSError **)error {
    self.loopbackOnly = NO;
    self.ephemeral = NO;
    return [self installConfig:config error:error];
}

- (BOOL)startLoopbackForTests:(TLConfig *)config error:(NSError **)error {
    self.loopbackOnly = YES;
    self.ephemeral = YES;
    self.port = 0;
    return [self installConfig:config error:error];
}

- (BOOL)installConfig:(TLConfig *)config error:(NSError **)error {
    NSString *previousToken = nil;
    [self.stateLock lock];
    previousToken = self.config.serverToken;
    self.config = config;
    if (previousToken && !TLWebConstantTimeEqual(previousToken, config.serverToken ?: @"")) {
        [self.sessions removeAllObjects];
        [self.sessionOrder removeAllObjects];
    }
    [self.stateLock unlock];
    if (self.stopped) {
        return YES;
    }
    __block BOOL bound = NO;
    __block NSError *bindError = nil;
    dispatch_sync(self.listenQueue, ^{
        bound = [self rebindOnListenQueue:&bindError];
        [self ensureRefreshTimer];
    });
    if (error) {
        *error = bindError;
    }
    return bound;
}

- (void)stop {
    self.stopped = YES;
    dispatch_sync(self.listenQueue, ^{
        if (self.refreshTimer) {
            dispatch_source_cancel(self.refreshTimer);
            self.refreshTimer = nil;
        }
        [self closeListeners];
    });
}

- (void)ensureRefreshTimer {
    if (self.refreshTimer || self.stopped) {
        return;
    }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.listenQueue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), 15 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    __weak TLWebServer *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        TLWebServer *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.stopped) {
            return;
        }
        [strongSelf rebindOnListenQueue:NULL];
    });
    dispatch_resume(timer);
    self.refreshTimer = timer;
}

- (TLConfig *)currentConfig {
    [self.stateLock lock];
    TLConfig *config = self.config;
    [self.stateLock unlock];
    return config;
}

- (void)replaceConfigAfterWrite:(TLConfig *)config {
    [self.stateLock lock];
    self.config = config;
    [self.stateLock unlock];
}

- (void)closeListeners {
    for (TLWebListener *listener in self.listeners) {
        dispatch_source_cancel(listener.source);
    }
    [self.listeners removeAllObjects];
    self.listenAddresses = @[];
    self.hostAddresses = @[];
    self.boundSignature = nil;
    if (self.ephemeral) {
        self.port = 0;
    }
}

- (BOOL)rebindOnListenQueue:(NSError **)error {
    if (self.stopped) {
        return YES;
    }
    TLConfig *config = [self currentConfig];
    if (!config || !TLWebTokenAcceptable(config.serverToken)) {
        [self closeListeners];
        if (!self.warnedWeakToken) {
            self.warnedWeakToken = YES;
            TLLogError(@"控制台未启动：server.token 还是默认值或短于 16 位。请改成随机字符串，端口保持关闭");
        }
        return YES;
    }
    self.warnedWeakToken = NO;
    uint16_t requested = self.ephemeral ? self.port : (uint16_t)config.serverPort;
    if (!self.ephemeral && requested < 1024) {
        [self closeListeners];
        if (!self.warnedPrivilegedPort) {
            self.warnedPrivilegedPort = YES;
            TLLogError(@"控制台未启动：%u 是特权端口，mobile 用户不能监听", requested);
        }
        return YES;
    }
    self.warnedPrivilegedPort = NO;
    NSArray<NSDictionary *> *candidates = [self addressCandidates];
    NSMutableArray<NSString *> *wanted = [NSMutableArray array];
    for (NSDictionary *candidate in candidates) {
        [wanted addObject:candidate[@"display"]];
    }
    [wanted sortUsingSelector:@selector(compare:)];
    NSString *signature = [NSString stringWithFormat:@"%u|%@", requested, [wanted componentsJoinedByString:@","]];
    if (self.listeners.count > 0 && [signature isEqualToString:self.boundSignature]) {
        return YES;
    }
    uint16_t previousPort = self.port;
    [self closeListeners];
    if (self.ephemeral && requested == 0) {
        requested = previousPort;
    }
    NSMutableArray<NSString *> *displays = [NSMutableArray array];
    NSMutableArray<NSString *> *hosts = [NSMutableArray array];
    uint16_t boundPort = requested;
    for (NSDictionary *candidate in candidates) {
        NSData *storage = candidate[@"address"];
        struct sockaddr_storage address;
        memset(&address, 0, sizeof(address));
        memcpy(&address, storage.bytes, MIN(storage.length, sizeof(address)));
        if (address.ss_family == AF_INET) {
            ((struct sockaddr_in *)&address)->sin_port = htons(boundPort);
        } else if (address.ss_family == AF_INET6) {
            ((struct sockaddr_in6 *)&address)->sin6_port = htons(boundPort);
        }
        int fd = [self listenOnAddress:&address];
        if (fd < 0) {
            continue;
        }
        struct sockaddr_storage actual;
        socklen_t length = sizeof(actual);
        if (getsockname(fd, (struct sockaddr *)&actual, &length) != 0) {
            close(fd);
            continue;
        }
        uint16_t actualPort = actual.ss_family == AF_INET ? ntohs(((struct sockaddr_in *)&actual)->sin_port) : ntohs(((struct sockaddr_in6 *)&actual)->sin6_port);
        if (boundPort == 0) {
            boundPort = actualPort;
        }
        NSString *numeric = [self numericHost:&actual];
        if (numeric.length == 0) {
            close(fd);
            continue;
        }
        TLWebListener *listener = [[TLWebListener alloc] init];
        listener.fd = fd;
        listener.source = [self sourceForListener:fd];
        [self.listeners addObject:listener];
        NSString *pretty = [numeric containsString:@":"] ? [NSString stringWithFormat:@"[%@]:%u", numeric, actualPort] : [NSString stringWithFormat:@"%@:%u", numeric, actualPort];
        [displays addObject:pretty];
        [hosts addObject:numeric];
    }
    self.port = boundPort;
    self.listenAddresses = displays;
    self.hostAddresses = hosts;
    NSArray<NSString *> *boundHosts = [hosts sortedArrayUsingSelector:@selector(compare:)];
    self.boundSignature = [NSString stringWithFormat:@"%u|%@", boundPort, [boundHosts componentsJoinedByString:@","]];
    if (displays.count == 0) {
        if (self.loopbackOnly) {
            if (error) {
                *error = TLError(TLErrorCodeInternal, @"无法监听回环地址");
            }
            return NO;
        }
        if (!self.warnedNoAddress) {
            self.warnedNoAddress = YES;
            TLLogInfo(@"控制台没有可绑定的局域网地址。连上 Wi-Fi、个人热点或 Tailscale 后会自动打开");
        }
        return YES;
    }
    self.warnedNoAddress = NO;
    TLLogInfo(@"控制台监听 %@。只接受这些地址、localhost 和 .local 名称，不监听蜂窝网", [displays componentsJoinedByString:@"、"]);
    return YES;
}

- (NSArray<NSDictionary *> *)addressCandidates {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (struct ifaddrs *item = list; item; item = item->ifa_next) {
        if (!item->ifa_addr || !(item->ifa_flags & IFF_UP)) {
            continue;
        }
        NSString *name = [NSString stringWithUTF8String:item->ifa_name] ?: @"";
        if (!TLWebSocketAddressUsable(name, item->ifa_addr, self.loopbackOnly)) {
            continue;
        }
        NSString *numeric = [self numericHost:(struct sockaddr_storage *)item->ifa_addr];
        if (numeric.length == 0 || [seen containsObject:numeric]) {
            continue;
        }
        [seen addObject:numeric];
        struct sockaddr_storage copy;
        memset(&copy, 0, sizeof(copy));
        size_t size = item->ifa_addr->sa_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
        memcpy(&copy, item->ifa_addr, size);
        [candidates addObject:@{
            @"display": numeric,
            @"address": [NSData dataWithBytes:&copy length:sizeof(copy)],
        }];
    }
    freeifaddrs(list);
    return candidates;
}

- (NSString *)numericHost:(struct sockaddr_storage *)address {
    char host[NI_MAXHOST];
    socklen_t length = address->ss_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
    if (getnameinfo((struct sockaddr *)address, length, host, sizeof(host), NULL, 0, NI_NUMERICHOST) != 0) {
        return @"";
    }
    NSString *text = [NSString stringWithUTF8String:host] ?: @"";
    NSRange zone = [text rangeOfString:@"%"];
    if (zone.location != NSNotFound) {
        text = [text substringToIndex:zone.location];
    }
    return text;
}

- (int)listenOnAddress:(struct sockaddr_storage *)address {
    int fd = socket(address->ss_family, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    if (address->ss_family == AF_INET6) {
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, sizeof(yes));
    }
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
    socklen_t length = address->ss_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
    if (bind(fd, (struct sockaddr *)address, length) != 0 || listen(fd, 16) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

- (dispatch_source_t)sourceForListener:(int)fd {
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self.listenQueue);
    __weak TLWebServer *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        TLWebServer *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        while (!strongSelf.stopped) {
            struct sockaddr_storage peerAddress;
            socklen_t length = sizeof(peerAddress);
            int client = accept(fd, (struct sockaddr *)&peerAddress, &length);
            if (client < 0) {
                if (errno == EINTR) {
                    continue;
                }
                break;
            }
            if (dispatch_semaphore_wait(strongSelf.slots, DISPATCH_TIME_NOW) != 0) {
                close(client);
                continue;
            }
            NSString *peer = [strongSelf numericHost:&peerAddress];
            if (peer.length == 0) {
                peer = @"unknown";
            }
            dispatch_async(strongSelf.connectionQueue, ^{
                [strongSelf serveClient:client peer:peer];
                dispatch_semaphore_signal(strongSelf.slots);
            });
        }
    });
    dispatch_source_set_cancel_handler(source, ^{
        close(fd);
    });
    dispatch_resume(source);
    return source;
}

- (void)serveClient:(int)client peer:(NSString *)peer {
    int yes = 1;
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    // Darwin 的 accept 会继承监听套接字的非阻塞标志。不清掉的话，请求还在路上时 read 会立刻返回 EAGAIN。
    int flags = fcntl(client, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(client, F_SETFL, flags & ~O_NONBLOCK);
    }
    struct timeval timeout = {20, 0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    timeout.tv_sec = 60;
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    @autoreleasepool {
        TLWebResponse *response = [self responseForClient:client peer:peer];
        [self writeResponse:response toClient:client];
    }
    close(client);
}

static BOOL TLWriteAll(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t count = write(fd, cursor, remaining);
        if (count <= 0) {
            if (count < 0 && errno == EINTR) { continue; }
            return NO;
        }
        cursor += count;
        remaining -= (size_t)count;
    }
    return YES;
}

- (BOOL)writeResponse:(TLWebResponse *)response toClient:(int)client {
    NSData *body = response.body ?: [NSData data];
    NSString *reason = [self reasonForStatus:response.status];
    NSMutableString *header = [NSMutableString string];
    [header appendFormat:@"HTTP/1.1 %ld %@\r\n", (long)response.status, reason];
    [header appendFormat:@"Content-Type: %@\r\n", response.type ?: @"text/plain; charset=utf-8"];
    [header appendFormat:@"Content-Length: %llu\r\n", response.fileFD >= 0 ? response.fileLength : (unsigned long long)body.length];
    if (response.acceptsRanges) { [header appendString:@"Accept-Ranges: bytes\r\n"]; }
    if (response.contentRange) { [header appendFormat:@"Content-Range: %@\r\n", response.contentRange]; }
    [header appendString:@"Connection: close\r\n"];
    [header appendString:@"Cache-Control: no-store\r\n"];
    [header appendString:@"X-Content-Type-Options: nosniff\r\n"];
    [header appendString:@"Referrer-Policy: no-referrer\r\n"];
    [header appendString:@"X-Frame-Options: DENY\r\n"];
    if ([response.type containsString:@"text/html"]) {
        [header appendString:@"Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob:; font-src 'self'; media-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'\r\n"];
    }
    if (response.cookie) {
        [header appendFormat:@"Set-Cookie: %@\r\n", response.cookie];
    }
    if (response.fileName.length > 0 && TLPathComponent(response.fileName)) {
        [header appendFormat:@"Content-Disposition: attachment; filename=\"%@\"\r\n", response.fileName];
    }
    [header appendString:@"\r\n"];
    NSData *head = [header dataUsingEncoding:NSUTF8StringEncoding];
    BOOL sent = TLWriteAll(client, head.bytes, head.length);
    if (sent && !response.headOnly) {
        if (response.fileFD < 0) { sent = TLWriteAll(client, body.bytes, body.length); }
        else {
            uint8_t chunk[64 * 1024];
            unsigned long long remaining = response.fileLength, offset = response.fileOffset;
            while (sent && remaining > 0) {
                ssize_t count = pread(response.fileFD, chunk, (size_t)MIN(remaining, sizeof(chunk)), (off_t)offset);
                if (count < 0 && errno == EINTR) { continue; }
                if (count <= 0) {
                    TLLogError(@"视频响应读取失败或文件已截断，剩余 %llu 字节", remaining);
                    sent = NO;
                    break;
                }
                sent = TLWriteAll(client, chunk, (size_t)count);
                remaining -= (unsigned long long)count;
                offset += (unsigned long long)count;
            }
        }
    }
    // 成功、HEAD、断连及读取失败均在同一出口释放文件句柄。
    if (response.fileFD >= 0) { close(response.fileFD); response.fileFD = -1; }
    return sent;
}

- (NSString *)reasonForStatus:(NSInteger)status {
    switch (status) {
        case 200: return @"OK";
        case 204: return @"No Content";
        case 206: return @"Partial Content";
        case 416: return @"Range Not Satisfiable";
        case 400: return @"Bad Request";
        case 401: return @"Unauthorized";
        case 403: return @"Forbidden";
        case 404: return @"Not Found";
        case 405: return @"Method Not Allowed";
        case 409: return @"Conflict";
        case 413: return @"Payload Too Large";
        case 429: return @"Too Many Requests";
        case 500: return @"Internal Server Error";
        case 501: return @"Not Implemented";
        case 503: return @"Service Unavailable";
        default: return @"Error";
    }
}

- (TLWebResponse *)responseForClient:(int)client peer:(NSString *)peer {
    NSMutableData *buffer = [NSMutableData data];
    NSData *marker = [NSData dataWithBytes:"\r\n\r\n" length:4];
    while ([buffer rangeOfData:marker options:0 range:NSMakeRange(0, buffer.length)].location == NSNotFound) {
        if (buffer.length > TLWebMaxHeaderBytes) {
            return [self text:413 message:@"请求头太大"];
        }
        uint8_t chunk[2048];
        ssize_t count = read(client, chunk, sizeof(chunk));
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return [self text:400 message:@"请求不完整"];
        }
        if (count == 0) {
            return [self text:400 message:@"请求不完整"];
        }
        [buffer appendBytes:chunk length:(NSUInteger)count];
    }
    NSRange split = [buffer rangeOfData:marker options:0 range:NSMakeRange(0, buffer.length)];
    NSData *headData = [buffer subdataWithRange:NSMakeRange(0, split.location)];
    NSData *rest = [buffer subdataWithRange:NSMakeRange(NSMaxRange(split), buffer.length - NSMaxRange(split))];
    NSString *head = [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding];
    if (!head) {
        return [self text:400 message:@"请求头不是文本"];
    }
    NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) {
        return [self text:400 message:@"空请求"];
    }
    NSArray<NSString *> *request = [lines[0] componentsSeparatedByString:@" "];
    if (request.count < 2) {
        return [self text:400 message:@"请求行无法解析"];
    }
    NSString *method = request[0];
    NSString *target = request[1];
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    for (NSUInteger index = 1; index < lines.count; index++) {
        NSRange colon = [lines[index] rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            continue;
        }
        NSString *name = [[lines[index] substringToIndex:colon.location] lowercaseString];
        NSString *value = [[lines[index] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (headers[name]) {
            headers[name] = [NSString stringWithFormat:@"%@, %@", headers[name], value];
        } else {
            headers[name] = value;
        }
    }
    NSInteger contentLength = headers[@"content-length"] ? headers[@"content-length"].integerValue : 0;
    if (contentLength < 0 || (NSUInteger)contentLength > TLWebMaxBodyBytes) {
        return [self jsonError:413 message:@"请求内容太大"];
    }
    if ([headers[@"transfer-encoding"].lowercaseString containsString:@"chunked"]) {
        return [self jsonError:400 message:@"不支持分块请求"];
    }
    NSMutableData *body = [rest mutableCopy];
    while (body.length < (NSUInteger)contentLength) {
        uint8_t chunk[2048];
        size_t want = MIN(sizeof(chunk), (NSUInteger)contentLength - body.length);
        ssize_t count = read(client, chunk, want);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return [self text:400 message:@"请求内容不完整"];
        }
        if (count == 0) {
            return [self text:400 message:@"请求内容不完整"];
        }
        [body appendBytes:chunk length:(NSUInteger)count];
    }
    if (body.length > (NSUInteger)contentLength) {
        body.length = (NSUInteger)contentLength;
    }
    NSString *path = target;
    NSString *query = @"";
    NSRange question = [target rangeOfString:@"?"];
    if (question.location != NSNotFound) {
        path = [target substringToIndex:question.location];
        query = [target substringFromIndex:question.location + 1];
    }
    NSString *decodedPath = [path stringByRemovingPercentEncoding];
    if (!decodedPath || [decodedPath containsString:@".."] || [decodedPath containsString:@"\\"]) {
        return [self jsonError:404 message:@"没有这个页面"];
    }
    uint16_t port = self.port;
    NSArray<NSString *> *addresses = self.hostAddresses;
    if (!TLWebHostAllowed(headers[@"host"], addresses, port)) {
        return [self text:403 message:@"请用手机的局域网地址打开控制台"];
    }
    BOOL headOnly = [method isEqualToString:@"HEAD"];
    NSMutableDictionary *routeHeaders = [headers mutableCopy];
    if (headOnly) { [routeHeaders removeObjectForKey:@"range"]; }
    TLWebResponse *response = [self routeMethod:headOnly ? @"GET" : method path:decodedPath query:[self query:query] headers:routeHeaders body:body peer:peer];
    response.headOnly = headOnly;
    return response;
}

- (NSDictionary<NSString *, NSString *> *)query:(NSString *)query {
    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    if (query.length == 0) {
        return values;
    }
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSRange equal = [pair rangeOfString:@"="];
        NSString *rawKey = equal.location == NSNotFound ? pair : [pair substringToIndex:equal.location];
        NSString *rawValue = equal.location == NSNotFound ? @"" : [pair substringFromIndex:equal.location + 1];
        NSString *key = TLPercentDecode(rawKey, YES);
        NSString *value = TLPercentDecode(rawValue, YES);
        if (key.length > 0 && value) {
            values[key] = value;
        }
    }
    return values;
}

- (TLWebResponse *)routeMethod:(NSString *)method
                          path:(NSString *)path
                         query:(NSDictionary<NSString *, NSString *> *)query
                       headers:(NSDictionary<NSString *, NSString *> *)headers
                          body:(NSData *)body
                          peer:(NSString *)peer {
    if (![path hasPrefix:@"/api/"]) {
        if (![method isEqualToString:@"GET"]) { return [self jsonError:405 message:@"静态资源只支持 GET 和 HEAD"]; }
        if ([path isEqualToString:@"/favicon.ico"]) { return [self empty:204]; }
        return [self staticResponse:path];
    }
    NSArray<NSString *> *parts = [self parts:path];
    if (!parts || parts.count < 2 || ![parts[0] isEqualToString:@"api"]) {
        return [self jsonError:404 message:@"没有这个页面"];
    }
    BOOL login = parts.count == 2 && [parts[1] isEqualToString:@"login"] && [method isEqualToString:@"POST"];
    if (!login) {
        NSString *auth = [self authorizedSession:headers peer:peer];
        if ([auth isEqualToString:@"locked"]) {
            return [self jsonError:429 message:@"尝试次数过多，请稍后再试"];
        }
        if (![auth isEqualToString:@"ok"]) {
            return [self jsonError:401 message:@"需要登录"];
        }
        if (![method isEqualToString:@"GET"] && ![method isEqualToString:@"HEAD"]) {
            if (![headers[@"x-tlapse-request"] isEqualToString:@"1"]) {
                return [self jsonError:403 message:@"缺少控制台请求标记"];
            }
        }
    } else if (![headers[@"x-tlapse-request"] isEqualToString:@"1"]) {
        return [self jsonError:403 message:@"缺少控制台请求标记"];
    }
    if (login) {
        return [self login:body peer:peer];
    }
    if (parts.count == 2 && [parts[1] isEqualToString:@"logout"] && [method isEqualToString:@"POST"]) {
        return [self logout:headers];
    }
    if (parts.count == 2 && [parts[1] isEqualToString:@"status"] && [method isEqualToString:@"GET"]) {
        return [self status];
    }
    if (parts.count == 2 && [parts[1] isEqualToString:@"logs"] && [method isEqualToString:@"GET"]) {
        return [self logs:query];
    }
    if (parts.count == 2 && [parts[1] isEqualToString:@"projects"] && [method isEqualToString:@"GET"]) {
        return [self projectList];
    }
    if (parts.count == 2 && [parts[1] isEqualToString:@"projects"] && [method isEqualToString:@"POST"]) {
        return [self createProject:body];
    }
    if (parts.count >= 3 && [parts[1] isEqualToString:@"projects"]) {
        return [self projectMethod:method projectID:parts[2] parts:parts query:query headers:headers body:body];
    }
    if (parts.count == 4 && [parts[1] isEqualToString:@"videos"] && [parts[3] isEqualToString:@"upload"] && [method isEqualToString:@"POST"]) {
        return [self uploadNamed:parts[2]];
    }
    return [self jsonError:404 message:@"没有这个页面"];
}

- (NSArray<NSString *> *)parts:(NSString *)path {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *piece in [path componentsSeparatedByString:@"/"]) {
        if (piece.length == 0) {
            continue;
        }
        if (!TLPathComponent(piece)) {
            return nil;
        }
        [parts addObject:piece];
    }
    return parts;
}

- (NSString *)authorizedSession:(NSDictionary<NSString *, NSString *> *)headers peer:(NSString *)peer {
    if ([self lockedPeer:peer]) {
        return @"locked";
    }
    TLConfig *config = [self currentConfig];
    NSString *authorization = headers[@"authorization"] ?: @"";
    if ([authorization hasPrefix:@"Bearer "]) {
        NSString *token = [authorization substringFromIndex:7];
        if (TLWebConstantTimeEqual(token, config.serverToken ?: @"")) {
            [self clearAttempts:peer];
            return @"ok";
        }
        [self recordFailure:peer];
        return [self lockedPeer:peer] ? @"locked" : @"bad";
    }
    if ([authorization.lowercaseString hasPrefix:@"basic "]) {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:[authorization substringFromIndex:6] options:0];
        NSString *text = [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] ?: @"";
        NSRange colon = [text rangeOfString:@":"];
        NSString *token = colon.location == NSNotFound ? @"" : [text substringFromIndex:colon.location + 1];
        if (TLWebConstantTimeEqual(token, config.serverToken ?: @"")) {
            [self clearAttempts:peer];
            return @"ok";
        }
        [self recordFailure:peer];
        return [self lockedPeer:peer] ? @"locked" : @"bad";
    }
    NSString *session = [self cookie:headers[@"cookie"] name:@"tlapse_session"];
    if (session.length == 0) {
        return @"none";
    }
    [self.stateLock lock];
    NSDate *expiry = self.sessions[session];
    BOOL valid = expiry && [expiry timeIntervalSinceNow] > 0;
    if (!valid) {
        [self.sessions removeObjectForKey:session];
        [self.sessionOrder removeObject:session];
    }
    [self.stateLock unlock];
    return valid ? @"ok" : @"none";
}

- (NSString *)cookie:(NSString *)header name:(NSString *)name {
    for (NSString *piece in [header componentsSeparatedByString:@";"]) {
        NSString *trimmed = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *prefix = [name stringByAppendingString:@"="];
        if ([trimmed hasPrefix:prefix]) {
            return [trimmed substringFromIndex:prefix.length];
        }
    }
    return nil;
}

- (BOOL)lockedPeer:(NSString *)peer {
    [self.stateLock lock];
    NSDate *until = self.attempts[peer][@"until"];
    BOOL locked = [until isKindOfClass:[NSDate class]] && [until timeIntervalSinceNow] > 0;
    [self.stateLock unlock];
    return locked;
}

- (void)recordFailure:(NSString *)peer {
    [self.stateLock lock];
    NSMutableDictionary *entry = self.attempts[peer] ?: [NSMutableDictionary dictionary];
    NSDate *first = entry[@"first"];
    if (![first isKindOfClass:[NSDate class]] || -[first timeIntervalSinceNow] > TLWebLockoutSeconds) {
        entry[@"first"] = [NSDate date];
        entry[@"count"] = @0;
        [entry removeObjectForKey:@"until"];
    }
    NSInteger count = [entry[@"count"] integerValue] + 1;
    entry[@"count"] = @(count);
    if (count >= TLWebMaxAttempts) {
        entry[@"until"] = [NSDate dateWithTimeIntervalSinceNow:TLWebLockoutSeconds];
        TLLogError(@"控制台登录失败次数过多，暂时拒绝 %@", peer);
    }
    self.attempts[peer] = entry;
    [self.stateLock unlock];
}

- (void)clearAttempts:(NSString *)peer {
    [self.stateLock lock];
    [self.attempts removeObjectForKey:peer];
    [self.stateLock unlock];
}

- (TLWebResponse *)login:(NSData *)body peer:(NSString *)peer {
    if ([self lockedPeer:peer]) {
        return [self jsonError:429 message:@"尝试次数过多，请稍后再试"];
    }
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSString *token = [json isKindOfClass:[NSDictionary class]] ? json[@"token"] : nil;
    if (![token isKindOfClass:[NSString class]]) {
        token = @"";
    }
    token = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    TLConfig *config = [self currentConfig];
    if (!TLWebConstantTimeEqual(token, config.serverToken ?: @"")) {
        [self recordFailure:peer];
        if ([self lockedPeer:peer]) {
            return [self jsonError:429 message:@"尝试次数过多，请稍后再试"];
        }
        return [self jsonError:401 message:@"口令不正确"];
    }
    [self clearAttempts:peer];
    NSString *session = TLNewSessionID();
    [self.stateLock lock];
    self.sessions[session] = [NSDate dateWithTimeIntervalSinceNow:TLWebSessionSeconds];
    [self.sessionOrder addObject:session];
    while (self.sessionOrder.count > 32) {
        NSString *old = self.sessionOrder.firstObject;
        [self.sessionOrder removeObjectAtIndex:0];
        [self.sessions removeObjectForKey:old];
    }
    [self.stateLock unlock];
    TLWebResponse *response = [self json:200 object:@{@"ok": @YES}];
    response.cookie = [NSString stringWithFormat:@"tlapse_session=%@; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200", session];
    return response;
}

- (TLWebResponse *)logout:(NSDictionary<NSString *, NSString *> *)headers {
    NSString *session = [self cookie:headers[@"cookie"] name:@"tlapse_session"];
    if (session.length > 0) {
        [self.stateLock lock];
        [self.sessions removeObjectForKey:session];
        [self.sessionOrder removeObject:session];
        [self.stateLock unlock];
    }
    TLWebResponse *response = [self json:200 object:@{@"ok": @YES}];
    response.cookie = @"tlapse_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0";
    return response;
}

- (TLWebResponse *)status {
    TLConfig *config = [self currentConfig];
    NSDictionary *snapshot = [self.state snapshot];
    NSDictionary *daemon = [snapshot[@"daemon"] isKindOfClass:[NSDictionary class]] ? snapshot[@"daemon"] : @{};
    NSString *started = [daemon[@"startedAt"] isKindOfClass:[NSString class]] ? daemon[@"startedAt"] : @"";
    NSDate *startedAt = started.length > 0 ? TLParseTimestamp(started) : nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:config.storageRoot error:nil];
    unsigned long long freeBytes = [attributes[NSFileSystemFreeSize] unsignedLongLongValue];
    NSMutableDictionary *payload = [@{
        @"version": TLAPSED_VERSION_STRING,
        @"pid": @(getpid()),
        @"storageRoot": config.storageRoot ?: @"",
        @"freeBytes": @(freeBytes),
        @"freeText": attributes ? TLFormatBytes(freeBytes) : @"未知",
        @"minFreeGB": @(config.minFreeGB),
        @"listeners": self.listenAddresses ?: @[],
        @"projectCount": @(config.projects.count),
        @"enabledCount": @(config.enabledProjectCount),
        @"features": @{
            @"capture": @YES,
            @"encode": (self.encoder ? @YES : @NO),
            @"upload": (self.uploader ? @YES : @NO),
            @"cleanup": (self.encoder ? @YES : @NO),
        },
    } mutableCopy];
    if (startedAt) {
        payload[@"startedAt"] = started;
        payload[@"uptimeSeconds"] = @((NSInteger)[[NSDate date] timeIntervalSinceDate:startedAt]);
    }
    NSDictionary *battery = [self battery];
    if (battery) {
        payload[@"battery"] = battery;
    }
    return [self json:200 object:payload];
}

- (NSDictionary *)battery {
    TLBatteryReading reading = TLReadBattery();
    if (!reading.valid) {
        return nil;
    }
    NSMutableDictionary *battery = [NSMutableDictionary dictionary];
    battery[@"percent"] = @(reading.percent);
    battery[@"charging"] = @(reading.charging);
    if (reading.hasTemperature) {
        battery[@"temperatureC"] = @(reading.celsius);
    }
    return battery;
}

- (TLWebResponse *)projectList {
    TLConfig *config = [self currentConfig];
    NSDictionary *snapshot = [self.state snapshot];
    NSDictionary *states = [snapshot[@"projects"] isKindOfClass:[NSDictionary class]] ? snapshot[@"projects"] : @{};
    NSMutableArray *projects = [NSMutableArray array];
    for (TLProject *project in config.projects) {
        NSMutableDictionary *entry = [[project dictionaryRepresentation] mutableCopy];
        NSDictionary *state = [states[project.projectID] isKindOfClass:[NSDictionary class]] ? states[project.projectID] : @{};
        entry[@"state"] = @{
            @"frameCount": @([state[TLStateFrameCount] integerValue]),
            @"lastCaptureAt": [state[TLStateLastCaptureAt] isKindOfClass:[NSString class]] ? state[TLStateLastCaptureAt] : @"",
            @"lastFile": [state[TLStateLastFile] isKindOfClass:[NSString class]] ? state[TLStateLastFile] : @"",
            @"lastError": [state[TLStateLastError] isKindOfClass:[NSString class]] ? state[TLStateLastError] : @"",
            @"consecutiveFailures": @([state[TLStateConsecutiveFailures] integerValue]),
            @"lastSkip": [state[@"lastSkip"] isKindOfClass:[NSString class]] ? state[@"lastSkip"] : @"",
        };
        [projects addObject:entry];
    }
    return [self json:200 object:@{@"projects": projects}];
}

- (TLWebResponse *)projectMethod:(NSString *)method
                      projectID:(NSString *)projectID
                          parts:(NSArray<NSString *> *)parts
                          query:(NSDictionary<NSString *, NSString *> *)query
                        headers:(NSDictionary<NSString *, NSString *> *)headers
                           body:(NSData *)body {
    NSString *safeID = TLSanitizeProjectID(projectID);
    if (!safeID || ![safeID isEqualToString:projectID]) {
        return [self jsonError:404 message:@"没有这个项目"];
    }
    if (parts.count == 3 && [method isEqualToString:@"PUT"]) {
        return [self updateProject:safeID body:body];
    }
    if (parts.count == 3 && [method isEqualToString:@"DELETE"]) {
        return [self deleteProject:safeID];
    }
    if (parts.count == 4 && [parts[3] isEqualToString:@"pause"] && [method isEqualToString:@"POST"]) {
        return [self setProject:safeID enabled:NO];
    }
    if (parts.count == 4 && [parts[3] isEqualToString:@"resume"] && [method isEqualToString:@"POST"]) {
        return [self setProject:safeID enabled:YES];
    }
    if (parts.count == 4 && [parts[3] isEqualToString:@"snap"] && [method isEqualToString:@"POST"]) {
        return [self snapProject:safeID];
    }
    if (parts.count == 4 && [parts[3] isEqualToString:@"latest.jpg"] && [method isEqualToString:@"GET"]) {
        return [self latestImage:safeID];
    }
    if (parts.count == 4 && [parts[3] isEqualToString:@"frames"] && [method isEqualToString:@"GET"]) {
        return [self frames:safeID date:query[@"date"]];
    }
    if (parts.count == 6 && [parts[3] isEqualToString:@"frames"] && [method isEqualToString:@"DELETE"]) {
        return [self deleteFrame:safeID day:parts[4] name:parts[5]];
    }
    if (parts.count == 4 && [parts[3] isEqualToString:@"videos"] && [method isEqualToString:@"GET"]) {
        return [self videos:safeID];
    }
    if (parts.count == 4 && [parts[3] isEqualToString:@"encode"] && [method isEqualToString:@"POST"]) {
        return [self encodeProject:safeID];
    }
    if ([method isEqualToString:@"GET"] && parts.count >= 5 && [parts[3] isEqualToString:@"media"]) {
        return [self media:safeID parts:parts query:query headers:headers];
    }
    return [self jsonError:404 message:@"没有这个页面"];
}

- (TLWebResponse *)createProject:(NSData *)body {
    NSDictionary *patch = [self jsonObject:body];
    if (!patch) {
        return [self jsonError:400 message:@"需要 JSON 对象"];
    }
    NSString *projectID = [patch[@"id"] isKindOfClass:[NSString class]] ? TLSanitizeProjectID(patch[@"id"]) : nil;
    if (!projectID) {
        return [self jsonError:400 message:@"项目 id 只能包含字母、数字、下划线和减号"];
    }
    NSError *error = nil;
    BOOL ok = [TLConfig updateFileAtPath:self.configPath mutate:^BOOL(NSMutableDictionary *root, NSError **mutateError) {
        NSMutableArray *projects = [root[@"projects"] isKindOfClass:[NSMutableArray class]] ? root[@"projects"] : nil;
        if (!projects) {
            projects = [NSMutableArray array];
            root[@"projects"] = projects;
        }
        for (id entry in projects) {
            if ([entry isKindOfClass:[NSDictionary class]] && [entry[@"id"] isEqualToString:projectID]) {
                if (mutateError) {
                    *mutateError = TLError(TLErrorCodeConfig, @"项目 id 已存在");
                }
                return NO;
            }
        }
        NSMutableDictionary *project = [@{
            @"id": projectID,
            @"name": @"",
            @"enabled": @NO,
            @"capture": [@{@"interval": @300, @"resolution": @"1920x1440", @"orientation": @"auto", @"shutterSound": @YES, @"nightSkip": @NO} mutableCopy],
            @"encode": [@{@"every": @"daily", @"at": @"23:30", @"mode": @"daily", @"fps": @30} mutableCopy],
            @"upload": [NSMutableArray array],
            @"cleanup": [@{@"keepFramesDays": @14} mutableCopy],
        } mutableCopy];
        if (![self applyPatch:patch toProject:project error:mutateError]) {
            return NO;
        }
        [projects addObject:project];
        return YES;
    } error:&error];
    if (!ok) {
        return [self jsonError:400 message:error.localizedDescription ?: @"无法新建项目"];
    }
    [self reloadWrittenConfig];
    return [self json:200 object:@{@"id": projectID}];
}

- (TLWebResponse *)updateProject:(NSString *)projectID body:(NSData *)body {
    NSDictionary *patch = [self jsonObject:body];
    if (!patch) {
        return [self jsonError:400 message:@"需要 JSON 对象"];
    }
    if ([patch[@"id"] isKindOfClass:[NSString class]] && ![patch[@"id"] isEqualToString:projectID]) {
        return [self jsonError:400 message:@"不能修改项目 id"];
    }
    NSError *error = nil;
    BOOL ok = [TLConfig updateFileAtPath:self.configPath mutate:^BOOL(NSMutableDictionary *root, NSError **mutateError) {
        NSMutableDictionary *project = [self mutableProject:projectID inRoot:root];
        if (!project) {
            if (mutateError) {
                *mutateError = TLError(TLErrorCodeConfig, @"没有这个项目");
            }
            return NO;
        }
        return [self applyPatch:patch toProject:project error:mutateError];
    } error:&error];
    if (!ok) {
        return [self jsonError:400 message:error.localizedDescription ?: @"无法保存项目"];
    }
    [self reloadWrittenConfig];
    return [self json:200 object:@{@"id": projectID}];
}

- (TLWebResponse *)setProject:(NSString *)projectID enabled:(BOOL)enabled {
    NSError *error = nil;
    BOOL ok = [TLConfig updateFileAtPath:self.configPath mutate:^BOOL(NSMutableDictionary *root, NSError **mutateError) {
        NSMutableDictionary *project = [self mutableProject:projectID inRoot:root];
        if (!project) {
            if (mutateError) {
                *mutateError = TLError(TLErrorCodeConfig, @"没有这个项目");
            }
            return NO;
        }
        project[@"enabled"] = @(enabled);
        return YES;
    } error:&error];
    if (!ok) {
        return [self jsonError:404 message:error.localizedDescription ?: @"没有这个项目"];
    }
    [self reloadWrittenConfig];
    return [self json:200 object:@{@"id": projectID, @"enabled": @(enabled)}];
}

- (TLWebResponse *)deleteProject:(NSString *)projectID {
    NSError *error = nil;
    BOOL ok = [TLConfig updateFileAtPath:self.configPath mutate:^BOOL(NSMutableDictionary *root, NSError **mutateError) {
        NSMutableArray *projects = [root[@"projects"] isKindOfClass:[NSMutableArray class]] ? root[@"projects"] : nil;
        NSUInteger index = NSNotFound;
        for (NSUInteger cursor = 0; projects && cursor < projects.count; cursor++) {
            id entry = projects[cursor];
            if ([entry isKindOfClass:[NSDictionary class]] && [entry[@"id"] isEqualToString:projectID]) {
                index = cursor;
                break;
            }
        }
        if (index == NSNotFound) {
            if (mutateError) {
                *mutateError = TLError(TLErrorCodeConfig, @"没有这个项目");
            }
            return NO;
        }
        [projects removeObjectAtIndex:index];
        return YES;
    } error:&error];
    if (!ok) {
        return [self jsonError:404 message:error.localizedDescription ?: @"没有这个项目"];
    }
    [self reloadWrittenConfig];
    return [self json:200 object:@{@"deleted": @YES, @"keptFiles": @YES}];
}

- (NSMutableDictionary *)mutableProject:(NSString *)projectID inRoot:(NSMutableDictionary *)root {
    NSMutableArray *projects = [root[@"projects"] isKindOfClass:[NSMutableArray class]] ? root[@"projects"] : nil;
    for (id entry in projects) {
        if ([entry isKindOfClass:[NSMutableDictionary class]] && [entry[@"id"] isEqualToString:projectID]) {
            return entry;
        }
    }
    return nil;
}

- (BOOL)applyPatch:(NSDictionary *)patch toProject:(NSMutableDictionary *)project error:(NSError **)error {
    NSSet *top = [NSSet setWithObjects:@"id", @"name", @"enabled", @"capture", @"encode", @"upload", @"cleanup", @"state", nil];
    for (NSString *key in patch) {
        if (![top containsObject:key]) {
            if (error) {
                *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"项目含有未知字段 %@", key]);
            }
            return NO;
        }
    }
    if ([patch[@"name"] isKindOfClass:[NSString class]]) {
        project[@"name"] = patch[@"name"];
    }
    if ([patch[@"enabled"] isKindOfClass:[NSNumber class]]) {
        project[@"enabled"] = patch[@"enabled"];
    }
    if (patch[@"capture"]) {
        if (![patch[@"capture"] isKindOfClass:[NSDictionary class]]) {
            if (error) {
                *error = TLError(TLErrorCodeConfig, @"capture 必须是对象");
            }
            return NO;
        }
        NSMutableDictionary *capture = [project[@"capture"] isKindOfClass:[NSMutableDictionary class]] ? project[@"capture"] : [NSMutableDictionary dictionary];
        NSArray *keys = @[@"interval", @"resolution", @"lockFocus", @"lockExposure", @"lockWhiteBalance", @"jpegQuality", @"shutterSound", @"settleSeconds", @"orientation", @"nightSkip"];
        if (![self copyKeys:keys from:patch[@"capture"] to:capture path:@"capture" error:error]) {
            return NO;
        }
        project[@"capture"] = capture;
    }
    if (patch[@"encode"]) {
        if (![patch[@"encode"] isKindOfClass:[NSDictionary class]]) {
            if (error) {
                *error = TLError(TLErrorCodeConfig, @"encode 必须是对象");
            }
            return NO;
        }
        NSMutableDictionary *encode = [project[@"encode"] isKindOfClass:[NSMutableDictionary class]] ? project[@"encode"] : [NSMutableDictionary dictionary];
        if (![self copyKeys:@[@"every", @"at", @"mode", @"fps", @"targetDuration"] from:patch[@"encode"] to:encode path:@"encode" error:error]) {
            return NO;
        }
        project[@"encode"] = encode;
    }
    if (patch[@"cleanup"]) {
        if (![patch[@"cleanup"] isKindOfClass:[NSDictionary class]]) {
            if (error) {
                *error = TLError(TLErrorCodeConfig, @"cleanup 必须是对象");
            }
            return NO;
        }
        NSMutableDictionary *cleanup = [project[@"cleanup"] isKindOfClass:[NSMutableDictionary class]] ? project[@"cleanup"] : [NSMutableDictionary dictionary];
        if (![self copyKeys:@[@"keepFramesDays"] from:patch[@"cleanup"] to:cleanup path:@"cleanup" error:error]) {
            return NO;
        }
        project[@"cleanup"] = cleanup;
    }
    if (patch[@"upload"]) {
        if (![patch[@"upload"] isKindOfClass:[NSArray class]]) {
            if (error) {
                *error = TLError(TLErrorCodeConfig, @"upload 必须是数组");
            }
            return NO;
        }
        project[@"upload"] = patch[@"upload"];
    }
    return YES;
}

- (BOOL)copyKeys:(NSArray<NSString *> *)keys from:(NSDictionary *)source to:(NSMutableDictionary *)target path:(NSString *)path error:(NSError **)error {
    NSSet *allowed = [NSSet setWithArray:keys];
    for (NSString *key in source) {
        if (![allowed containsObject:key]) {
            if (error) {
                *error = TLError(TLErrorCodeConfig, [NSString stringWithFormat:@"%@ 含有未知字段 %@", path, key]);
            }
            return NO;
        }
        if (source[key] == [NSNull null]) {
            [target removeObjectForKey:key];
            continue;
        }
        target[key] = source[key];
    }
    return YES;
}

- (void)reloadWrittenConfig {
    NSError *error = nil;
    TLConfig *config = [TLConfig configWithContentsOfFile:self.configPath error:&error];
    if (config) {
        [self replaceConfigAfterWrite:config];
    }
}

- (TLWebResponse *)snapProject:(NSString *)projectID {
    TLConfig *config = [self currentConfig];
    TLProject *project = [config projectWithID:projectID];
    if (!project) {
        return [self jsonError:404 message:@"没有这个项目"];
    }
    if (!self.snap) {
        return [self jsonError:503 message:@"这台进程没有连接摄像头"];
    }
    TLCaptureResult *result = self.snap(project);
    if (!result) {
        return [self jsonError:503 message:@"拍照没有返回结果"];
    }
    NSString *outcome = @"failed";
    NSInteger status = 500;
    switch (result.outcome) {
        case TLCaptureOutcomeSaved:
            outcome = @"saved";
            status = 200;
            break;
        case TLCaptureOutcomeSkippedNight:
            outcome = @"skippedNight";
            status = 409;
            break;
        case TLCaptureOutcomeSkippedDark:
            outcome = @"skippedDark";
            status = 409;
            break;
        case TLCaptureOutcomeSkippedStorage:
            outcome = @"skippedStorage";
            status = 409;
            break;
        case TLCaptureOutcomeFailed:
            outcome = @"failed";
            status = 500;
            break;
    }
    return [self json:status object:@{
        @"outcome": outcome,
        @"message": result.message ?: @"",
        @"relativePath": result.relativePath ?: @"",
        @"width": @(result.width),
        @"height": @(result.height),
    }];
}

- (TLWebResponse *)latestImage:(NSString *)projectID {
    TLConfig *config = [self currentConfig];
    if (![config projectWithID:projectID]) {
        return [self jsonError:404 message:@"没有这个项目"];
    }
    NSString *relative = [self.state stringForProject:projectID key:TLStateLastFile];
    NSString *path = nil;
    if (relative.length > 0) {
        path = TLWebSafePath(config.storageRoot, [relative componentsSeparatedByString:@"/"]);
    }
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        path = [self newestFrame:projectID root:config.storageRoot];
    }
    return [self file:path type:@"image/jpeg"];
}

- (NSString *)newestFrame:(NSString *)projectID root:(NSString *)root {
    NSString *frames = TLWebSafePath(root, @[@"projects", projectID, @"frames"]);
    if (!frames) {
        return nil;
    }
    NSString *best = nil;
    NSArray<NSString *> *days = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:frames error:nil];
    for (NSString *day in days) {
        if (!TLPathComponent(day)) {
            continue;
        }
        NSString *directory = TLWebSafePath(root, @[@"projects", projectID, @"frames", day]);
        NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
        for (NSString *name in names) {
            if (![name.lowercaseString hasSuffix:@".jpg"] || !TLPathComponent(name)) {
                continue;
            }
            NSString *relative = [NSString stringWithFormat:@"%@/%@", day, name];
            if (!best || [relative compare:best] == NSOrderedDescending) {
                best = relative;
            }
        }
    }
    if (!best) {
        return nil;
    }
    return TLWebSafePath(root, @[@"projects", projectID, @"frames", [best componentsSeparatedByString:@"/"][0], [best componentsSeparatedByString:@"/"][1]]);
}

- (TLWebResponse *)frames:(NSString *)projectID date:(NSString *)date {
    TLConfig *config = [self currentConfig];
    if (![config projectWithID:projectID]) {
        return [self jsonError:404 message:@"没有这个项目"];
    }
    NSString *frames = TLWebSafePath(config.storageRoot, @[@"projects", projectID, @"frames"]);
    NSMutableArray<NSString *> *dates = [NSMutableArray array];
    for (NSString *day in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:frames error:nil]) {
        if (day.length == 8 && TLPathComponent(day)) {
            [dates addObject:day];
        }
    }
    [dates sortUsingSelector:@selector(compare:)];
    if (date.length == 0) {
        return [self json:200 object:@{@"dates": [[dates reverseObjectEnumerator] allObjects]}];
    }
    if (date.length != 8 || !TLPathComponent(date)) {
        return [self jsonError:400 message:@"日期格式应为 YYYYMMDD"];
    }
    NSString *directory = TLWebSafePath(config.storageRoot, @[@"projects", projectID, @"thumbs", date]);
    NSString *kind = @"thumbs";
    if (![[NSFileManager defaultManager] fileExistsAtPath:directory]) {
        directory = TLWebSafePath(config.storageRoot, @[@"projects", projectID, @"frames", date]);
        kind = @"frames";
    }
    NSMutableArray *framesOut = [NSMutableArray array];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil]) {
        if (![name.lowercaseString hasSuffix:@".jpg"] || !TLPathComponent(name)) {
            continue;
        }
        NSString *stamp = [name stringByDeletingPathExtension];
        NSRange suffix = [stamp rangeOfString:@"_"];
        if (suffix.location != NSNotFound) {
            stamp = [stamp substringToIndex:suffix.location];
        }
        NSString *label = stamp;
        if (stamp.length == 6) {
            label = [NSString stringWithFormat:@"%@:%@:%@", [stamp substringToIndex:2], [stamp substringWithRange:NSMakeRange(2, 2)], [stamp substringFromIndex:4]];
        }
        NSString *original = TLWebSafePath(config.storageRoot, @[@"projects", projectID, @"frames", date, name]);
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:original error:nil];
        [framesOut addObject:@{
            @"name": name,
            @"label": label,
            @"kind": kind,
            @"bytes": @([attributes[NSFileSize] unsignedLongLongValue]),
        }];
    }
    [framesOut sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [right[@"name"] compare:left[@"name"]];
    }];
    return [self json:200 object:@{@"date": date, @"frames": framesOut}];
}

- (TLWebResponse *)deleteFrame:(NSString *)projectID day:(NSString *)day name:(NSString *)name {
    TLConfig *config = [self currentConfig];
    if (![config projectWithID:projectID]) {
        return [self jsonError:404 message:@"没有这个项目"];
    }
    if (day.length != 8 || ![name.lowercaseString hasSuffix:@".jpg"]) {
        return [self jsonError:400 message:@"只能删除一张 JPEG"];
    }
    NSInteger removed = TLRemoveCapturedFrame(config.storageRoot, projectID, day, name);
    if (removed <= 0) {
        return [self jsonError:404 message:@"没有这张照片"];
    }
    NSString *relative = [NSString stringWithFormat:@"projects/%@/frames/%@/%@", projectID, day, name];
    if ([[self.state stringForProject:projectID key:TLStateLastFile] isEqualToString:relative]) {
        [self.state updateProject:projectID values:@{TLStateLastFile: @""} error:nil];
    }
    return [self json:200 object:@{@"deleted": @YES, @"removed": @(removed)}];
}

- (TLWebResponse *)videos:(NSString *)projectID {
    TLConfig *config = [self currentConfig];
    if (![config projectWithID:projectID]) {
        return [self jsonError:404 message:@"没有这个项目"];
    }
    NSString *directory = TLWebSafePath(config.storageRoot, @[@"projects", projectID, @"videos"]);
    NSMutableArray *videos = [NSMutableArray array];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil]) {
        if ([name.lowercaseString hasSuffix:@".mp4"] && TLPathComponent(name)) {
            [videos addObject:@{@"name": name}];
        }
    }
    return [self json:200 object:@{@"videos": videos, @"encodeEnabled": (self.encoder ? @YES : @NO)}];
}

- (TLWebResponse *)encodeProject:(NSString *)projectID {
    if (!self.encoder) {
        return [self jsonError:501 message:@"合成还没实现。编码设置会保存，后续阶段才会生成视频"];
    }
    TLConfig *config = [self currentConfig];
    TLProject *project = [config projectWithID:projectID];
    if (!project) {
        return [self jsonError:404 message:@"没有这个项目"];
    }
    TLEncodeResult *result = TLPerformEncodeJob(self.encoder, self.uploader, self.state, config, project, [NSDate date], [NSTimeZone localTimeZone]);
    if (result.empty) {
        return [self jsonError:409 message:result.message ?: @"没有可合成的照片"];
    }
    if (!result.succeeded) {
        return [self jsonError:500 message:result.message ?: @"合成失败"];
    }
    return [self json:200 object:@{
        @"ok": @YES,
        @"message": result.message ?: @"已合成",
        @"relativePath": result.relativePath ?: @"",
        @"width": @(result.width),
        @"height": @(result.height),
        @"frames": @(result.frameCount),
        @"removedFrames": @(result.removedFrames),
    }];
}

- (TLWebResponse *)uploadNamed:(NSString *)name {
    if (!TLSafePathComponent(name) || ![name.lowercaseString hasSuffix:@".mp4"]) {
        return [self jsonError:404 message:@"没有这个视频"];
    }
    if (!self.uploader) {
        return [self jsonError:501 message:@"上传还没实现。视频生成后可以在后续阶段手动或自动上传"];
    }
    TLConfig *config = [self currentConfig];
    TLProject *found = nil;
    NSString *path = nil;
    for (TLProject *project in config.projects) {
        NSString *candidate = TLWebSafePath(config.storageRoot, @[@"projects", project.projectID, @"videos", name]);
        if (candidate && [[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            if (found) {
                return [self jsonError:409 message:@"有多个项目含有同名视频"];
            }
            found = project;
            path = candidate;
        }
    }
    if (!found) {
        return [self jsonError:404 message:@"没有这个视频"];
    }
    NSString *summary = [self.uploader uploadFileAtPath:path project:found config:config];
    BOOL failed = [summary containsString:@"失败"] && ![summary containsString:@"已进入重试队列"];
    if (failed && ![summary containsString:@"已上传"]) {
        return [self jsonError:500 message:summary];
    }
    return [self json:200 object:@{@"ok": @YES, @"message": summary ?: @"已处理"}];
}

- (TLWebResponse *)media:(NSString *)projectID parts:(NSArray<NSString *> *)parts query:(NSDictionary<NSString *, NSString *> *)query headers:(NSDictionary<NSString *, NSString *> *)headers {
    TLConfig *config = [self currentConfig];
    if (![config projectWithID:projectID]) {
        return [self jsonError:404 message:@"没有这个项目"];
    }
    NSString *kind = parts.count > 4 ? parts[4] : @"";
    NSArray<NSString *> *components = nil;
    NSString *type = nil;
    if (([kind isEqualToString:@"frames"] || [kind isEqualToString:@"thumbs"]) && parts.count == 7) {
        components = @[@"projects", projectID, kind, parts[5], parts[6]];
        type = @"image/jpeg";
        if (![parts[6].lowercaseString hasSuffix:@".jpg"]) {
            return [self jsonError:404 message:@"没有这个文件"];
        }
    } else if ([kind isEqualToString:@"videos"] && parts.count == 6) {
        components = @[@"projects", projectID, @"videos", parts[5]];
        type = @"video/mp4";
        if (![parts[5].lowercaseString hasSuffix:@".mp4"]) {
            return [self jsonError:404 message:@"没有这个文件"];
        }
    } else {
        return [self jsonError:404 message:@"没有这个文件"];
    }
    TLWebResponse *response = [self openedFile:TLOpenWebFile(config.storageRoot, components) type:type range:headers[@"range"]];
    if ((response.status == 200 || response.status == 206) && [query[@"download"] isEqualToString:@"1"]) {
        response.fileName = components.lastObject;
    }
    return response;
}

- (TLWebResponse *)logs:(NSDictionary<NSString *, NSString *> *)query {
    NSInteger tail = query[@"tail"].integerValue;
    if (tail <= 0) {
        tail = 200;
    }
    if (tail > 400) {
        tail = 400;
    }
    TLConfig *config = [self currentConfig];
    NSString *path = TLWebSafePath(config.storageRoot, @[@"logs", @"tlapsed.log"]);
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length > 256 * 1024) {
        data = [data subdataWithRange:NSMakeRange(data.length - 256 * 1024, 256 * 1024)];
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    if (lines.count > 0 && lines.lastObject.length == 0) {
        lines = [lines subarrayWithRange:NSMakeRange(0, lines.count - 1)];
    }
    if ((NSInteger)lines.count > tail) {
        lines = [lines subarrayWithRange:NSMakeRange(lines.count - (NSUInteger)tail, (NSUInteger)tail)];
    }
    return [self json:200 object:@{@"lines": lines ?: @[]}];
}

- (NSString *)webRoot {
    if (self.indexFileOverride.length > 0) { return self.indexFileOverride.stringByDeletingLastPathComponent; }
    NSString *primary = [[self currentConfig].storageRoot stringByAppendingPathComponent:@"web"];
    int fd = TLOpenWebFile(primary, @[@"index.html"]);
    if (fd >= 0) { close(fd); return primary; }
    return @"/var/mobile/Timelapse/web";
}

- (TLWebResponse *)staticResponse:(NSString *)path {
    NSDictionary *types = @{@"html": @"text/html; charset=utf-8", @"js": @"text/javascript; charset=utf-8",
                           @"css": @"text/css; charset=utf-8", @"svg": @"image/svg+xml",
                           @"woff": @"font/woff", @"woff2": @"font/woff2"};
    NSString *relative = [path isEqualToString:@"/"] ? @"index.html" : [path substringFromIndex:1];
    // override 只决定测试资源根：首页及 assets 始终来自同一个目录。
    if ([relative isEqualToString:@"index.html"] && self.indexFileOverride.length > 0) {
        relative = self.indexFileOverride.lastPathComponent;
    }
    NSString *type = types[relative.pathExtension.lowercaseString];
    if (!type) { return [self jsonError:404 message:@"没有这个资源"]; }
    return [self openedFile:TLOpenWebFile([self webRoot], [relative componentsSeparatedByString:@"/"]) type:type range:nil];
}

- (TLWebResponse *)file:(NSString *)path type:(NSString *)type {
    // 最新图的路径也使用逐级目录校验，媒体不能借符号链接越过 storageRoot。
    NSString *root = [self currentConfig].storageRoot;
    NSString *prefix = [root stringByAppendingString:@"/"];
    if (![path hasPrefix:prefix]) { return [self jsonError:404 message:@"没有这个文件"]; }
    NSArray *parts = [[path substringFromIndex:prefix.length] componentsSeparatedByString:@"/"];
    return [self openedFile:TLOpenWebFile(root, parts) type:type range:nil];
}

- (TLWebResponse *)openedFile:(int)fd type:(NSString *)type range:(NSString *)range {
    struct stat info;
    if (fd < 0) { return [self jsonError:404 message:@"没有这个文件"]; }
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0) {
        close(fd);
        return [self jsonError:404 message:@"没有这个文件"];
    }
    unsigned long long size = (unsigned long long)info.st_size;
    if ([type isEqualToString:@"video/mp4"]) {
        unsigned long long offset = 0, length = size;
        if (range && !TLVideoRange(range, size, &offset, &length)) {
            close(fd);
            TLWebResponse *error = [self jsonError:416 message:@"视频区间无效，只支持单个字节区间"];
            error.acceptsRanges = YES;
            error.contentRange = [NSString stringWithFormat:@"bytes */%llu", size];
            return error;
        }
        TLWebResponse *response = [[TLWebResponse alloc] init];
        response.status = range ? 206 : 200;
        response.type = type;
        response.fileFD = fd;
        response.fileOffset = offset;
        response.fileLength = length;
        response.acceptsRanges = YES;
        if (range) { response.contentRange = [NSString stringWithFormat:@"bytes %llu-%llu/%llu", offset, offset + length - 1, size]; }
        return response;
    }
    if (size > TLWebMaxImageBytes) { close(fd); return [self jsonError:413 message:@"文件太大"]; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = read(fd, (uint8_t *)data.mutableBytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) { continue; }
        if (count <= 0) { close(fd); return [self jsonError:404 message:@"文件读取失败"]; }
        offset += (NSUInteger)count;
    }
    close(fd);
    TLWebResponse *response = [[TLWebResponse alloc] init];
    response.status = 200;
    response.type = type;
    response.body = data;
    return response;
}

- (NSDictionary *)jsonObject:(NSData *)body {
    if (body.length == 0) {
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

- (TLWebResponse *)json:(NSInteger)status object:(id)object {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil] ?: [NSData data];
    TLWebResponse *response = [[TLWebResponse alloc] init];
    response.status = status;
    response.type = @"application/json; charset=utf-8";
    response.body = data;
    return response;
}

- (TLWebResponse *)jsonError:(NSInteger)status message:(NSString *)message {
    return [self json:status object:@{@"error": message ?: @"请求失败"}];
}

- (TLWebResponse *)text:(NSInteger)status message:(NSString *)message {
    TLWebResponse *response = [[TLWebResponse alloc] init];
    response.status = status;
    response.type = @"text/plain; charset=utf-8";
    response.body = [[message stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    return response;
}

- (TLWebResponse *)empty:(NSInteger)status {
    TLWebResponse *response = [[TLWebResponse alloc] init];
    response.status = status;
    response.type = @"text/plain; charset=utf-8";
    response.body = [NSData data];
    return response;
}

@end
