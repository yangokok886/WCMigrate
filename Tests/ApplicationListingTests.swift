import XCTest
@testable import TransferCore
final class ApplicationListingTests: XCTestCase {
    let installed = "/private/var/containers/Bundle/Application/8C5096C3-B60C-4DC7-8967-8E14C40C6AD6/WeChat.app"
    func testInstalledClonesAndSystemAppsRemain() {
        XCTAssertNil(ApplicationListingPolicy.rejection(bundlePath: installed))
        XCTAssertNil(ApplicationListingPolicy.rejection(bundlePath: installed.replacingOccurrences(of: "/private/var/", with: "/var/")))
        XCTAssertNil(ApplicationListingPolicy.rejection(bundlePath: "/Applications/MobileSafari.app"))
        XCTAssertNil(ApplicationListingPolicy.rejection(bundlePath: "/System/Applications/Camera.app"))
    }
    func testServicesExtensionsAndUnidentifiedContainersAreExcluded() {
        for path: String? in [nil, "/System/Library/PrivateFrameworks/Foo.framework/Service.app", installed + "/PlugIns/Share.appex", installed + "/Nested.app", "/Applications/../Applications/App.app", "/var/containers/Bundle/Application/invalid/App.app"] {
            XCTAssertNotNil(ApplicationListingPolicy.rejection(bundlePath: path))
        }
        XCTAssertEqual(ApplicationListingPolicy.rejection(bundlePath: installed, excludedReason: "隐藏组件"), "隐藏组件")
    }
    private let dataRoot = "/private/var/mobile/Containers/Data/Application/28B3EF9C-568D-4F67-82A6-8230B2CFADB8"
    func testVerifiedApplicationDataContainerSurvivesMissingInstallationMetadata() {
        for id in ["com.tencent.xin", "com.tencent.qy.xin", "com.netease.cloudmusic", "ph.telegra.Telegraph", "org.clone.wechat", "com.apple.iBooks"] {
            XCTAssertNil(ApplicationListingPolicy.rejection(bundlePath: nil, bundleIdentifier: id, verifiedContainerIdentifier: id, dataContainerPath: dataRoot))
        }
    }
    func testFallbackRequiresExactIdentityAndApplicationClass() {
        let id = "com.tencent.xin"
        XCTAssertNotNil(ApplicationListingPolicy.rejection(bundlePath: nil, bundleIdentifier: id, dataContainerPath: dataRoot))
        XCTAssertNotNil(ApplicationListingPolicy.rejection(bundlePath: nil, bundleIdentifier: id, verifiedContainerIdentifier: "com.other.app", dataContainerPath: dataRoot))
        for root in [dataRoot + "/Documents", dataRoot.replacingOccurrences(of: "/Application/", with: "/PluginKitPlugin/"), dataRoot.replacingOccurrences(of: "/Application/", with: "/InternalDaemon/"), "/tmp/Example", dataRoot + "/../28B3EF9C-568D-4F67-82A6-8230B2CFADB8"] {
            XCTAssertNotNil(ApplicationListingPolicy.rejection(bundlePath: nil, bundleIdentifier: id, verifiedContainerIdentifier: id, dataContainerPath: root))
        }
    }
    func testFallbackNeverOverridesExplicitServiceOrIdentityRejection() {
        for reason in ["隐藏组件", "扩展或非应用包类型", "安装包身份与容器标识不一致"] {
            XCTAssertEqual(ApplicationListingPolicy.rejection(bundlePath: nil, excludedReason: reason, bundleIdentifier: "com.tencent.xin", verifiedContainerIdentifier: "com.tencent.xin", dataContainerPath: dataRoot), reason)
        }
        for id in ["com.apple.WebKit.PushBundle.1234", "com.apple.RemotePassUIService", "com.apple.siri"] {
            XCTAssertNotNil(ApplicationListingPolicy.rejection(bundlePath: nil, bundleIdentifier: id, verifiedContainerIdentifier: id, dataContainerPath: dataRoot))
        }
        for path in ["relative/App.app", "/Applications/../Applications/App.app", installed + "/PlugIns/Share.appex"] {
            XCTAssertNotNil(ApplicationListingPolicy.rejection(bundlePath: path, bundleIdentifier: "com.tencent.xin", verifiedContainerIdentifier: "com.tencent.xin", dataContainerPath: dataRoot))
        }
    }
    func testVerifiedIdentityPersistsForCachedApplicationListing() throws {
        let app = AppInstance(displayName: "WeChat", bundleIdentifier: "com.tencent.xin", root: URL(fileURLWithPath: dataRoot), origin: "系统容器 · 应用分类v2", verifiedContainerIdentifier: "com.tencent.xin")
        let decoded = try JSONDecoder().decode(AppInstance.self, from: JSONEncoder().encode(app))
        XCTAssertNil(ApplicationListingPolicy.rejection(bundlePath: decoded.bundlePath, bundleIdentifier: decoded.bundleIdentifier, verifiedContainerIdentifier: decoded.verifiedContainerIdentifier, dataContainerPath: decoded.root.path))
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as! [String: Any]
        old.removeValue(forKey: "verifiedContainerIdentifier")
        let legacy = try JSONDecoder().decode(AppInstance.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.verifiedContainerIdentifier)
    }
    func testExplicitWeChatIconAliasOnly() {
        XCTAssertEqual(ApplicationListingPolicy.fallbackIconBundleID(for: "com.tencent.qy.xin"), "com.tencent.xin")
        for id in ["com.tencent.xin", "com.tencent.qy.xin.other", "com.tencent.ww", "org.clone.wechat"] {
            XCTAssertNil(ApplicationListingPolicy.fallbackIconBundleID(for: id))
        }
    }
}
