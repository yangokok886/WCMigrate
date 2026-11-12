# 架构

## 工程

SwiftUI + Objective-C + C，单主App target `XChatTransfer`，另有UI测试target，无分享/其他扩展。XcodeGen入口project.yml。版本1.0.0/11，显示名称WCMigrate，Bundle ID local.xchat.transfer，App Group group.local.xchat.transfer，最低部署iOS17；访问适配器需要iOS26以上。无storyboard/xib、外部Swift Package、CocoaPods或第三方二进制framework。

## 模块

- App：应用选择、路径映射、操作进度、配置库、历史恢复、设置与诊断。系统文件选择器使用稳定UIViewController宿主；诊断原生文本分页，复制全文。
- Core：安全路径解析、预检、清单、备份/迁移、持久恢复日志、SHA-256、进度估算、商店图标查询。Package.swift仅提供本机核心测试。
- ContainerAccess：Objective-C容器授权桥接、LaunchServices元数据、图标查找与诊断。
- CSupport：CommonCrypto、POSIX安全打开、APFS克隆、原子交换和排他移动封装。
- Vendor：固定版本第三方源码，详见THIRD_PARTY_NOTICES.md。

## 文件安全与恢复

源/目标限制在所选应用根内，拒绝越界、符号链接和重复父子选择。替换/合并每次暂存并核验一个文件后提交，保留完整哈希校验；优先APFS写时复制，回退4MiB缓冲流复制。空间与UI进度查询节流。

转换使用同文件系统renamex_np原子交换；目标不存在时排他移动。不支持的文件系统或权限明确失败，不隐式降级为不可恢复的双重复制。多条映射并非整任务事务。

新任务持久保存原始树、完成映射、交换状态和待提交临时文件路径。恢复重新检查来源/目标身份、原始/已完成状态和校验值，识别已交换路径，防止重复交换。未知或外部修改状态拒绝继续；只清理精确记录的任务临时文件。已完成文件核验后跳过，未完成单文件重新传输。配置备份有独立的未完成任务计划。

没有字节偏移续传、全任务回滚或任意掉电/磁盘故障恢复保证。文件成功不等于微信内部数据兼容；操作前应退出两边应用。目标旧数据不自动备份。

## 配置与隐私

配置独立手动备份到本软件沙盒，允许递归仅包含plist及目录结构；不跟随链接。恢复可替换或合并，ZIP导入有路径、CRC、尺寸与链接校验。

迁移本机执行。可选商店图标回退仅通过Apple公开接口查询Bundle ID并下载图像，不上传聊天和配置。无后台服务器依赖。
