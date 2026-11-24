#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TLErrorDomain;

typedef NS_ENUM(NSInteger, TLErrorCode) {
    TLErrorCodeConfig = 1,
    TLErrorCodeCamera = 2,
    TLErrorCodeStorage = 3,
    TLErrorCodeBusy = 4,
    TLErrorCodeInternal = 5,
};

NSError *TLError(TLErrorCode code, NSString *message);

typedef struct {
    BOOL valid;
    NSInteger percent;
    BOOL charging;
    BOOL hasTemperature;
    double celsius;
} TLBatteryReading;

TLBatteryReading TLReadBattery(void);

BOOL TLStorageRootAllowed(NSString *root);
BOOL TLEnsureDirectory(NSString *path, NSError **error);
BOOL TLWriteDataAtomic(NSData *data, NSString *path, NSError **error);
NSString *TLUniqueFilePath(NSString *path);
double TLFreeGigabytes(NSString *path);
int TLTryLockProjectMedia(NSString *root, BOOL exclusive);

/// When running as root, create storageRoot and switch to the mobile user.
/// Launchd starts the daemon as root so it can raise its jetsam limit first.
BOOL TLDropToMobileUser(NSString *storageRoot, NSError **error);

@interface TLFileLock : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (BOOL)lockWithTimeout:(NSTimeInterval)timeout error:(NSError **)error;
- (void)unlock;
@end

NS_ASSUME_NONNULL_END
