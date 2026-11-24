#import "TLCapture.h"
#import "TLConfig.h"
#import "TLDaemon.h"
#import "TLEncode.h"
#import "TLEncoder.h"
#import "TLJobs.h"
#import "TLLog.h"
#import "TLRules.h"
#import "TLState.h"
#import "TLSupport.h"
#import "TLUploader.h"
#import "TLVersion.h"
#import "TLWeb.h"

#import <errno.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>

static void TLPrintHelp(void) {
    fprintf(stdout,
            "tlapsed %s\n"
            "用法：\n"
            "  tlapsed snap [--project ID] [--config PATH]\n"
            "  tlapsed encode [--project ID] [--date YYYYMMDD] [--config PATH]\n"
            "  tlapsed upload [--project ID] [--config PATH]\n"
            "  tlapsed status [--config PATH]\n"
            "  tlapsed --daemon [--config PATH]\n"
            "\n"
            "默认配置：%s\n"
            "snap      立刻拍一张。项目暂停时也可以手动拍。\n"
            "encode    把已有照片合成 MP4。项目暂停时也可以手动合成。\n"
            "upload    把该项目最新的视频按配置上传。\n"
            "status    查看剩余空间、守护进程和各项目进度。\n"
            "--daemon  常驻定时拍照、合成、上传，并在局域网打开网页控制台。\n"
            "\n"
            "退出码：0 成功，1 参数错误，2 拍照、合成或上传失败，3 配置或存储错误。\n",
            TLAPSED_VERSION_STRING.UTF8String,
            TLDefaultConfigPath.UTF8String);
}

static NSString *TLHHMM(NSInteger minutes) {
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)(minutes / 60), (long)(minutes % 60)];
}

