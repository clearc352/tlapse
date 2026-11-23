#import "TLJobs.h"

#import "TLConfig.h"
#import "TLEncode.h"
#import "TLEncoder.h"
#import "TLLog.h"
#import "TLRules.h"
#import "TLState.h"
#import "TLUploader.h"

TLEncodeResult *TLPerformEncodeJob(TLEncoder *encoder,
                                  TLUploader *uploader,
                                  TLState *state,
                                  TLConfig *config,
                                  TLProject *project,
                                  NSDate *date,
                                  NSTimeZone *timeZone) {
    NSDate *when = date ?: [NSDate date];
    NSTimeZone *zone = timeZone ?: [NSTimeZone localTimeZone];
    TLEncodeResult *result = [encoder encodeProject:project storageRoot:config.storageRoot date:when timeZone:zone];
    if (!result) {
        result = [[TLEncodeResult alloc] init];
        result.message = @"合成没有返回结果";
    }
    if (result.empty) {
        TLLogInfo(@"%@：%@", project.projectID, result.message);
        return result;
    }
    if (!result.succeeded) {
        TLLogError(@"%@：%@", project.projectID, result.message ?: @"合成失败");
        if (state) {
            [state updateProject:project.projectID values:@{TLStateLastEncodeError: result.message ?: @"合成失败"} error:nil];
        }
        return result;
    }
    NSInteger removed = TLCleanupExpiredFrames(config.storageRoot, project.projectID, project.keepFramesDays, when, zone);
    result.removedFrames = removed;
    if (removed > 0) {
        TLLogInfo(@"%@：已清理 %ld 张超过 %ld 天的原图", project.projectID, (long)removed, (long)project.keepFramesDays);
        result.message = [NSString stringWithFormat:@"%@，清理过期原图 %ld 张", result.message, (long)removed];
    }
    if (state) {
        [state updateProject:project.projectID values:@{
            TLStateLastEncodeAt: TLFormatTimestamp(when, zone),
            TLStateLastEncodeFile: result.relativePath ?: @"",
            TLStateLastEncodeError: @"",
        } error:nil];
    }
    TLLogInfo(@"%@：%@", project.projectID, result.message);
    if (uploader && project.uploadTargets.count > 0 && result.absolutePath.length > 0) {
        NSString *summary = [uploader uploadFileAtPath:result.absolutePath project:project config:config];
        if (summary.length > 0) {
            result.message = [NSString stringWithFormat:@"%@。%@", result.message, summary];
            TLLogInfo(@"%@：%@", project.projectID, summary);
        }
    }
    return result;
}
