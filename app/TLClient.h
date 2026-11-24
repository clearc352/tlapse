#import <Foundation/Foundation.h>

typedef void (^TLReply)(NSDictionary *payload, NSError *error);
typedef void (^TLMediaReply)(NSData *data, NSError *error);

extern NSString *const TLHTTPErrorDomain;
extern NSString *TLPathSegment(NSString *value);

@interface TLClient : NSObject
@property (nonatomic, readonly) NSURL *server;
+ (NSURL *)serverURLForAddress:(NSString *)address;
- (instancetype)initWithServer:(NSURL *)server;
- (void)request:(NSString *)method path:(NSString *)path body:(NSDictionary *)body timeout:(NSTimeInterval)timeout reply:(TLReply)reply;
- (void)getMedia:(NSString *)path reply:(TLMediaReply)reply;
- (NSURL *)URLForPath:(NSString *)path;
- (NSArray<NSHTTPCookie *> *)cookiesForURL:(NSURL *)url;
- (void)invalidate;
@end
