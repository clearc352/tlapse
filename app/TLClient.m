#import "TLClient.h"

NSString *const TLHTTPErrorDomain = @"com.ddxyl.tlapse.http";

NSString *TLPathSegment(NSString *value) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

@interface TLClient () <NSURLSessionTaskDelegate>
@property (nonatomic) NSURLSession *session;
@end

@implementation TLClient

+ (NSURL *)serverURLForAddress:(NSString *)address {
    address = [address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!address.length) return nil;
    BOOL hasScheme = [address containsString:@"://"];
    NSURLComponents *parts = [NSURLComponents componentsWithString:hasScheme ? address : [@"http://" stringByAppendingString:address]];
    NSString *scheme = parts.scheme.lowercaseString;
    if ((![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) ||
        !parts.host.length || parts.user || parts.password || parts.query || parts.fragment ||
        (parts.path.length && ![parts.path isEqualToString:@"/"]) ||
        (parts.port && (parts.port.integerValue < 1 || parts.port.integerValue > 65535))) return nil;
    parts.scheme = scheme;
    parts.path = @"";
    if (!hasScheme && !parts.port) parts.port = @8080;
    return parts.URL;
}

- (instancetype)initWithServer:(NSURL *)server {
    if ((self = [super init])) {
        _server = [server copy];
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    }
    return self;
}

- (NSURL *)URLForPath:(NSString *)path {
    return [NSURL URLWithString:[self.server.absoluteString stringByAppendingString:path]];
}

- (NSArray<NSHTTPCookie *> *)cookiesForURL:(NSURL *)url {
    return [self.session.configuration.HTTPCookieStorage cookiesForURL:url] ?: @[];
}

- (void)invalidate {
    [self.session invalidateAndCancel];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}

- (void)send:(NSString *)method path:(NSString *)path body:(NSDictionary *)body
     timeout:(NSTimeInterval)timeout json:(BOOL)json reply:(TLReply)reply media:(TLMediaReply)media {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self URLForPath:path]];
    request.HTTPMethod = method;
    request.timeoutInterval = timeout;
    if (![method isEqualToString:@"GET"]) [request setValue:@"1" forHTTPHeaderField:@"X-Tlapse-Request"];
    if (body) {
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    }
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        BOOL success = status >= 200 && status < 300;
        id value = (json || !success) && data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSDictionary *payload = [value isKindOfClass:NSDictionary.class] ? value : nil;
        NSError *error = networkError;
        if (!error && (!success || (json && !payload))) {
            NSString *message = payload[@"error"] ?: payload[@"message"];
            if (![message isKindOfClass:NSString.class] || !message.length) {
                message = success ? @"服务器响应无效" : [NSString stringWithFormat:@"请求失败（HTTP %ld）", (long)status];
            }
            error = [NSError errorWithDomain:TLHTTPErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey: message}];
        } else if (error && error.code == NSURLErrorTimedOut) {
            error = [NSError errorWithDomain:error.domain code:error.code
                                     userInfo:@{NSLocalizedDescriptionKey: @"等待手机响应超时，操作结果尚未确认"}];
        } else if (error && error.code != NSURLErrorCancelled) {
            error = [NSError errorWithDomain:error.domain code:error.code
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法连接手机，请检查地址和守护进程。"}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (reply) reply(payload, error);
            if (media) media(error ? nil : data, error);
        });
    }] resume];
}

- (void)request:(NSString *)method path:(NSString *)path body:(NSDictionary *)body timeout:(NSTimeInterval)timeout reply:(TLReply)reply {
    [self send:method path:path body:body timeout:timeout json:YES reply:reply media:nil];
}

- (void)getMedia:(NSString *)path reply:(TLMediaReply)reply {
    [self send:@"GET" path:path body:nil timeout:20 json:NO reply:nil media:reply];
}

@end
