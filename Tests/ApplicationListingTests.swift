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
    func testExplicitWeChatIconAliasOnly() {
        XCTAssertEqual(ApplicationListingPolicy.fallbackIconBundleID(for: "com.tencent.qy.xin"), "com.tencent.xin")
        for id in ["com.tencent.xin", "com.tencent.qy.xin.other", "com.tencent.ww", "org.clone.wechat"] {
            XCTAssertNil(ApplicationListingPolicy.fallbackIconBundleID(for: id))
        }
    }
}