static BOOL TLParseArgs(NSArray<NSString *> *args, NSString **command, NSString **configPath, NSString **projectID, NSString **day, int *exitCode) {
    *configPath = TLDefaultConfigPath;
    *projectID = nil;
    *day = nil;
    *command = nil;
    for (NSUInteger index = 1; index < args.count; index++) {
        NSString *argument = args[index];
        if ([argument isEqualToString:@"--help"] || [argument isEqualToString:@"-h"]) {
            TLPrintHelp();
            *exitCode = 0;
            return NO;
        }
        if ([argument isEqualToString:@"--config"]) {
            if (index + 1 >= args.count) {
                fprintf(stderr, "缺少 --config 参数\n");
                *exitCode = 1;
                return NO;
            }
            *configPath = args[++index];
            continue;
        }
        if ([argument isEqualToString:@"--project"]) {
            if (index + 1 >= args.count) {
                fprintf(stderr, "缺少 --project 参数\n");
                *exitCode = 1;
                return NO;
            }
            *projectID = args[++index];
            continue;
        }
        if ([argument isEqualToString:@"--date"]) {
            if (index + 1 >= args.count) {
                fprintf(stderr, "缺少 --date 参数\n");
                *exitCode = 1;
                return NO;
            }
            *day = args[++index];
            continue;
        }
        if ([argument isEqualToString:@"--daemon"] || [argument isEqualToString:@"daemon"]) {
            if (*command) {
                fprintf(stderr, "重复的命令\n");
                *exitCode = 1;
                return NO;
            }
            *command = @"daemon";
            continue;
        }
        if ([argument hasPrefix:@"-"]) {
            fprintf(stderr, "未知参数：%s\n", argument.UTF8String);
            *exitCode = 1;
            return NO;
        }
        if (*command) {
            fprintf(stderr, "多余参数：%s\n", argument.UTF8String);
            *exitCode = 1;
            return NO;
        }
        *command = argument;
    }
    BOOL projectCommand = [*command isEqualToString:@"snap"] || [*command isEqualToString:@"encode"] || [*command isEqualToString:@"upload"];
    if (*projectID && !projectCommand) {
        fprintf(stderr, "--project 只能和 snap、encode、upload 一起使用\n");
        *exitCode = 1;
        return NO;
    }
    if (*day && ![*command isEqualToString:@"encode"]) {
        fprintf(stderr, "--date 只能和 encode 一起使用\n");
        *exitCode = 1;
        return NO;
    }
    if (*day && ((*day).length != 8 || [*day rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound)) {
        fprintf(stderr, "--date 必须是 YYYYMMDD\n");
        *exitCode = 1;
        return NO;
    }
    return YES;
}

static TLConfig *TLLoadConfig(NSString *path, int *exitCode) {
    NSError *error = nil;
    TLConfig *config = [TLConfig configWithContentsOfFile:path error:&error];
    if (!config) {
        fprintf(stderr, "配置错误：%s\n", (error.localizedDescription ?: @"无法读取").UTF8String);
        *exitCode = 3;
    }
    return config;
}

static int TLCmdStatus(NSString *configPath) {
    int exitCode = 0;
    TLConfig *config = TLLoadConfig(configPath, &exitCode);
    if (!config) {
        return exitCode;
    }
    TLState *state = [[TLState alloc] initWithPath:[config.storageRoot stringByAppendingPathComponent:@"state.json"]];
    NSDictionary *snapshot = [state snapshot];
    NSDictionary *daemon = [snapshot[@"daemon"] isKindOfClass:[NSDictionary class]] ? snapshot[@"daemon"] : @{};
    pid_t pid = [daemon[@"pid"] intValue];
    BOOL alive = pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
    double freeGB = TLFreeGigabytes(config.storageRoot);
    NSString *freeText = freeGB >= 0 ? TLFormatGigabytes(freeGB) : @"未知";

    printf("tlapsed %s\n", TLAPSED_VERSION_STRING.UTF8String);
    printf("配置：%s\n", configPath.UTF8String);
    printf("存储：%s\n", config.storageRoot.UTF8String);
    printf("剩余空间：%s（最低 %.1f GB）\n", freeText.UTF8String, config.minFreeGB);
    if (TLWebTokenAcceptable(config.serverToken)) {
        printf("控制台：端口 %ld，只监听本机、Wi-Fi、热点和 Tailscale，不监听蜂窝网\n", (long)config.serverPort);
    } else {
        printf("控制台：未启动。请把 server.token 改成至少 16 位的随机字符串\n");
    }
    if (alive) {
        printf("守护进程：运行中 pid %d", pid);
        NSString *started = [daemon[@"startedAt"] isKindOfClass:[NSString class]] ? daemon[@"startedAt"] : nil;
        if (started.length > 0) {
            printf("，启动于 %s", started.UTF8String);
        }
        printf("\n");
    } else {
        printf("守护进程：没有运行\n");
    }
    printf("上传：telegram %s，webdav %s\n", config.telegramEnabled ? "启用" : "关闭", config.webdavEnabled ? "启用" : "关闭");

    NSDictionary *projects = [snapshot[@"projects"] isKindOfClass:[NSDictionary class]] ? snapshot[@"projects"] : @{};
    if (config.projects.count == 0) {
        printf("\n没有项目。\n");
        return 0;
    }
    for (TLProject *project in config.projects) {
        NSDictionary *entry = [projects[project.projectID] isKindOfClass:[NSDictionary class]] ? projects[project.projectID] : @{};
        printf("\n项目 %s  %s\n", project.projectID.UTF8String, project.name.UTF8String);
        printf("  启用：%s\n", project.enabled ? "是" : "否");
        printf("  间隔：%.0f 秒\n", project.captureInterval);
        printf("  分辨率：%s\n", project.resolution.UTF8String);
        printf("  方向：%s\n", TLOrientationModeString(project.orientationMode).UTF8String);
        printf("  快门声：%s\n", project.shutterSound ? "开" : "关");
        if (!project.nightSkip.enabled) {
            printf("  夜间跳过：关\n");
        } else {
            printf("  夜间跳过：开");
            if (project.nightSkip.hasTimeWindow) {
                printf(" %s-%s", TLHHMM(project.nightSkip.fromMinutes).UTF8String, TLHHMM(project.nightSkip.toMinutes).UTF8String);
            }
            if (project.nightSkip.brightness > 0) {
                printf(" 亮度低于 %.2f 丢弃", project.nightSkip.brightness);
            }
            printf("\n");
        }
        NSInteger frames = [entry[TLStateFrameCount] integerValue];
        NSString *lastFile = [entry[TLStateLastFile] isKindOfClass:[NSString class]] ? entry[TLStateLastFile] : @"";
        NSString *lastCapture = [entry[TLStateLastCaptureAt] isKindOfClass:[NSString class]] ? entry[TLStateLastCaptureAt] : @"";
        NSString *lastError = [entry[TLStateLastError] isKindOfClass:[NSString class]] ? entry[TLStateLastError] : @"";
        printf("  已拍：%ld\n", (long)frames);
        printf("  最近拍摄：%s\n", lastCapture.length > 0 ? lastCapture.UTF8String : "无");
        printf("  最近文件：%s\n", lastFile.length > 0 ? lastFile.UTF8String : "无");
        if (lastError.length > 0) {
            printf("  最近错误：%s\n", lastError.UTF8String);
        }
        printf("  合成：%s %s %s\n",
               project.encodeEvery.UTF8String,
               TLHHMM(project.encodeAtMinutes).UTF8String,
               project.encodeMode.UTF8String);
        NSString *lastVideo = [entry[TLStateLastEncodeFile] isKindOfClass:[NSString class]] ? entry[TLStateLastEncodeFile] : @"";
        if (lastVideo.length > 0) {
            printf("  最近视频：%s\n", lastVideo.UTF8String);
        }
        printf("  上传：%s\n", project.uploadTargets.count > 0 ? [project.uploadTargets componentsJoinedByString:@", "].UTF8String : "无");
        printf("  保留原图：%ld 天\n", (long)project.keepFramesDays);
    }
    return 0;
}

static int TLLockMediaForCommand(TLConfig *config) {
    int lock = TLTryLockProjectMedia(config.storageRoot, NO);
    if (lock < 0) {
        fprintf(stderr, "%s\n", errno == EWOULDBLOCK ? "正在删除项目内容，请稍后重试" : "无法锁定项目存储");
    }
    return lock;
}

static int TLCmdSnap(NSString *configPath, NSString *projectID) {
    int exitCode = 0;
    TLConfig *config = TLLoadConfig(configPath, &exitCode);
    if (!config) {
        return exitCode;
    }
    TLProject *project = nil;
    if (projectID.length > 0) {
        project = [config projectWithID:projectID];
        if (!project) {
            fprintf(stderr, "没有项目 %s\n", projectID.UTF8String);
            return 3;
        }
    } else if (config.projects.count > 0) {
        project = config.projects[0];
        for (TLProject *candidate in config.projects) {
            if (candidate.enabled) {
                project = candidate;
                break;
            }
        }
    } else {
        fprintf(stderr, "配置里没有项目\n");
        return 3;
    }

    NSError *error = nil;
    if (!TLDropToMobileUser(config.storageRoot, &error)) {
        fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        return 3;
    }
    TLLogSetup([config.storageRoot stringByAppendingPathComponent:@"logs/tlapsed.log"]);
    int mediaLock = TLLockMediaForCommand(config);
    if (mediaLock < 0) { return 2; }
    if (!project.enabled) {
        TLLogInfo(@"项目 %@ 当前暂停，这次按手动拍摄执行", project.projectID);
    }
    TLState *state = [[TLState alloc] initWithPath:[config.storageRoot stringByAppendingPathComponent:@"state.json"]];
    TLCapture *capture = [[TLCapture alloc] init];
    dispatch_queue_t cameraQueue = dispatch_queue_create("com.ddxyl.tlapsed.camera", DISPATCH_QUEUE_SERIAL);
    __block TLCaptureResult *result = nil;
    __block BOOL done = NO;
    NSString *storageRoot = config.storageRoot;
    double minFreeGB = config.minFreeGB;
    dispatch_async(cameraQueue, ^{
        TLCaptureResult *captured = [capture captureProject:project
                                                 storageRoot:storageRoot
                                                   minFreeGB:minFreeGB
                                                      manual:YES
                                             willOpenCamera:^{
            [state updateProject:project.projectID
                          values:@{TLStateLastAttemptAt: TLFormatTimestamp([NSDate date], [NSTimeZone localTimeZone])}
                           error:nil];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            result = captured;
            done = YES;
            CFRunLoopStop(CFRunLoopGetMain());
        });
    });
    while (!done) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
    }
    [state recordCaptureResult:result projectID:project.projectID];
    close(mediaLock);
    if (result.outcome == TLCaptureOutcomeSaved) {
        printf("%s\n", result.message.UTF8String);
        return 0;
    }
    fprintf(stderr, "%s\n", (result.message ?: @"拍照失败").UTF8String);
    return 2;
}

