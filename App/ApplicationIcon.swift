import SwiftUI
import ImageIO


@MainActor final class ApplicationIconCache: ObservableObject {
    static let shared = ApplicationIconCache()
    let cache = NSCache<NSString, UIImage>()
    private var pending: [String: Task<UIImage?, Never>] = [:]
    private let queue = DispatchQueue(label: "WCMigrate.icons", qos: .utility)
    private let disk = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("WCMigrate/StoreIcons-v1")
    private var nextLookup = Date.distantPast
    private(set) var sources: [String: String] = [:]
    /// Large file operations must not compete with App Store artwork lookups or
    /// image decoding. The generation makes visible icon views retry once the
    /// operation has finished, without keeping a request alive in the meantime.
    @Published private(set) var remoteLookupGeneration = 0
    private(set) var remoteLookupsSuppressed = false

    func setRemoteLookupsSuppressed(_ suppressed: Bool) {
        guard remoteLookupsSuppressed != suppressed else { return }
        remoteLookupsSuppressed = suppressed
        if suppressed {
            for task in pending.values { task.cancel() }
            pending.removeAll()
        }
        remoteLookupGeneration &+= 1
    }
    private func note(_ id: String, _ text: String) {
        sources[id] = text
        XCTContainerBridge.recordIconSource(id, message: text)
    }
    private static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 180] as CFDictionary),
              cg.width >= 16, cg.height >= 16 else { return nil }
        return UIImage(cgImage: cg)
    }
    func load(_ bundleID: String) async -> UIImage? {
        let online = UserDefaults.standard.object(forKey: "storeIconsEnabled") as? Bool ?? true
        let key = bundleID + (online ? ":online" : ":local")
        if let image = cache.object(forKey: key as NSString) { return image }
        if remoteLookupsSuppressed && online {
            // A local/system icon is still allowed below; only the remote
            // fallback is blocked while migration work is active.
        }
        if let task = pending[key] { return await task.value }
        let task = Task<UIImage?, Never> {
            let data: Data? = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: XCTContainerBridge.iconPNG(forBundleID: bundleID)) }
            }
            if let data, let image = UIImage(data: data) { note(bundleID, "本地系统接口或安装包"); return image }
            if let fallbackID = ApplicationListingPolicy.fallbackIconBundleID(for: bundleID) {
                let fallback = await load(fallbackID)
                note(bundleID, fallback == nil ? "自身图标不可用；微信图标回退也未取得图像" : "自身图标不可用；按用户规则复用微信图标 · " + fallbackID)
                return fallback
            }
            guard online, !self.remoteLookupsSuppressed else {
                note(bundleID, "本地未取得图标；迁移期间暂停商店图标")
                return nil
            }
            let input = Data(bundleID.utf8)
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            input.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(input.count), &hash) }
            let name = hash.map { String(format: "%02x", $0) }.joined()
            let file = disk.appendingPathComponent(name + ".png")
            let missKey = "storeIconMiss." + name
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(modified) < 7 * 86400,
               let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                note(bundleID, "Apple商店图标 · 本地缓存（非安装包读取）"); return image
            }
            let miss = UserDefaults.standard.double(forKey: missKey)
            if miss > 0, Date().timeIntervalSince1970 - miss < 86400 { note(bundleID, "Apple商店未找到匹配Bundle ID（24小时后重试）"); return nil }
            let delay = max(0, nextLookup.timeIntervalSinceNow)
            nextLookup = Date().addingTimeInterval(delay + 0.25)
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard UserDefaults.standard.object(forKey: "storeIconsEnabled") as? Bool ?? true else { return nil }
            do {
                guard let result = try await StoreIconLookup().lookup(bundleID) else {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: missKey)
                    note(bundleID, "Apple商店未找到匹配Bundle ID；未猜测分身的原始应用"); return nil
                }
                guard let image = Self.thumbnail(result.data) else {
                    note(bundleID, "Apple商店图像无法解码，下次可重试"); return nil
                }
                try? FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
                if let png = image.pngData() { try? png.write(to: file, options: .atomic) }
                UserDefaults.standard.removeObject(forKey: missKey)
                note(bundleID, "Apple商店图标 · " + result.artworkURL.absoluteString + "（非安装包读取）")
                return image
            } catch { note(bundleID, "Apple商店请求失败，可重试 · " + String(describing: error)); return nil }
        }
        pending[key] = task
        let image = await task.value; pending[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }
}
struct ApplicationIcon: View {
    var application: AppInstance?
    var size: CGFloat = 44
    @State private var image: UIImage?
    @AppStorage("storeIconsEnabled") private var online = true
    @ObservedObject private var iconCache = ApplicationIconCache.shared
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "app.dashed").font(.system(size: size * 0.48, weight: .regular)).foregroundStyle(Color.xctAccent).frame(width: size, height: size).background(Color.xctAccent.opacity(0.08)) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityLabel(image == nil ? "应用图标暂不可用" : "应用图标")
            .task(id: (application?.bundleIdentifier ?? "") + String(online) + ":" + String(iconCache.remoteLookupGeneration)) {
                image = nil
                guard let app = application, app.origin.hasPrefix("系统容器") else { return }
                let result = await ApplicationIconCache.shared.load(app.bundleIdentifier)
                if !Task.isCancelled { image = result }
            }
    }
}
