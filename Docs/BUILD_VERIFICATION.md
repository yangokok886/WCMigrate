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

SHA-256：`05dedead4b3f429412ac022624980dd8707b8401549b5c5a3d66634ed5df56a9`

主Mach-O：arm64、LC_BUILD_VERSION平台IOS、SDK26.0、最低17.0。Info.plist版本1.0.0/build11、DTSDKName iphoneos26.0、MinimumOSVersion17.0，与二进制一致。Bundle ID local.xchat.transfer，App Group group.local.xchat.transfer。没有App扩展，因此没有额外扩展Mach-O验收项。

ZIP完整性、独立解包后的codesign --verify --deep --strict、entitlements核对通过。adhoc签名，没有embedded.mobileprovision，需要适合设备的重签安装环境。真实设备安装、运行、微信兼容性和手机性能均未验证。

## 复现与证据

```sh
SDK26='/absolute/path/iPhoneOS26.0.sdk' XCODE_SOURCE='/Applications/Xcode.app' ./Scripts/build-sdk26.sh
python3 Scripts/verify-ipa.py build/WCMigrate-1.0.0-sdk26-adhoc.ipa
./Scripts/package-source.sh
```

本机完整日志保存在项目build内（不加入Git）：v100-sdk26-release-verified.log、sdk26-final.log、sdk26-macho.txt、sdk26-signature.log、sdk26-zip-validation.log、v100-final-verification.json。源码包不包含日志、研究克隆、Apple SDK、工具链或个人路径。

72项核心测试（大文件可选项另见测试说明）、ZIP host测试通过；1.0设置界面明/暗模式定向回归通过；前版完整UI回归详见TEST_MATRIX.md。

最终源包在独立导出目录重新运行核心测试：72项、1项可选大文件跳过、0失败。最后一次SDK26目标平台识别失败日志sdk26-build-20261112-183213.log保留，结束模拟器构建后重试成功；未更改全局SDK或平台。