static TLProject *TLResolveProject(TLConfig *config, NSString *projectID, int *exitCode) {
    if (projectID.length > 0) {
        TLProject *project = [config projectWithID:projectID];
        if (!project) {
            fprintf(stderr, "没有项目 %s\n", projectID.UTF8String);
            *exitCode = 3;
        }
        return project;
    }
    if (config.projects.count == 0) {
        fprintf(stderr, "配置里没有项目\n");
        *exitCode = 3;
        return nil;
    }
    TLProject *project = config.projects[0];
    for (TLProject *candidate in config.projects) {
        if (candidate.enabled) {
            return candidate;
        }
    }
    return project;
}

static NSDate *TLDateFromDay(NSString *day) {
    if (day.length != 8) {
        return [NSDate date];
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone localTimeZone];
    formatter.dateFormat = @"yyyyMMdd";
    return [formatter dateFromString:day] ?: [NSDate date];
}

static int TLCmdEncode(NSString *configPath, NSString *projectID, NSString *day) {
    int exitCode = 0;
    TLConfig *config = TLLoadConfig(configPath, &exitCode);
    if (!config) {
        return exitCode;
    }
    TLProject *project = TLResolveProject(config, projectID, &exitCode);
    if (!project) {
        return exitCode;
    }
    NSError *error = nil;
    if (!TLDropToMobileUser(config.storageRoot, &error)) {
        fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        return 3;
    }
    TLLogSetup([config.storageRoot stringByAppendingPathComponent:@"logs/tlapsed.log"]);
    TLState *state = [[TLState alloc] initWithPath:[config.storageRoot stringByAppendingPathComponent:@"state.json"]];
    TLEncoder *encoder = [[TLEncoder alloc] init];
    TLUploader *uploader = [[TLUploader alloc] initWithState:state storageRoot:config.storageRoot];
    int mediaLock = TLLockMediaForCommand(config);
    if (mediaLock < 0) { return 2; }
    TLEncodeResult *result = TLPerformEncodeJob(encoder, uploader, state, config, project, TLDateFromDay(day), [NSTimeZone localTimeZone]);
    close(mediaLock);
    if (result.succeeded) {
        printf("%s\n", result.message.UTF8String);
        return 0;
    }
    fprintf(stderr, "%s\n", (result.message ?: @"合成失败").UTF8String);
    return 2;
}

