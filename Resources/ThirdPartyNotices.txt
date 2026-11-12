# 第三方源码、参考与逐项致谢

WCMigrate使用GPL-3.0-or-later，完整许可见根目录LICENSE和Vendor/WQFiles/LICENSE。以下区分实际包含的源码、技术来源和调研参考。

## 实际包含：WQFiles

感谢 **kolbicz**，仓库：https://github.com/kolbicz/WQFiles 。固定提交 `86bc395a4d04408ef91ded2938fbee3c8cd07eb8`，GPL-3.0-or-later。

Vendor/WQFiles保留与该提交逐字一致的原始文件及LICENSE：

- WQAccess.h/.m、WQAccessSafety.h：沙盒授权、容器访问、描述符IO与安全操作。
- WQLaunchServices.h/.m：应用与容器元数据枚举。
- WQCore.h/.m：底层辅助。
- WQLocalization.h/.m：上游本地化。
- WQArchive.h/.m：ZIP读写。

Tests/ArchiveTests.m保留上游ZIP测试，调整include路径。ContainerAccess/XCTAppMetadata.m的图标文件查找和系统占位图判断改编自同提交WQUI.m；原WQUI.m不参与构建。XCTContainerBridge为本项目集成桥接。

## 漏洞利用技术：worse_query

感谢 **Taj C (forcequit)**，仓库：https://github.com/forcequitOS/worse_query ，GPL-3.0-or-later。通过上述WQAccess实现接入worse_query沙盒扩展技术，并非另行捆绑整个worse_query仓库。保留原始技术署名。

## 容器枚举技术：KAMUI

感谢 **murk-sus**，仓库：https://github.com/murk-sus/kamui-escape 。上游标注的fsgetpath枚举技术来源，经WQAccess沿用，没有另外导入KAMUI源码文件。

## 图标实现参考：WQManager

感谢 **hseons**，仓库：https://github.com/hseons/WQManager 。参考提交 `d356dedfa9a39dd166a6f47e55b0114ad0c38076`，GPL-3.0-or-later。

参考WQMAppIconService.m的本地优先、系统图标多格式、未知图标比较及公开iTunes Lookup回退、缓存和重试策略，对应本项目Core/StoreIconLookup.swift、App/ApplicationIcon.swift、ContainerAccess/XCTAppMetadata.m。未包含其源码文件、私有渲染器或应用二进制。商店图片运行时下载，不作为安装包可读证据。

## 可行性调研参考：AppsManager27

感谢项目维护者，仓库：https://git.jbjflab.top/admin/AppsManager27 。调研提交 `9bc7b9bcc6850605810d8762e1045d679060b394`。

仅作早期架构与可行性调研，没有将其hook、注入脚本、IPA或原始专有Apps Manager应用加入构建，不对未使用部分作重新授权声明。

## 上游本地化贡献

感谢 [iosrxwy](https://github.com/iosrxwy)（简体中文，[PR38](https://github.com/kolbicz/WQFiles/pull/38)）、[hfip](https://github.com/hfip)（阿拉伯语，[issue39](https://github.com/kolbicz/WQFiles/issues/39)）、[hooray804](https://github.com/hooray804)（韩语，[PR40](https://github.com/kolbicz/WQFiles/pull/40)）。这些信息来自固定版本上游README，随本地化源码一并致谢。

## 系统依赖与分发

SwiftUI/UIKit/Foundation/Security/ImageIO/CommonCrypto、SQLite及zlib通过Apple SDK/系统库链接，仓库不捆绑这些库的源码、SDK或二进制framework。XcodeGen与Swift工具链属于构建工具。

分发本项目及修改版本时，请保留这些声明、第三方原始版权头和许可证，并履行GPL对应源码义务。上述作者并未因此为WCMigrate提供背书。


证书到期提醒参考与感谢

感谢 Apple 的 TN3125 与 UserNotifications 文档，及 fastlane 的描述文件解析思路。新增 Swift/ASN.1 实现为本项目编写，未复制或打包 fastlane/OpenSSL 源码。
https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app
https://github.com/fastlane/fastlane/blob/master/fastlane_core/lib/fastlane_core/provisioning_profile.rb
