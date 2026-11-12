# 图标与容器状态调查 / 0.5.1

2026-11-12。仅以代码和用户日志为证据；没有本机执行SDK26真机测试。

## 用户实机日志

iOS27.0.1，重签AppGroup group.8d3edcc3ba7b1929.1。

- WeChat com.tencent.xin：LS数据库返回安装路径；安装UUID目录、.app、Info.plist三次grant=NO；实际open Info.plist全部EPERM；系统接口无可用图像。
- com.tencent.qy.xin相同。
- Wallet com.apple.Passbook、Weather com.apple.weather、Watch com.apple.Bridge、PosterBoard：Info.plist同样EPERM，但最终系统接口返回图像。说明系统图标API与直接读安装包是独立权限路线。
- VoiceMemos：/System/Library/AppPlaceholders/VoiceMemos.app 的Info.plist可读；PNG搜索候选0；最终系统接口成功。
- FinanceStub/VoiceOverTouch返回网格图仍被旧启发式算成功，不能把系统返回UIImage当作真实图标铁证。

## WQManager源码核对

仓库 https://github.com/hseons/WQManager ，本次读取commit d356dedfa9a39dd166a6f47e55b0114ad0c38076。只读克隆在build/Research-WQManager，不参与App编译或源码交付。

WQMAppIconService.m 的 WQMResolveIcon 先尝试LSApplicationProxy的primaryIconDataForVariant等、iconsOfAllSizes、applicationIconImageForFormat。NSData还尝试BOMStore/CoreUI分层图标解码；然后按条件尝试UIImage私有接口、IconServices ISBundleIcon/ISGenerationRequest、SpringBoardServices图标数据/路径、CUICatalog读取Assets.car、PNG。扩展还尝试父Bundle ID。它有多种占位指纹和灰色重复图识别、内存缓存、7天本地磁盘缓存。

关键区别：本地无结果时WQMAppIconFetchRemoteIcon调用Apple公开 https://itunes.apple.com/lookup?bundleId=... ，从artworkUrl512/100/60下载图标；默认启用，可设置关闭；默认商店无结果会试cn，临时错误重试，不命中24小时过期。此磁盘缓存是它自己下载/获取后的缓存，不是已证实读到了SpringBoard系统缓存。

README明确记录LaunchServices -54/process may not map database、iconservicesagent -609/client disallowed；说明第三方请求仍受限，系统允许自己的/第一方/CoreType图标，商店应用用网络补齐。未上架/改Bundle ID的分身可能仍为占位。

系统缓存探测函数WQMAppIconDiagProbeCache只在诊断模式下尝试候选目录/保存一份isdata样本；不是已经实现按Bundle ID提取缓存图标的产品回退链。代码有CoreUI路线也不构成其能在该用户系统上成功读取WeChat Assets.car的证据；@catch不能捕获abort或所有底层崩溃。

源码入口：

- https://github.com/hseons/WQManager/blob/d356dedfa9a39dd166a6f47e55b0114ad0c38076/README.zh-Hans.md#L99
- https://github.com/hseons/WQManager/blob/d356dedfa9a39dd166a6f47e55b0114ad0c38076/WQManager/WQManager/WQMAppIconService.m#L1422
- https://github.com/hseons/WQManager/blob/d356dedfa9a39dd166a6f47e55b0114ad0c38076/WQManager/WQManager/WQMAppIconService.m#L1599

## 本版实际修改

设置删除“界面 / iOS26 SDK · 原生Liquid Glass”整行及无用状态属性。应用列表持久化恢复时显示“已载入记录、本次未复查”，不恢复旧权限结论；进入设置或完成扫描后，按优先级抽查最多3个已保存系统应用的根目录，grant后真实open+readdir，统计当前成功数。只读，不写入，不枚举整棵目录；明确不是所有容器、所有子项、安装包或写权限的验证。无系统记录时提示先检测本机应用。

运行日志新增“检测图标缓存（只读）”：仅在点击时尝试三个历史候选根目录，记录grant、实际opendir errno、最多32个条目及普通文件前8字节。候选com.apple.IconsCache、com.apple.iconservices、com.apple.springboard.sharedimagecache不被当作本机已存在目录。无递归扫描、无缓存清理、无图标映射/提取成功宣称。探测报告可复制/分享，使用普通诊断结果标题。

系统图标诊断增加返回空图/已识别占位/通过单一占位指纹筛选的区别；仍是启发式，未保证识别全部占位变体。安装包错误区分EPERM/EACCES与ENOENT，不把不存在路径一概称为系统拒绝。

本版没有移植WQManager的私有渲染/服务调用，也没有加入联网图标下载；不通过商店图片冒充本地安装包实际图标。文件迁移、独立手动配置、原entitlements、最低iOS17/arm64保留。
