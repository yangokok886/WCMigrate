// WCMigrate. Icon PNG lookup follows WQ Files WQUI.m, GPL-3.0-or-later.
// WQ Files: kolbicz; worse_query: Taj C (forcequit). See THIRD_PARTY_NOTICES.
#import "XCTAppMetadata.h"
#import "WQAccess.h"
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>

@interface UIImage (XCTSystemIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt scale:(CGFloat)scale;
@end
static NSMutableDictionary<NSString *, NSMutableDictionary *> *XCTIconNotes;
static void XCTNote(NSString *bid, NSString *step, NSString *value) {
    @synchronized (UIImage.class) {
        if (!XCTIconNotes) XCTIconNotes = [NSMutableDictionary new];
        if (!XCTIconNotes[bid]) XCTIconNotes[bid] = [NSMutableDictionary new];
        XCTIconNotes[bid][step] = value ?: @"未知";
    }
    wq_log(@"icon %@ · %@: %@", bid, step, value);
}
void XCTRecordIconSource(NSString *bundleID, NSString *message) { XCTNote(bundleID, @"显示来源", message); }
NSDictionary *XCTIconDiagnostics(NSString *bid) {
    @synchronized (UIImage.class) { return [XCTIconNotes[bid] copy] ?: @{@"状态":@"尚未请求图标"}; }
}
// Opening all ancestors individually can be denied even when a token covers the .app.
// Open only the final regular file; the installation path is obtained from LS, never user input.
static NSData *XCTBoundedRead(NSString *path, NSUInteger limit, NSString **reason) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) {
        wq_grant(path.stringByDeletingLastPathComponent); wq_grant(path);
        fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    }
    if (fd >= 0) {
        struct stat st;
        if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0 && st.st_size <= limit) {
            NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
            NSUInteger count = 0;
            while (count < data.length) { ssize_t n = read(fd, (char *)data.mutableBytes + count, data.length - count); if (n < 0 && errno == EINTR) continue; if (n <= 0) break; count += n; }
            close(fd); if (count == data.length) return data;
            if (reason) *reason = @"读取未完成"; return nil;
        }
        close(fd); if (reason) *reason = @"不是普通文件、为空或超过读取上限"; return nil;
    }
    if (reason) *reason = [NSString stringWithFormat:@"errno=%d %s", errno, strerror(errno)];
    return nil;
}
static NSString *XCTLSBundlePath(NSString *bid) {
    Class cls = NSClassFromString(@"LSApplicationProxy"); SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    @try {
        if ([cls respondsToSelector:selector]) {
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)(cls, selector, bid);
            SEL urlSelector = NSSelectorFromString(@"bundleURL");
            if ([proxy respondsToSelector:urlSelector]) {
                id value = ((id (*)(id, SEL))objc_msgSend)(proxy, urlSelector);
                if ([value isKindOfClass:NSURL.class] && [value isFileURL] && [[[value path] pathExtension] isEqual:@"app"]) {
                    XCTNote(bid, @"路径来源", @"LSApplicationProxy.bundleURL"); return [value path];
                }
            }
        }
    } @catch (NSException *exception) { XCTNote(bid, @"LS接口", exception.reason); }
    XCTNote(bid, @"LS备用路径", @"LSApplicationProxy 未返回可用 .app 路径（不影响已有 WQ 路径）"); return nil;
}
static BOOL XCTProbeBundleAccess(NSString *bid, NSString *bundle) {
    NSString *container = bundle.stringByDeletingLastPathComponent;
    NSString *plist = [bundle stringByAppendingPathComponent:@"Info.plist"];
    NSArray *paths = @[[container stringByStandardizingPath], bundle, plist];
    NSMutableArray *outcomes = [NSMutableArray new];
    for (NSString *path in paths) {
        int fd = open(plist.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (fd >= 0) { close(fd); XCTNote(bid, @"安装权限", @"Info.plist 可打开"); return YES; }
        BOOL granted = wq_grant(path);
        fd = open(plist.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        int code = fd < 0 ? errno : 0;
        if (fd >= 0) close(fd);
        [outcomes addObject:[NSString stringWithFormat:@"%@ | grant=%@ | open Info.plist errno=%d (%s)", path, granted ? @"YES" : @"NO", code, strerror(code)]];
        if (!code) { XCTNote(bid, @"安装权限", [outcomes componentsJoinedByString:@"\n"]); return YES; }
    }
    XCTNote(bid, @"安装权限", [outcomes componentsJoinedByString:@"\n"]);
    XCTNote(bid, @"限制说明", @"已取得安装路径，但未读到Info.plist；请以各次open errno为准：EPERM/EACCES表示访问受限，ENOENT可能路径过期或文件不存在。可读数据容器不等于可读安装包，系统图标接口是独立路线；不是Assets.car解码结果。");
    return NO;
}
static NSString *XCTBundlePath(NSString *bid) {
    NSString *path = wq_bundle_path_for_id(bid);
    if (path.length) { XCTNote(bid, @"路径来源", @"WQ LaunchServices 数据库"); return path; }
    return XCTLSBundlePath(bid);
}
NSDictionary *XCTReadBundleInfo(NSString *path) {
    NSString *reason = nil;
    NSData *data = XCTBoundedRead([path stringByAppendingPathComponent:@"Info.plist"], 2 * 1024 * 1024, &reason);
    id value = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
// Only inspect identity/visibility metadata; no foreign bundle resource rendering.
NSDictionary<NSString *, NSString *> *XCTApplicationListingFacts(NSString *bid) {
    NSString *path = XCTBundlePath(bid);
    NSMutableDictionary *facts = [NSMutableDictionary new];
    if (path.length) facts[@"bundlePath"] = path;
    NSDictionary *info = path.length ? XCTReadBundleInfo(path) : nil;
    if (info) {
        if (![info[@"CFBundleIdentifier"] isEqual:bid]) facts[@"excludedReason"] = @"安装包身份与容器标识不一致";
        else if (info[@"NSExtension"] || (info[@"CFBundlePackageType"] && ![info[@"CFBundlePackageType"] isEqual:@"APPL"])) facts[@"excludedReason"] = @"扩展或非应用包类型";
        else if ([info[@"LSUIElement"] boolValue] || [info[@"LSBackgroundOnly"] boolValue] ||
                 ([info[@"SBAppTags"] isKindOfClass:NSArray.class] && [info[@"SBAppTags"] containsObject:@"hidden"])) facts[@"excludedReason"] = @"隐藏组件或后台服务";
    }
    @try {
        Class cls = NSClassFromString(@"LSApplicationProxy"); SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        id proxy = [cls respondsToSelector:sel] ? ((id (*)(id, SEL, id))objc_msgSend)(cls, sel, bid) : nil;
        SEL tagsSelector = NSSelectorFromString(@"appTags");
        id tags = [proxy respondsToSelector:tagsSelector] ? ((id (*)(id, SEL))objc_msgSend)(proxy, tagsSelector) : nil;
        if (([tags isKindOfClass:NSArray.class] || [tags isKindOfClass:NSSet.class]) && [tags containsObject:@"hidden"]) facts[@"excludedReason"] = @"LaunchServices 标记为隐藏组件";
        SEL typeSelector = NSSelectorFromString(@"applicationType");
        id type = [proxy respondsToSelector:typeSelector] ? ((id (*)(id, SEL))objc_msgSend)(proxy, typeSelector) : nil;
        if ([type isKindOfClass:NSString.class] && [@[@"PluginKitPlugin", @"Internal", @"Daemon", @"XPCService"] containsObject:type]) facts[@"excludedReason"] = @"LaunchServices 标记为扩展或系统服务";
    } @catch (NSException *exception) { wq_log(@"应用分类 %@ · LS 元数据不可用: %@", bid, exception.reason); }
    return facts;
}
static NSData *XCTFingerprint(UIImage *image) {
    if (!image.CGImage) return nil;
    uint8_t bytes[12 * 12 * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bytes, 12, 12, 8, 48, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextDrawImage(context, CGRectMake(0, 0, 12, 12), image.CGImage); CGContextRelease(context);
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}
static NSData *XCTSystemIcon(NSString *bundleID) {
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    // WQManager uses multiple system formats. Compare against unknown-app images
    // for each format rather than treating every returned UIImage as a real icon.
    NSArray *formats = @[@10, @8, @2, @0, @1];
    NSMutableArray<NSData *> *placeholders = [NSMutableArray new];
    @try {
    for (NSNumber *format in formats) {
        UIImage *empty = [UIImage _applicationIconImageForBundleIdentifier:@"local.wcmigrate.no-such-application" format:format.intValue scale:2];
        NSData *fp = XCTFingerprint(empty); if (fp) [placeholders addObject:fp];
    }
        for (NSNumber *format in formats) {
            UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:format.intValue scale:2];
            NSData *a = XCTFingerprint(icon); if (!a) continue;
            BOOL placeholder = NO;
            for (NSData *b in placeholders) {
                if (a.length != b.length) continue;
                const uint8_t *x = a.bytes, *y = b.bytes; NSUInteger difference = 0;
                for (NSUInteger i = 0; i < a.length; i++) difference += abs((int)x[i] - (int)y[i]);
                if (difference / a.length < 8) { placeholder = YES; break; }
            }
            if (placeholder) continue;
            XCTNote(bundleID, @"系统图标接口", [NSString stringWithFormat:@"format=%@返回图像，通过多格式占位指纹筛选（仍是启发式）", format]);
            return UIImagePNGRepresentation(icon);
        }
    } @catch (NSException *exception) { XCTNote(bundleID, @"系统图标接口", exception.reason); return nil; }
    XCTNote(bundleID, @"系统图标接口", @"五种格式均为空或与未知应用占位图接近");
    return nil;
}
static NSData *XCTThumbnail(NSData *data) {
    if (!data.length) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (id)kCGImageSourceThumbnailMaxPixelSize:@180, (id)kCGImageSourceCreateThumbnailWithTransform:@YES};
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source); if (!image) return nil;
    NSData *result = UIImagePNGRepresentation([UIImage imageWithCGImage:image]); CGImageRelease(image); return result;
}
NSData *XCTReadApplicationIcon(NSString *bundleID) {
    // Installation directory first. Never execute or load code from the foreign bundle.
    NSString *path = XCTBundlePath(bundleID);
    XCTNote(bundleID, @"安装目录", path ?: @"未找到");
    if (path) XCTProbeBundleAccess(bundleID, path);
    NSString *plistError = nil;
    NSData *plistData = path ? XCTBoundedRead([path stringByAppendingPathComponent:@"Info.plist"], 2 * 1024 * 1024, &plistError) : nil;
    id decoded = plistData ? [NSPropertyListSerialization propertyListWithData:plistData options:0 format:nil error:nil] : nil;
    NSDictionary *info = [decoded isKindOfClass:NSDictionary.class] ? decoded : nil;
    XCTNote(bundleID, @"Info.plist", info ? @"读取成功" : (plistError ?: @"未取得或格式无效"));
    if (![info[@"CFBundleIdentifier"] isEqual:bundleID]) {
        NSString *alternate = XCTLSBundlePath(bundleID);
        if (alternate.length && ![alternate isEqual:path]) {
            XCTProbeBundleAccess(bundleID, alternate);
            NSDictionary *other = XCTReadBundleInfo(alternate);
            if ([other[@"CFBundleIdentifier"] isEqual:bundleID]) { path = alternate; info = other; XCTNote(bundleID, @"备用安装目录", alternate); }
        }
        if (![info[@"CFBundleIdentifier"] isEqual:bundleID]) XCTNote(bundleID, @"身份核验", info ? @"Info.plist的BundleID不匹配，未使用其图标" : @"Info.plist读取失败");
    }
    if ([info[@"CFBundleIdentifier"] isEqual:bundleID]) {
        NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet new];
        for (NSString *key in @[@"CFBundleIcons", @"CFBundleIcons~ipad"]) {
            id icons = info[key]; id primary = [icons isKindOfClass:NSDictionary.class] ? icons[@"CFBundlePrimaryIcon"] : nil;
            if (![primary isKindOfClass:NSDictionary.class]) continue;
            if ([primary[@"CFBundleIconName"] isKindOfClass:NSString.class]) [names addObject:primary[@"CFBundleIconName"]];
            id files = primary[@"CFBundleIconFiles"];
            if ([files isKindOfClass:NSArray.class]) for (id name in [files reverseObjectEnumerator]) if ([name isKindOfClass:NSString.class]) [names addObject:name];
        }
        id legacy = info[@"CFBundleIconFiles"];
        if ([legacy isKindOfClass:NSArray.class]) for (id name in [legacy reverseObjectEnumerator]) if ([name isKindOfClass:NSString.class]) [names addObject:name];
        if ([info[@"CFBundleIconFile"] isKindOfClass:NSString.class]) [names addObject:info[@"CFBundleIconFile"]];
        [names addObjectsFromArray:@[@"AppIcon60x60", @"AppIcon76x76", @"AppIcon"]];
        for (NSString *name in names) {
            // Info.plist values are data, not trusted paths.
            if (!name.length || [name containsString:@"/"] || [name containsString:@".."] || name.length > 200) continue;
            NSString *base = name.stringByDeletingPathExtension;
            for (NSString *suffix in @[@"@3x.png", @"@2x.png", @"@2x~ipad.png", @"~ipad.png", @".png"]) {
                NSString *file = [path stringByAppendingPathComponent:[base stringByAppendingString:suffix]];
                NSData *image = XCTThumbnail(XCTBoundedRead(file, 8 * 1024 * 1024, nil));
                if (image) { XCTNote(bundleID, @"图标结果", file); return image; }
            }
        }
    }
    if (path && [info[@"CFBundleIdentifier"] isEqual:bundleID]) {
        // Legacy/custom icon names not declared in CFBundleIcons.
        NSArray *files = wq_list(path, nil);
        NSUInteger tried = 0;
        for (NSString *file in files) {
            NSString *lower = file.lowercaseString;
            if (![lower hasSuffix:@".png"] || !([lower hasPrefix:@"appicon"] || [lower hasPrefix:@"icon"] || [lower hasPrefix:@"iphoneicon"]) || [file containsString:@"/"]) continue;
            if (++tried > 64) break;
            NSData *data = XCTThumbnail(XCTBoundedRead([path stringByAppendingPathComponent:file], 8 * 1024 * 1024, nil));
            if (data) { XCTNote(bundleID, @"图标结果", file); return data; }
        }
        XCTNote(bundleID, @"PNG搜索", [NSString stringWithFormat:@"未读到图标；目录枚举%@，候选%lu", files ? @"成功" : @"失败", (unsigned long)tried]);
    }
    // Assets.car is intentionally not rendered: upstream reports UIKit aborts on some systems.
    NSData *system = XCTSystemIcon(bundleID);
    XCTNote(bundleID, @"图标结果", system ? @"系统接口返回图像（不代表安装包或图标缓存可读）" : @"未取得真实图标；请查看安装权限与 Info.plist 结果。系统接口为空或占位，Assets.car未读取");
    return system;
}
