> 0.5更新：用户EPERM日志和上游README均证实安装包读取存在系统限制；不承诺图标已修复。迁移和配置应用不再自动保存Preferences；备份独立手动，固定本App沙盒。详见REVISION_0.5.md，覆盖下文历史描述。

# WCMigrate 可行性报告（0.4）

2026-11-12。文件直接迁移已实现；真实微信聊天可读性尚未验证。只保存完整 Preferences 配置，不备份聊天、不承诺回滚。

## 参考仓库源码审查

WQFiles @ 86bc395a4d04408ef91ded2938fbee3c8cd07eb8：Objective-C；build.sh 使用 clang 构建 arm64，链接 UIKit/Foundation/Security/UniformTypeIdentifiers、sqlite3、z，adhoc App Group 签名。WQAccess 为容器授权、枚举、描述符 I/O 与安全操作；WQLaunchServices 解析 CSStore 并提供标识和路径映射；WQApps 为备份/恢复；WQSQLiteViewer/Save 为副本检查与保存；WQArchive / WQSharing 为 ZIP/共享；WQHealth 为访问诊断；tests 是 host fixture 与构建检查。XChat 只复用访问相关源码模块，使用独立 Core 备份协议。

AppsManager27 @ 9bc7b9bcc6850605810d8762e1045d679060b394：source/hook/src/WBHook.m Hook LSApplicationWorkspace / LSApplicationProxy；WQ*.m 为浏览器和访问实现；build_dylib.sh 构建 Hook；build_app.sh 需要外部 ADManager.app、注入器、证书与 profile。它不是完整开源 App 源码。不能将其闭源本体直接作为新工程基础。

两库的 WQFiles 部分 GPL-3.0-or-later；新工程 vendor 后采用相同许可证，保留署名及完整源码。Research 下 clone 不参与编译，vendor 固定源码参与编译。未复用 AppsManager 原版二进制。

## iOS 26 / 27 支持证据

以下均是上游 README / 源码声明，不是本项目实测：
- WQFiles README 称 iOS26.0–26.7.2 初步支持，测试过 26.7.1；应用/扩展/App Group 可通过 LaunchServices 数据取得；系统目录不可用；真实图标受限。
- WQFiles 声称 27.0.1、27.2 测试过；应用图标 / bundle 等能力依具体小版本变化。源码对 26.5 / 26.7 的 CSStore layout 有不同处理，不能仅按大版本保证兼容。
- AppsManager27 README 声称 iOS27.0.1 测试过，但不足以证明 iOS26 可用。
这些声明中包含高于本机既有 SDK 的版本描述，仅按仓库原文记录，未推断系统发布状态或泛化支持范围。

本机已验证：默认 Xcode16.2，iOS18.2 SDK，Swift6.0.3。用户提供的独立 iPhoneOS26.0.sdk 存在，SDKSettings 声明 Version26.0 / iphoneos26.0。Swift6.0.3 导入 SDK26 的最小样例失败，首个错误为标准库接口对外层泛型 ~Copyable 的 suppression 不支持，另含 ~Escapable 与 @lifetime。原始失败日志保留。
已配对设备由 devicectl 报告 iPhone17 Pro Max / iOS27.0.1；当前 host 无法挂载开发镜像，未在该设备安装或读取微信数据。报告不包含设备唯一标识。
完整 SDK26 构建证据另见 BUILD_VERIFICATION.md，不能将早期默认 SDK 的失败当成独立 SDK 不可用的结论。

## 应用发现和安装图标

公共沙盒 App 无法自然枚举和读写任意第三方容器。研究适配器需要签名 App Group 和目标系统上的 WQ 能力。不能把 group UUID 当 bundle ID。只有获得 bundle 标识与读取 grant 的容器才展示。

WQLaunchServices 的 wq_bundle_path_for_id 提供安装.app路径；本版经WQ授权读取Info.plist，匹配Bundle ID后使用CFBundleExecutable=WeChat识别候选，停止运行时也可识别；不枚举实时进程。本版暂缓识别筛选及提示，显示全部应用，精确com.tencent.xin最优先，然后xin前缀和其他com.tencent。用户界面称应用。

图标读取安装目录声明PNG及常见尺寸，ImageIO缩图、异步缓存，失败时尝试系统接口并过滤占位；不渲染有崩溃风险的Assets.car。不加载第三方应用代码。以上为已编译实现/源码能力，真实安装目录权限、图标与元信息覆盖率尚未设备验证。

## 当前迁移与限制

任意普通文件/目录显式映射已实现。替换清理目标多余内容，合并保留目标独有内容，这两种保留来源并用流式单文件临时写入/哈希校验。转换在同文件系统使用原子rename交换每对路径；缺失目标时排他移动，不创建大聊天中转副本。多对操作非整任务事务，失败/取消记录部分完成；掉电日志窗口需人工核对。两边配置目录（默认Preferences，可修改）先保存并验证。macOS 测试仅证明可丢弃文件上的文件行为；iOS 模拟器验证界面和自建 fixture，不代表容器授权或微信兼容。

真实容器的写权限、跨 Bundle ID 的数据库密钥/schema/账户关联、媒体索引和首启清理尚未验证。Keychain 与登录态不迁移。未实现全任务回滚/续传/聊天备份加密/ZIP 聊天导入导出。代码不声称从任意微信实例取得可读聊天。

IPA 是 adhoc 重签输入。普通真机安装需匹配证书/profile/App Group；已配对 iOS27 设备受当前开发镜像不匹配影响，未安装或运行。后续先在可丢弃自建容器验证权限与大文件/低空间/中断，再以有独立来源保障的样本核验目标微信，禁止把文件成功标记当聊天恢复证明。

0.4增加独立配置保存位置、plist/ZIP本地导入、ZIP分享、删除及选应用替换/合并配置；详细实现及新图标读取路径见REVISION_0.4.md。用户实机旧截图证明0.3曾能枚举应用但未取得图标，不能从该截图证明0.4图标已修复，也不能由旧泛化弹窗断定唯一故障原因。
