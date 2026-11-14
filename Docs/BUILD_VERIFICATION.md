# 1.0.0 / 11 构建验收

2026-11-12，隔离使用独立iOS26 SDK编译、链接并打包，没有修改原始SDK或全局xcode-select。

## 实际工具

- 默认安装：Xcode16.2、Swift6.0.3、iPhoneOS18.2 SDK。
- 本次：项目build/XcodeHost.app内隔离宿主；build/toolchains/swift-6.2.xctoolchain/usr/bin/swiftc（Swift6.2）与clang17。
- 链接驱动：隔离宿主默认clang16，ld1115.7.3。
- SDK：用户提供的独立iPhoneOS26.0.sdk，通过当前进程DEVELOPER_DIR和-sdk iphoneos26.0接入；实际编译/链接的SDK参数指向SDK26。用户机器路径不写入公开文档。
- Swift6.0.3无法解析SDK26部分~Copyable/~Escapable/@lifetime接口，因此使用独立Swift6.2。未关闭Swift模块或编辑SDK头文件。

## 产物与二进制

`build/WCMigrate-1.0.0-sdk26-adhoc.ipa`

SHA-256：`6e45985ec6aaf98dd278befd4ba978c400c82908dfc3aeb8424463622554b4d7`

主Mach-O：arm64、LC_BUILD_VERSION平台IOS、SDK26.0、最低17.0。Info.plist版本1.0.0/build11、DTSDKName iphoneos26.0、MinimumOSVersion17.0，与二进制一致。Bundle ID local.xchat.transfer，App Group group.local.xchat.transfer。没有App扩展，因此没有额外扩展Mach-O验收项。

ZIP完整性、独立解包后的codesign --verify --deep --strict、entitlements核对通过。adhoc签名，没有embedded.mobileprovision，需要适合设备的重签安装环境。真实设备安装、运行、微信兼容性和手机性能均未验证。

## 复现与证据

```sh
SDK26='/absolute/path/iPhoneOS26.0.sdk' XCODE_SOURCE='/Applications/Xcode.app' ./Scripts/build-sdk26.sh
python3 Scripts/verify-ipa.py build/WCMigrate-1.0.0-sdk26-adhoc.ipa
./Scripts/package-source.sh
```

本机完整日志保存在项目build内（不加入Git）：v100-sdk26-source-label-final.log、sdk26-final.log、sdk26-macho.txt、sdk26-signature.log、sdk26-zip-validation.log、v100-final-verification.json。源码包不包含日志、研究克隆、Apple SDK、工具链或个人路径。

72项核心测试（大文件可选项另见测试说明）、ZIP host测试通过；1.0设置界面明/暗模式定向回归通过；前版完整UI回归详见TEST_MATRIX.md。

最终源包在独立导出目录重新运行核心测试：72项、1项可选大文件跳过、0失败。最后一次SDK26目标平台识别失败日志sdk26-build-20261112-183213.log保留，结束模拟器构建后重试成功；未更改全局SDK或平台。


## 应用列表未知布局修订（1.0.2 Build 27）

用户 iOS 26.4.2 日志中，数据库 15.8 MB，固定布局候选 26.5 仅映射 476/2056 条路径，触发低于半数时拒绝整批解析的条件；26.5 是解析候选标签，不是检测到的系统版本。完整 inode 扫描预估约 25–28 小时，不作为实用修复。

对照 WQFiles 提交 0d9c28c7e283e729b7cef4e18adcce145920dbdb、WQManager 提交 112586b81563ce8bdb844fd9480e0d3e004821d7 和 GestaltX 提交 d1d5473734440e8f2e797494ac373427c02fd674。采用新版 WQFiles 的未知布局路径发现、按系统 build 缓存、稳定读取和解析工作量限制。推断结果不作为容器 Bundle ID，仍由现有 WQAccess 标识符读取链核验；身份无法核验则不展示为可用应用。未导入 GestaltX 源码。

Scripts/test-launchservices.sh 启用 WQ_LS_TESTING，全部解析回归通过（含本地部分布局匹配回退测试）；Swift 核心测试 125 项、跳过 1 项、失败 0 项。首次本地测试发现默认 macOS SDK 缺少 CoreGraphics，脚本改用完整的 CommandLineTools macOS SDK；上游 WQVerbatim API 与现有本地化不匹配，名称返回适配为现有接口。

构建命令：

```sh
SDK26='/Users/xuegao/Downloads/ClassDump-com.phoenix.video😡-1792882659/SDKDownloads/iOS-SDKs-26/iPhoneOS26.0.sdk' IPA_OUTPUT="$PWD/build/WCMigrate-1.0.2-app-list-fix.ipa" Scripts/build-sdk26.sh
```

Mach-O：arm64、iOS 真机平台 2、SDK26.0、最低系统17.0；无扩展；ZIP 完整性及 adhoc 签名验证通过。未包含 provisioning profile，需要重新签名安装；未进行用户设备上的安装和运行验证。合成数据库测试不等于用户原始数据库验证。

IPA SHA256：01659894d46364dc9a7d4e33b141143580b838a245533ee03c18201615ca8ce6。


## 仅显示五个应用的后续修订

更新后的 iOS 26.4.2 设备日志确认，未知布局备用解析已经发现 466 个 Application 数据容器和 1517 个扩展容器，但 Swift 应用分类要求存在 .app 安装路径；未知布局刻意不提供猜测的安装路径，造成微信等第三方应用被拒绝。此前数据库解析修订未覆盖这个筛选环节。

本次保留安装包身份冲突、隐藏标签、扩展与服务的显式排除。安装路径缺失时，允许通过 WQAccess 确认标识并取得授权的顶层 Application/UUID 数据容器作为第三方应用候选；不接受 PluginKitPlugin、InternalDaemon、嵌套目录或身份不匹配。Apple 系统容器缺少安装信息时仅保留明确列出的常用用户应用。第三方 Application 类容器仍可能包含未标记的辅助应用，这种备用分类不等于安装包 APPL 元数据验证。身份来源不使用未知布局推断的 Bundle ID。

将分类缓存升级为 v2，保存已确认的容器标识；旧 v1 缓存触发重新发现，避免重启后再次过滤无安装路径的应用。新增发现汇总日志，分别记录候选数、身份授权确认数和缺少安装路径数。补充无安装路径的微信/多开、系统组件排除、身份不匹配、扩展路径、缓存兼容回归测试。Swift 测试共129项，跳过1项，失败0项。用户设备的最终应用数量仍待重新安装验证。
