# WCMigrate 0.5 / 独立配置备份与居中确认

2026-11-12。用户最新要求覆盖0.2–0.4的迁移前自动配置保护。

## 迁移与配置完全解耦

DirectMigrationService不再在预检或执行时读取/保存两边Preferences，任务preferences/preferenceAbsences留空以兼容旧记录。普通文件替换/转换/合并以及配置应用都不自动备份。配置页的手动备份、plist/ZIP导入、ZIP分享、删除、选应用替换/合并保留。修改的应用内配置相对路径只用于手动配置操作。

预检也不探测未选中的Library/Preferences；未选配置目录不可读、缺失或含链接不应挡住选定Documents迁移；选定范围内仍严格拒绝符号链接和特殊文件。

## 提示与界面

全部confirmationDialog改为居中的系统alert，包含迁移执行、配置应用、删除配置、完整扫描。输入路径/配置目录等原有alert保持居中；诊断仍用可滚动/复制详情sheet。截图中顶部箭头气泡来自confirmationDialog在当前系统上的popover呈现，不是文件错误。

迁移确认按钮改为“确认开始迁移”，不再捆绑“保存插件配置”。首页、映射、确认和设置明确配置为独立手动操作。

删除备份保存位置选择、位置显示和复制入口，设置也不显示副本路径。PreferencesCopies固定在本App的Application Support/XChatTransfer下。移除旧外部存储bookmark设置，不再打开该目录；旧外部文件不自动删除或搬走。

排序：精确com.tencent.xin → 精确com.tencent.qy.xin → com.tencent.xin前缀 → com.tencent.qy.xin前缀 → 其他com.tencent → 其他。

## 图标实机证据与限制

用户提供0.4实机日志：WQ返回了/private/var/containers/Bundle/Application/<UUID>/WeChat.app，但Info.plist读取errno=1 Operation not permitted。证明问题在安装包读取授权，不是查不到安装路径，也不是Assets.car解码。备用LS接口失败的日志原先误称数据库也没路径，本版更正。

核对固定版本WQFiles README：iOS26图标API只返回占位且不能读其他App安装包；App Bundles条目说明iOS26和27.0.1可能打不开安装目录。上游能从数据库给路径不等于该系统可读安装文件。因此不宣称接入WQ就能解决该权限限制。

新版本在文件读取前依次尝试安装UUID容器、.app、Info.plist授权，每次均重新真实open测试，记录grant结果和open errno；拿到token不冒充可读。读不到时明确报告系统/签名限制，保留已取得路径。支持的系统仍尝试PNG及系统图标回退。未验证该用户设备上新探测能取得权限；没有用网上图标或伪造图标冒充真实安装包读取。

## 保留项

0.5.0/5。BundleID local.xchat.transfer、group.local.xchat.transfer、最低iOS17.0、arm64、SwiftUI+ObjC+C、SDK26隔离构建不变。没有全聊天备份、整任务回滚、自动续传或数据库行级合并。真实iOS26/27安装及迁移兼容性未在本机验证。