static NSString *TLNewestVideo(NSString *root, NSString *projectID) {
    NSString *directory = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"projects/%@/videos", projectID]];
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
    NSString *best = nil;
    NSDate *bestDate = nil;
    for (NSString *name in names) {
        if (!TLSafePathComponent(name) || ![name.lowercaseString hasSuffix:@".mp4"]) {
            continue;
        }
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDate *modified = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (!best || [modified compare:bestDate] == NSOrderedDescending) {
            best = path;
            bestDate = modified;
        }
    }
    return best;
}

static int TLCmdUpload(NSString *configPath, NSString *projectID) {
    int exitCode = 0;
    TLConfig *config = TLLoadConfig(configPath, &exitCode);
    if (!config) {
        return exitCode;
    }
    TLProject *project = TLResolveProject(config, projectID, &exitCode);
    if (!project) {
        return exitCode;
    }
    NSError *error = nil;
    if (!TLDropToMobileUser(config.storageRoot, &error)) {
        fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        return 3;
    }
    TLLogSetup([config.storageRoot stringByAppendingPathComponent:@"logs/tlapsed.log"]);
    NSString *path = TLNewestVideo(config.storageRoot, project.projectID);
    if (path.length == 0) {
        fprintf(stderr, "没有可上传的视频\n");
        return 2;
    }
    TLState *state = [[TLState alloc] initWithPath:[config.storageRoot stringByAppendingPathComponent:@"state.json"]];
    TLUploader *uploader = [[TLUploader alloc] initWithState:state storageRoot:config.storageRoot];
    NSString *summary = [uploader uploadFileAtPath:path project:project config:config];
    printf("%s\n", (summary ?: @"已处理").UTF8String);
    if ([summary containsString:@"失败"] && ![summary containsString:@"已上传"] && ![summary containsString:@"已进入重试队列"]) {
        return 2;
    }
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        (void)argc;
        (void)argv;
        NSString *command = nil;
        NSString *configPath = nil;
        NSString *projectID = nil;
        NSString *day = nil;
        int exitCode = 1;
        NSArray<NSString *> *arguments = [NSProcessInfo processInfo].arguments;
        if (!TLParseArgs(arguments, &command, &configPath, &projectID, &day, &exitCode)) {
            return exitCode;
        }
        if (command == nil) {
            TLPrintHelp();
            return 0;
        }
        if ([command isEqualToString:@"snap"]) {
            return TLCmdSnap(configPath, projectID);
        }
        if ([command isEqualToString:@"encode"]) {
            return TLCmdEncode(configPath, projectID, day);
        }
        if ([command isEqualToString:@"upload"]) {
            return TLCmdUpload(configPath, projectID);
        }
        if ([command isEqualToString:@"status"]) {
            return TLCmdStatus(configPath);
        }
        if ([command isEqualToString:@"daemon"]) {
            TLDaemon *daemon = [[TLDaemon alloc] init];
            return [daemon runWithConfigPath:configPath];
        }
        fprintf(stderr, "未知命令：%s\n", command.UTF8String);
        TLPrintHelp();
        return 1;
    }
}
