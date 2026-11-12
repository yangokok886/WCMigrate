# WCMigrate

适用于 **iOS 26–27.2** 的原生应用沙盒数据迁移工具，主要用于微信及其多开应用。版本 **1.0.0**，支持 iPhone / iPad。

[TG频道](https://t.me/xxuegao6) · [GitHub](https://github.com/yangokok886/WCMigrate) · [GPL-3.0-or-later](LICENSE)

## 功能

- 选择两个应用，以及沙盒内任意文件或文件夹；默认对应相对路径，也可自定义目标位置。
- **替换**：应用1覆盖到应用2，所选目标目录内多余内容删除，应用1保留。
- **转换**：两边所选路径互换；目标不存在时移动到目标。使用同文件系统原子交换或排他移动。
- **合并**：应用1覆盖到应用2，同名直接替换，应用2独有内容保留，应用1保留。
- 插件配置独立手动备份，默认选择 `Library/Preferences`，支持递归“仅备份 plist 文件”。不会自动备份几十GB聊天数据，配置备份也不是迁移前置条件。
- 配置支持ZIP分享、plist/ZIP导入，以及对指定应用执行配置替换或合并。
- 操作期间屏幕常亮，显示进度、估算剩余时间和“请勿离开当前页面”。
- 新任务持久化检查点；中断后可在迁移记录或未完成配置备份中检查并继续。长诊断支持分页阅读、全文复制与分享。

复制优先使用APFS写时复制，不支持时回退流复制，并保留完整哈希校验。应用图标优先读取本地，必要时可通过Apple公开商店接口查询Bundle ID；可关闭商店回退。

## 使用边界

操作前退出两边应用。替换会删除所选目标范围内的多余文件，转换会改变两边内容；没有整任务回滚。恢复会校验来源、目标和已完成结果，发现外部变更或未知状态会停止。未完成单文件重新传输，不是字节偏移续传，也不保证任意掉电或存储故障均能恢复。旧版任务没有完整恢复计划。

文件合并不是SQLite聊天记录行级合并；文件校验通过不代表微信账号、密钥、数据库版本与媒体索引兼容。Keychain与登录态不迁移。系统权限和签名影响容器与图标读取，不能保证每个应用均可访问。支持系统范围不等于每个小版本已完成真机验证。

## 构建

SwiftUI + Objective-C + C，入口 `XChatTransfer.xcodeproj`；`project.yml` 可由XcodeGen重建。单主应用target，无分享扩展，无外部Swift Package/CocoaPods依赖。保留最低部署iOS17、Bundle ID `local.xchat.transfer` 与App Group `group.local.xchat.transfer`；容器访问功能要求iOS26及以上。

使用含iOS26 SDK、兼容Swift编译器的Xcode，在工程中配置自己的签名团队和App Group后构建。无设备授权的adhoc校验签名不能直接普通安装。

```sh
xcodegen generate
xcodebuild -project XChatTransfer.xcodeproj -scheme XChatTransfer \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO build
./Scripts/test.sh
./Scripts/test-archive.sh
```

独立SDK26与Xcode16.2宿主的隔离构建（需要macOS、XcodeGen、网络下载Swift6.2及足够磁盘空间）：

```sh
SDK26='/absolute/path/iPhoneOS26.0.sdk' \
XCODE_SOURCE='/Applications/Xcode.app' ./Scripts/build-sdk26.sh
python3 Scripts/verify-ipa.py build/WCMigrate-1.0.0-sdk26-adhoc.ipa
./Scripts/package-source.sh
```

脚本仅在项目build目录准备工具，不更改全局xcode-select或覆盖原始SDK。源码不包含Apple SDK、Xcode或Swift工具链。详见 [测试说明](Docs/TEST_MATRIX.md)、[构建验收](Docs/BUILD_VERIFICATION.md)。

## 许可证与逐项致谢

本项目采用 **GPL-3.0-or-later**，见 [LICENSE](LICENSE)。第三方源码保留原始版权头和许可；分发修改后的二进制时须遵循GPL要求提供对应源码与构建脚本。

- 感谢 **Taj C (forcequit)** 的 [worse_query](https://github.com/forcequitOS/worse_query)：容器访问使用该漏洞利用技术，经下述容器访问源码接入。
- 感谢 **kolbicz** 的 [WQFiles](https://github.com/kolbicz/WQFiles)：实际包含容器授权、LaunchServices枚举、核心辅助、本地化与ZIP源码；图标路径查找和占位图判断改编自其实现。
- 感谢 **murk-sus** 的 [KAMUI](https://github.com/murk-sus/kamui-escape)：fsgetpath容器枚举思路经上述源码沿用。
- 感谢 **hseons** 的 [WQManager](https://github.com/hseons/WQManager)：参考本地图标优先、系统图标多格式及Apple商店回退策略，没有包含其源码文件或二进制。
- 感谢 [AppsManager27](https://git.jbjflab.top/admin/AppsManager27) 的维护者：早期可行性调研参考，没有包含其hook、原应用或IPA。
- 感谢上游本地化贡献者 [iosrxwy](https://github.com/iosrxwy)、[hfip](https://github.com/hfip)、[hooray804](https://github.com/hooray804)。

固定提交、具体文件和引用关系见 [第三方源码与致谢](Docs/THIRD_PARTY_NOTICES.md)。Apple系统框架、zlib、SQLite通过系统SDK链接，仓库不捆绑其源码。
