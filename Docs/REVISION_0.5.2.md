# WCMigrate 0.5.2 / 商店图标与运行日志

## 图标

沿用WQManager的本地优先、Apple公开商店图像回退策略，参考commit d356dedfa9a39dd166a6f47e55b0114ad0c38076。现有安装包PNG/系统图标路径保留；系统图标补充format10/8/2/0/1及多格式未知应用占位指纹。没有复制CoreUI分层渲染、SpringBoardServices或IconServices私有生成调用；这些不是商店联网回退的必要条件，也没有声称它们已经突破权限限制。

本地没有可用图像后，StoreIconLookup向https://itunes.apple.com/lookup发送该Bundle ID和entity=software，默认商店未命中再试cn。仅接受返回条目中完全相同的bundleId，不猜测分身/克隆原应用，不用模糊名称搜索。依次选择artworkUrl512/100/60，只接受HTTPS mzstatic.com或其子域。响应流式计数，查询1MiB/图像4MiB上限，单请求12秒超时，临时查询失败重试一次。图像通过ImageIO生成180px缩略图后保存，不显示未解码数据。

同BundleID并发请求共享任务；新查询按250ms节奏开始，缓存保存本App Caches，7天有效，系统可清理。只有默认/cn均明确无匹配时记录24小时未命中，HTTP/网络/解码失败不永久缓存为未命中。默认启用，可在设置关闭“商店图标回退”；关闭后展示本地结果，不使用远程缓存，排队请求在开始前复查设置；已经发出的请求不保证即时撤销。

记录“Apple商店图标/本地缓存”来源，与本地安装包及系统图标分开。商店图标可能不同于安装版本/主题/分身；未上架、改标识符、地区下架应用可能无结果。仅将查询的BundleID发给Apple，不发送聊天/配置文件/容器路径。所有迁移仍在本机进行。

## 设置与系统范围

新增“支持系统：iOS 26–27.2”，作为用户指定的产品支持范围。原最低部署字段iOS17.0保持，不以SDK版本擅改最低系统；支持范围不是各版本均已实机验收的声明。继续显示当前系统/AppGroup/容器实际复查状态，删除的“界面”介绍不恢复。

## 运行日志

新App/LogsView.swift：单列原生分组表面，与首页共用背景/颜色/圆角。操作日期、标题和简要详情分层，不把整页日志全用小号等宽字堆在一个单元格。搜索操作/路径/错误，分类全部/迁移/配置/异常；条目整行可点击，详情可选中或单条复制。底部固定完整诊断复制/分享按钮，复制后有完成反馈。

原始授权/图标日志进入独立“原始诊断”页，摘要与长文本分开，长文本默认折叠；仍可复制完整内容。缓存探测作为同风格工具行，保持只读，结果不是错误弹窗。

## 交付边界

版本0.5.2/7；BundleID local.xchat.transfer，group.local.xchat.transfer，arm64，最低iOS17.0不变。无扩展。配置独立手动、迁移不强制备份、替换/转换/合并语义保留。SDK26构建使用项目隔离宿主和Swift6.2；最终验收见BUILD_VERIFICATION.md、TEST_MATRIX.md。

## 新实机反馈：嵌套配置EPERM与复制

用户提供0.5.1/iOS27.0日志：手动配置保存的“检查目录与空间”阶段，对Library/Preferences/WeChatNeo/AnimatedEmoji/<hash>.json读取路径元信息lstat失败，errno=1。AppGroup存在，3个根目录抽查成功不代表该JSON可读。日志不能证明重签缺组，也不能证明JSON损坏。

核对WQAccess.m的wq_open：受拒后先尝试文件父目录授权再尝试文件本身。原桥接prepareRead只有wq_grant(path)，BackupService逐级PathSafety.resolve还会检查已经离开的祖先元信息，未在每一级重新准备访问。新版桥接先真实open+lstat，可读直接返回；EPERM/EACCES时补父目录/当前项grant，再记录实际open/lstat errno，不把grant成功当作读取成功。PathSafety.resolve/potential增加调用方可选的逐级访问准备，配置扫描/流式复制及迁移树接入，链接/路径边界检查保留。仍拒绝无法读取的配置，不跳过后谎报完整保存。用户设备是否恢复需真机复测。

复制：新增DiagnosticCopyButton，使用完整52pt按钮，setItems写入本机UTF8文本后读回比对；成功显示“已复制完整诊断”，失败显示分享导出提示。配置失败页面复制固定到底栏，不再是长文本中的细小按钮；提供分享，完整日志默认折叠。普通诊断、运行日志整份复制/单条复制使用同一组件。空diagnostic回退生成完整报告，避免复制空内容。只保存在本机剪贴板，不通过Handoff同步。

新增临时目录权限恢复/符号链接拒绝核心测试，新增模拟器失败页面复制回归；仅DEBUG允许构造可丢弃失败页面，不接触真实应用数据，不进入Release。最终结果见TEST_MATRIX.md。
