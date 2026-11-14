// XChat Transfer adapter, GPL-3.0-or-later. WQ Files attribution: Vendor/WQFiles/LICENSE.
#import "XCTContainerBridge.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import "XCTAppMetadata.h"
#import "WQArchive.h"
#import <dirent.h>
#import <fcntl.h>
#import <unistd.h>
static BOOL XCTAllowFullScan;
static BOOL XCTConfirmScan(NSString *what, int64_t ids, double seconds) { return XCTAllowFullScan; }
@implementation XCTContainerBridge
// Candidate names from historical iOS layouts, not an assertion these exist on this OS.
// Only list named cache roots and inspect regular-file headers. No recursive scan or writes.
+ (NSString *)probeIconCaches {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:@"图标缓存只读探测：历史候选路径，需以本机结果为准；未实现私有缓存解析或Bundle ID映射。"];
    NSArray *roots = @[@"/var/mobile/Library/Caches/com.apple.IconsCache",
                       @"/var/mobile/Library/Caches/com.apple.iconservices",
                       @"/var/mobile/Library/Caches/com.apple.springboard.sharedimagecache"];
    for (NSString *root in roots) {
        BOOL grant = wq_grant(root);
        DIR *dir = opendir(root.fileSystemRepresentation);
        int code = dir ? 0 : errno;
        [lines addObject:[NSString stringWithFormat:@"候选 %@ | grant=%@ | opendir errno=%d (%s)", root, grant ? @"YES" : @"NO", code, strerror(code)]];
        if (!dir) continue;
        struct dirent *entry; NSUInteger count = 0;
        while (count < 32 && (entry = readdir(dir))) {
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            count++;
            NSString *name = [NSString stringWithUTF8String:entry->d_name] ?: @"<非UTF8名称>";
            int fd = openat(dirfd(dir), entry->d_name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
            int fileError = fd < 0 ? errno : 0;
            struct stat st; unsigned char header[8]; ssize_t n = 0;
            if (fd >= 0) {
                if (!fstat(fd, &st) && S_ISREG(st.st_mode)) n = read(fd, header, sizeof(header));
                close(fd);
            }
            NSMutableString *magic = [NSMutableString new];
            for (ssize_t i = 0; i < n; i++) [magic appendFormat:@"%02x", header[i]];
            [lines addObject:[NSString stringWithFormat:@"  %@ | open errno=%d | 文件头=%@", name, fileError, magic.length ? magic : @"未读取普通文件头"]];
        }
        closedir(dir);
        [lines addObject:@"仅列出前32项；目录可读不等于已取得图标，尚无可靠Bundle ID映射。"];
    }
    NSString *report = [lines componentsJoinedByString:@"\n"];
    wq_log(@"%@", report); return report;
}
+ (NSData *)iconPNGForBundleID:(NSString *)bundleID { return XCTReadApplicationIcon(bundleID); }
+ (void)recordIconSource:(NSString *)bundleID message:(NSString *)message { XCTRecordIconSource(bundleID, message); }
+ (void)recordDiscoveryExclusion:(NSString *)bundleID reason:(NSString *)reason { wq_log(@"应用筛选 %@ · 已排除: %@", bundleID, reason); }
+ (NSString *)diagnostics { return wq_log_text() ?: @""; }
+ (NSDictionary *)iconDiagnostics:(NSString *)bundleID { return XCTIconDiagnostics(bundleID); }
+ (BOOL)createConfigurationZIP:(NSString *)directory output:(NSString *)output error:(NSError **)error {
    NSArray *names = @[@"manifest.json", @"checksums.sha256", @"payload"];
    NSMutableArray *paths = [NSMutableArray new];
    for (NSString *name in names) [paths addObject:[directory stringByAppendingPathComponent:name]];
    NSString *reason = nil; NSUInteger skipped = 0;
    BOOL ok = wq_zip_write(paths, output, wq_archive_posix_io(), nil, nil, &skipped, &reason);
    if (skipped) { ok = NO; reason = @"配置包含链接或特殊文件，未分享不完整的 ZIP。"; [NSFileManager.defaultManager removeItemAtPath:output error:nil]; }
    if (!ok && error) *error = [NSError errorWithDomain:@"WCMigrate.ZIP" code:1 userInfo:@{NSLocalizedDescriptionKey:reason ?: @"ZIP 压缩失败"}];
    return ok;
}
+ (BOOL)extractConfigurationZIP:(NSString *)zip output:(NSString *)output error:(NSError **)error {
    NSString *reason = nil; NSUInteger files = 0, skipped = 0;
    BOOL ok = wq_zip_extract(zip, output, wq_archive_posix_io(), 512ULL * 1024 * 1024, nil, nil, &files, &skipped, &reason);
    if (skipped) { ok = NO; reason = @"ZIP 含链接或特殊文件，配置导入已停止。"; }
    if (!ok && error) *error = [NSError errorWithDomain:@"WCMigrate.ZIP" code:2 userInfo:@{NSLocalizedDescriptionKey:reason ?: @"ZIP 解压失败"}];
    return ok;
}
+ (NSString *)directoryReadError:(NSString *)path {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return [NSString stringWithFormat:@"%@ | open errno=%d (%s)", path, errno, strerror(errno)];
    DIR *dir = fdopendir(fd);
    if (!dir) { int code = errno; close(fd); return [NSString stringWithFormat:@"%@ | fdopendir errno=%d (%s)", path, code, strerror(code)]; }
    errno = 0; readdir(dir); int code = errno; closedir(dir);
    if (code) return [NSString stringWithFormat:@"%@ | readdir errno=%d (%s)", path, code, strerror(code)];
    return nil;
}
+ (NSString *)appGroup { return wq_app_group(); }
+ (BOOL)prepareRead:(NSString *)path {
    // Match WQ's file-read fallback: an extension for the file alone may not
    // permit metadata/traversal on its containing directory.
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int openCode = fd < 0 ? errno : 0; if (fd >= 0) close(fd);
    struct stat st; int metadataCode = lstat(path.fileSystemRepresentation, &st) == 0 ? 0 : errno;
    if (!openCode && !metadataCode) return YES;
    if (openCode != EPERM && openCode != EACCES && metadataCode != EPERM && metadataCode != EACCES) return NO;
    NSString *parent = path.stringByDeletingLastPathComponent;
    BOOL parentGrant = wq_grant(parent);
    fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    openCode = fd < 0 ? errno : 0; if (fd >= 0) close(fd);
    metadataCode = lstat(path.fileSystemRepresentation, &st) == 0 ? 0 : errno;
    BOOL fileGrant = NO;
    if (openCode || metadataCode) {
        fileGrant = wq_grant(path);
        fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        openCode = fd < 0 ? errno : 0; if (fd >= 0) close(fd);
        metadataCode = lstat(path.fileSystemRepresentation, &st) == 0 ? 0 : errno;
    }
    wq_log(@"数据访问 %@ | parent=%@ grant=%@ | item grant=%@ | open errno=%d (%s) | lstat errno=%d (%s)", path, parent, parentGrant ? @"YES" : @"NO", fileGrant ? @"YES" : @"未尝试或NO", openCode, strerror(openCode), metadataCode, strerror(metadataCode));
    return !openCode && !metadataCode;
}
+ (NSArray<NSDictionary<NSString *,NSString *> *> *)discover:(BOOL)allowFullScan error:(NSError **)error {
#if TARGET_OS_SIMULATOR
    if (error) *error = [NSError errorWithDomain:@"XChatTransfer" code:1 userInfo:@{NSLocalizedDescriptionKey:@"模拟器不支持跨应用容器发现，请导入测试目录。"}];
    return nil;
#else
    if (@available(iOS 26.0, *)) {
        if (!wq_app_group()) {
            if (error) *error = [NSError errorWithDomain:@"XChatTransfer" code:2 userInfo:@{NSLocalizedDescriptionKey:@"签名未提供 App Group，无法启用容器访问。可使用文件 App 导入目录。"}]; return nil;
        }
        XCTAllowFullScan = allowFullScan;
        wq_set_full_scan_ui(XCTConfirmScan, NULL);
        wq_set_container_list_provider(wq_ls_container_paths);
        wq_set_container_label_resolver(wq_bundle_id_for_container);
        wq_display_names_reset_miss(); wq_enumerate_invalidate(); wq_load_display_names();
        NSArray *paths = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, nil, nil);
        if (!paths.count) {
            if (error) *error = [NSError errorWithDomain:@"XChatTransfer" code:3 userInfo:@{NSLocalizedDescriptionKey:@"没有取得可靠的应用容器列表。请检查 App Group、系统支持或手动同意完整扫描；空列表不代表未安装微信。"}]; return nil;
        }
        NSMutableArray *result = [NSMutableArray new];
        for (NSString *path in paths) {
            NSString *identifier = wq_container_label(path);
            if (!identifier.length || !wq_grant(path)) continue;
            NSString *name = wq_display_name(identifier) ?: identifier;
            NSMutableDictionary *item = [@{@"id":identifier,@"name":name,@"path":path,@"verifiedContainerIdentifier":identifier} mutableCopy];
            [item addEntriesFromDictionary:XCTApplicationListingFacts(identifier)];
            NSString *bundle = item[@"bundlePath"];
            if (bundle) {
                item[@"bundlePath"] = bundle;
                NSDictionary *info = XCTReadBundleInfo(bundle);
                if ([info isKindOfClass:NSDictionary.class] && [info[@"CFBundleIdentifier"] isEqual:identifier]) {
                    if ([info[@"CFBundleExecutable"] isKindOfClass:NSString.class]) item[@"executable"] = info[@"CFBundleExecutable"];
                    NSString *display = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
                    if ([display isKindOfClass:NSString.class] && display.length) item[@"name"] = display;
                    if ([info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class]) item[@"version"] = info[@"CFBundleShortVersionString"];
                    if ([info[@"CFBundleVersion"] isKindOfClass:NSString.class]) item[@"build"] = info[@"CFBundleVersion"];
                }
            }
            [result addObject:item];
        }
        NSUInteger missingBundle = 0;
        for (NSDictionary *item in result) if (![item[@"bundlePath"] length]) missingBundle++;
        wq_log(@"应用发现汇总: 候选路径=%lu，身份与授权已确认=%lu，未取得安装路径=%lu（交由应用数据容器分类处理）", (unsigned long)paths.count, (unsigned long)result.count, (unsigned long)missingBundle);
        if (!result.count && error) *error = [NSError errorWithDomain:@"XChatTransfer" code:4 userInfo:@{NSLocalizedDescriptionKey:@"容器存在，但身份或读取能力未确认，不能展示为可用应用。"}];
        return result;
    }
    if (error) *error = [NSError errorWithDomain:@"XChatTransfer" code:5 userInfo:@{NSLocalizedDescriptionKey:@"容器访问适配器要求 iOS 26 或更新版本。"}]; return nil;
#endif
}
@end
