# WCMigrate 0.5.3 / 8

2026-11-12。本次只修改 XChatTransfer 内文件，保留原 Bundle ID、App Group、签名结构、arm64 和最低 iOS17.0；设置的支持范围仍为 iOS26–27.2。

## WQManager 对照

参考本地只读克隆 build/Research-WQManager，提交 d356dedfa9a39dd166a6f47e55b0114ad0c38076。
WQMAppScanner.m 257–325：从应用数据容器扫描，排除自身，校验容器标识，未用顶层 .app 安装路径严格筛掉非应用。
WQMAppsViewController.m 613–620：列表筛选主要按搜索文字，非应用分类过滤。
WQMAppIconService.m 1422–1458：自身本地图标失败后，逐级尝试 Bundle ID 的父前缀；没有 com.tencent.qy.xin 到 com.tencent.xin 的专门映射。商店查询按 Bundle ID，不可推定任意多开来源。

## 实现

Core/ApplicationListingPolicy.swift：数据容器标签不再当作应用证据。允许 /var 或 /private/var/containers/Bundle/Application/<UUID>/<Name>.app，以及 /Applications/<Name>.app、/System/Applications/<Name>.app；排除嵌套包、扩展、框架下服务、路径穿越和无可核验安装路径的容器。
ContainerAccess/XCTAppMetadata.m：优先 WQ 数据库路径，缺失时使用现有 LS 备用路径；可读 Info.plist 校验 CFBundleIdentifier、CFBundlePackageType、NSExtension、LSUIElement、LSBackgroundOnly、SBAppTags；可用 LS 代理补充 hidden 标签和明确的内部服务/扩展类型。不以图标是否存在判断应用，不按 com.apple 全部删除。
App/AppStore.swift：应用过滤在全部选择入口共享的数据源执行，记录每个排除原因；旧版系统列表缓存失效并自动重新扫描，用户导入目录保留；失去有效身份的已有选择清空。未验证容器不会伪装成可选应用。诊断输出为“应用筛选 Bundle ID · 已排除: 原因”。
App/ApplicationIcon.swift：明确用户授权的单一映射 com.tencent.qy.xin → com.tencent.xin，仅在自身本地图标失败后使用；共享微信图标缓存/请求，商店图标开关仍生效。只复用图像，不修改应用名、Bundle ID、容器或迁移身份。其他未知多开不猜测来源。
版本、验证/打包脚本、XcodeGen 工程、README 随之更新；未修改 Vendor 或其他项目。

## 验证和边界

58 项核心测试（本次新增3项：真实安装路径保留、服务/扩展/未知容器排除、精确图标映射），WQArchive host 测试通过。SDK26 Release 编译链接、Mach-O、entitlements、ZIP 和 adhoc 验签通过。本次未重跑 UI 测试；0.5.2 的 UI 测试不作为0.5.3新增筛选行为的证明。

没有连接用户手机：不宣称已确认其全部非应用条目被过滤，或 qy.xin 图标已实际显示。若系统不提供包类型/隐藏标记，仍可能有顶层 .app 形式的内部应用无法进一步区分；如果安装路径完全不可获取，该应用会被排除并写原因。商店图像不证明安装包资源可读。无 provisioning profile，需要合适的重签/安装方式；未做真机安装与运行测试。

复现：Scripts/build-sdk26.sh；Scripts/package-source.sh。完整工具链、产物和哈希见 BUILD_VERIFICATION.md。
