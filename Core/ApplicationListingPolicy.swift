import Foundation

/// A data-container label alone is not evidence of an installed application.
public enum ApplicationListingPolicy {
    public static func rejection(bundlePath: String?, excludedReason: String? = nil) -> String? {
        if let excludedReason, !excludedReason.isEmpty { return excludedReason }
        guard let bundlePath, bundlePath.hasPrefix("/"), !bundlePath.split(separator: "/").contains("..") else {
            return "未取得可核验的 .app 安装路径"
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
    /// Explicit user-approved alias only. It never changes the application's identity.
    public static func fallbackIconBundleID(for bundleID: String) -> String? {
        bundleID == "com.tencent.qy.xin" ? "com.tencent.xin" : nil
    }
}
