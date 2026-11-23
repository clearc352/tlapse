// 复用主机图像夹具与类型，真正启动 TLWeb；仅相机结果由本机生成 JPEG 模拟。
#define main TLHostSuiteMain
#include "test_host.m"
#undef main
#import "TLLog.h"

@interface TLWebServer (FixtureAccess)
- (TLConfig *)currentConfig;
@end
@interface TLFixtureServer : TLWebServer
@property (nonatomic, copy) NSString *fixtureRoot;
@end
@implementation TLFixtureServer
- (TLConfig *)currentConfig {
    TLConfig *config = [super currentConfig];
    // 正式配置仍验证 /var/mobile；仅此进程把存储映射到独立临时目录。
    if (![config.storageRoot isEqualToString:self.fixtureRoot]) {
        [config setValue:self.fixtureRoot forKey:@"storageRoot"];
    }
    return config;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "用法：tlapse-web-fixture <临时目录> <生产index.html>\n"); return 2; }
        // 规范化并解析现有链接后再判定，避免 /tmp/../ 或目录链接绕过临时数据边界。
        NSString *root = [[NSString stringWithUTF8String:argv[1]] stringByStandardizingPath].stringByResolvingSymlinksInPath;
        BOOL temporary = NO;
        for (NSString *base in @[NSTemporaryDirectory(), @"/tmp"]) {
            NSString *prefix = [base.stringByStandardizingPath.stringByResolvingSymlinksInPath stringByAppendingString:@"/"];
            if ([root hasPrefix:prefix]) { temporary = YES; break; }
        }
        if (!temporary) {
            fprintf(stderr, "夹具只允许系统临时目录中的独立子目录\n"); return 2;
        }
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"logs"] withIntermediateDirectories:YES attributes:nil error:nil];
        TLLogSetup([root stringByAppendingPathComponent:@"logs/tlapsed.log"]);
        NSString *configPath = [root stringByAppendingPathComponent:@"config.json"];
        NSDictionary *document = @{
            @"server": @{@"token": @"local-fixture-token-only", @"port": @8080},
            @"storage": @{@"root": @"/var/mobile/TimelapseFixture", @"minFreeGB": @1},
            @"projects": @[@{@"id": @"plant", @"name": @"本地豆苗", @"capture": @{@"interval": @60}, @"encode": @{@"targetDuration": @30}, @"cleanup": @{@"keepFramesDays": @3650}}, @{@"id": @"empty", @"name": @"空项目"}]
        };
        [[NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingPrettyPrinted error:nil] writeToFile:configPath atomically:YES];
        TLConfig *config = [TLConfig configWithContentsOfFile:configPath error:nil];
        TLState *state = [[TLState alloc] initWithPath:[root stringByAppendingPathComponent:@"state.json"]];
        CGImageRef image = TLSolidImage(320, 240, 40, 150, 90);
        for (NSString *day in @[@"20261114", @"20261115"]) {
            for (NSInteger i = 0; i < 6; i++) {
                for (NSString *kind in @[@"frames", @"thumbs"]) {
                    NSString *relative = [NSString stringWithFormat:@"projects/plant/%@/%@/12000%ld.jpg", kind, day, (long)i];
                    TLWriteJPEGFile([root stringByAppendingPathComponent:relative], image);
                }
            }
        }
        CGImageRelease(image);
        [state updateProject:@"plant" values:@{TLStateLastFile: @"projects/plant/frames/20261115/120005.jpg", TLStateFrameCount: @12} error:nil];
        // 系统编码器生成有效 H.264，再追加合法 free box，使 MP4 大于 20MiB。
        [config setValue:root forKey:@"storageRoot"];
        TLEncoder *encoder = [[TLEncoder alloc] init];
        TLEncodeResult *encoded = [encoder encodeProject:config.projects[0] storageRoot:root date:TLDate(2026, 11, 15, 12, 0, 0, NSTimeZone.localTimeZone) timeZone:NSTimeZone.localTimeZone];
        if (!encoded.succeeded) { fprintf(stderr, "夹具视频编码失败\n"); return 1; }
        NSString *videoPath = [root stringByAppendingPathComponent:encoded.relativePath];
        NSFileHandle *video = [NSFileHandle fileHandleForWritingAtPath:videoPath];
        [video seekToEndOfFile];
        uint32_t box[2] = {htonl(22 * 1024 * 1024 + 8), htonl(0x66726565)};
        [video writeData:[NSData dataWithBytes:box length:sizeof(box)]];
        NSData *padding = [NSMutableData dataWithLength:64 * 1024];
        for (int i = 0; i < 22 * 16; i++) { [video writeData:padding]; }
        [video closeFile];
        TLFixtureServer *server = [[TLFixtureServer alloc] initWithConfigPath:configPath state:state snap:^TLCaptureResult *(TLProject *project) {
            usleep(200000);
            CGImageRef shot = TLSolidImage(320, 240, 180, 90, 40);
            NSString *relative = [NSString stringWithFormat:@"projects/%@/frames/20261115/130000.jpg", project.projectID];
            TLWriteJPEGFile([root stringByAppendingPathComponent:relative], shot);
            TLWriteJPEGFile([root stringByAppendingPathComponent:[relative stringByReplacingOccurrencesOfString:@"/frames/" withString:@"/thumbs/"]], shot);
            CGImageRelease(shot);
            [state updateProject:project.projectID values:@{TLStateLastFile: relative} error:nil];
            TLCaptureResult *result = [[TLCaptureResult alloc] init];
            result.outcome = TLCaptureOutcomeSaved; result.message = @"本地夹具已保存照片";
            result.relativePath = relative; result.width = 320; result.height = 240; result.capturedAt = NSDate.date;
            return result;
        }];
        server.fixtureRoot = root;
        server.indexFileOverride = [NSString stringWithUTF8String:argv[2]];
        // 默认关闭合成/上传能力，浏览器能验证能力禁用；真实系统编码已用于生成视频。
        if (![server startLoopbackForTests:config error:nil]) { return 1; }
        NSDictionary *info = @{@"port": @(server.port), @"root": root, @"video": videoPath, @"token": @"local-fixture-token-only"};
        [[NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[root stringByAppendingPathComponent:@"fixture.json"] atomically:YES];
        printf("FIXTURE_PORT=%u\n", server.port); fflush(stdout);
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
