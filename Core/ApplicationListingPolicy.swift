import Foundation

/// Installation metadata is preferred; verified application-class containers are
/// also usable when the OS denies access to installation metadata.
public enum ApplicationListingPolicy {
    public static func rejection(bundlePath: String?, excludedReason: String? = nil, bundleIdentifier: String? = nil, verifiedContainerIdentifier: String? = nil, dataContainerPath: String? = nil) -> String? {
        if let excludedReason, !excludedReason.isEmpty { return excludedReason }
        if let bundlePath, (!bundlePath.hasPrefix("/") || bundlePath.split(separator: "/").contains("..")) {
            return "应用安装路径无效"
        }
        guard let bundlePath else {
            // Do not guess identities from unknown LaunchServices record offsets.
            // This evidence is supplied only after wq_container_label + grant.
            guard let id = bundleIdentifier, id == verifiedContainerIdentifier,
                  id.split(separator: ".").count >= 2,
                  !id.contains(where: { $0.isWhitespace || $0 == "/" }),
                  let root = dataContainerPath, isApplicationDataRoot(root) else {
                return "未取得应用安装路径或已核验的应用数据容器"
            }
            // Apple's Application class includes many system UI services. Without
            // installation metadata, retain only known user-facing system apps.
            if id.hasPrefix("com.apple.") && !visibleSystemApps.contains(id) {
                return "系统组件缺少可显示应用的安装信息"
            }
            return nil
        }
        let path = (bundlePath as NSString).standardizingPath
        let parts = path.split(separator: "/").map(String.init)
        guard parts.last?.hasSuffix(".app") == true else { return "不是应用安装包" }
        // Installed apps must be immediate children of a UUID bundle container.
        for root in ["/private/var/containers/Bundle/Application/", "/var/containers/Bundle/Application/"] where path.hasPrefix(root) {
            let tail = String(path.dropFirst(root.count)).split(separator: "/")
            return tail.count == 2 && UUID(uuidString: String(tail[0])) != nil ? nil : "不是顶层应用安装包"
        }
        if parts.count == 2 && parts.first == "Applications" { return nil }
        if parts.count == 3 && Array(parts.prefix(2)) == ["System", "Applications"] { return nil }
        return "扩展、后台服务或非应用安装目录"
    }
    private static func isApplicationDataRoot(_ path: String) -> Bool {
        guard !path.split(separator: "/").contains("..") else { return false }
        for prefix in ["/private/var/mobile/Containers/Data/Application/", "/var/mobile/Containers/Data/Application/"] where path.hasPrefix(prefix) {
            let tail = path.dropFirst(prefix.count).split(separator: "/")
            return tail.count == 1 && UUID(uuidString: String(tail[0])) != nil
        }
        return false
    }
    private static let visibleSystemApps: Set<String> = [
        "com.apple.mobilesafari", "com.apple.Preferences", "com.apple.camera",
        "com.apple.mobileslideshow", "com.apple.mobilemail", "com.apple.MobileSMS",
        "com.apple.mobilephone", "com.apple.MobileAddressBook", "com.apple.mobilecal",
        "com.apple.mobilenotes", "com.apple.reminders", "com.apple.Maps",
        "com.apple.Music", "com.apple.podcasts", "com.apple.iBooks",
        "com.apple.AppStore", "com.apple.DocumentsApp", "com.apple.Health",
        "com.apple.Passbook", "com.apple.weather", "com.apple.stocks",
        "com.apple.mobiletimer", "com.apple.calculator", "com.apple.VoiceMemos",
        "com.apple.compass", "com.apple.measure", "com.apple.findmy",
        "com.apple.shortcuts", "com.apple.Translate", "com.apple.facetime", "com.apple.tv"
    ]
    /// Explicit user-approved alias only. It never changes the application's identity.
    public static func fallbackIconBundleID(for bundleID: String) -> String? {
        bundleID == "com.tencent.qy.xin" ? "com.tencent.xin" : nil
    }
}
