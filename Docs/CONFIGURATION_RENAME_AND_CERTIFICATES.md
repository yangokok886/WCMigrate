# 配置文件名适配与证书到期提醒（1.0.0 build 12）

## 配置文件名

设置「自动适配配置文件名」默认开启。迁移及配置还原完成校验后，将被迁移的来源应用自身 `<来源 Bundle ID>.plist` 原子改名为 `<目标 Bundle ID>.plist`；插件自己的配置域不改名，来源副本不改动，转换分别适配两边。已有目标同名普通文件会被原子替换。

关闭后，中央系统弹窗询问是否改名，同时文件任务继续执行。提前确认会在复制校验结束后执行；任务结束后确认立即执行。「暂不改名」保留原名称。任务中止或失败时不改名，继续任务完成后重新处理。

改名独立于复制/转换的恢复日志。完成文件操作后的待改名事项保存在本应用沙盒的 `configuration-renames.json`，重启时重新处理。执行前复查来源 inode/device、大小和 SHA-256，以及目标内容的 SHA-256；外部修改或符号链接导致拒绝并记录诊断。重启时数据容器路径改变会拒绝旧路径，不能保证跨重装自动处理。

导入的完整 WCMigrate 备份使用原始 Bundle ID；普通 ZIP/plist 没有来源身份时，只有文件名匹配已发现应用包名或明确的微信域且唯一时才识别，避免将插件域误改成应用域。无法唯一识别会保留文件名并记日志。手动映射已经改成目标文件名的项目无需再次适配。

命名适配仅是文件层操作，不修改 plist 内容，不声称能处理 App Group、钥匙串或应用内部数据库兼容；操作时需退出两边应用，重新打开后核对偏好缓存和配置生效情况。

## 签名与提醒

- 读取当前安装包的 `embedded.mobileprovision`（CMS SignedData 的 ASN.1 内容），提取 `Name`、`UUID`、`ExpirationDate`、`DeveloperCertificates`。
- X.509 DER 有效期兼容 UTCTime 与 GeneralizedTime。从 Mach-O `LC_CODE_SIGNATURE` 的 CMS 槽匹配 DeveloperCertificates，唯一匹配时显示实际证书；匹配不唯一时明确显示候选并保守取最早日期。
- 有效截止取描述文件和匹配证书到期时间的较早值。此功能是本地信息读取，不验证 CMS 的信任链、联网吊销状态或安装授权。
- 默认关闭；开启申请系统通知授权。选择前三天、前一周、前半个月（15天）、前一个月（30天）。在提醒期内每天 09:00 安排一条本地通知，到到期日为止。当天晚于09:00开启会尽快提醒；到期后不安排过去的通知。
- 最多31条一次性通知，前台激活重新读取重签后的描述文件并更新。前台也展示通知；关闭开关仅取消本功能通知，不删除其他通知。记录已安排/已过期的当日提醒，避免反复打开页面重复通知。
- 无描述文件时明确显示无法检测（临时签名、模拟器等），不捏造证书名称/日期。系统通知权限、专注模式及系统调度会影响实际展示。
- 所有解析实现为本项目新增代码，没有复制 fastlane 的 Ruby 源码；参考及感谢如下。

## 参考与感谢

- [Apple TN3125: Inside Code Signing: Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)：描述文件结构、DeveloperCertificates 和到期字段。
- [fastlane provisioning_profile.rb](https://github.com/fastlane/fastlane/blob/master/fastlane_core/lib/fastlane_core/provisioning_profile.rb)：CMS 解码、描述文件字段读取思路，感谢 fastlane 维护者。未打包 fastlane 或 OpenSSL。
- [Apple UserNotifications — Scheduling a notification locally from your app](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)：UNCalendarNotificationTrigger、授权和系统通知调度。

## 验证边界

核心测试覆盖替换、合并、双向转换后改名、保留来源与插件域、待办重启、目标被改动时拒绝、symlink拒绝、单文件映射、CMS截断/无效输入、两种证书有效期格式、四种提醒区间和过期边界。UI测试覆盖设置及改名弹窗。模拟器没有真实描述文件，无法代替已重签 iPhone 上的实际每日通知及配置生效测试。

## 本次构建验证结果

- 81 项核心测试：0 失败、1 项可选大文件测试跳过；归档测试通过；2 项 UI 测试通过。
- SDK26 Release 编译链接成功。独立 Swift 6.2 / Clang 17，项目内 Xcode 宿主 linker 1115.7.3。SDK 路径沿用本机独立 iPhoneOS26.0.sdk；未修改全局工具链或 SDK。
- 新增文件类型判断复用现有 CSupport 的 XCTModeIsRegular，避免旧宿主与独立 SDK 的 Darwin Swift overlay 常量链接不兼容；SHA256 复用 CommonCrypto。
- 主程序 arm64，LC_BUILD_VERSION：IOS / SDK26.0 / minOS17.0；无扩展。Bundle ID、App Group 保持原值。Info.plist 与二进制一致；ZIP 和临时签名验签通过。
- 产物：build/WCMigrate-1.0.0-build12-sdk26-adhoc.ipa
- SHA-256：06c456640769e0110d0b10dbf2368de8b3017c19c884b2a4db83f7a9f032d6d1
- 临时签名无描述文件，是重签输入；未验证真机安装、真实应用配置生效及每日通知。
