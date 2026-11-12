# 0.2 用户需求修订

2026-11-12。以当前用户请求为准，原 PRODUCT_PLAN 保留为历史材料。

取消“迁移前备份整份聊天数据”的设计。不复制几十 GiB 的来源/目标聊天到独立备份库。迁移直接写目标，保留来源；仅保存两边容器相对路径 `Library/Preferences` 的完整内容，不限 plist，不处理系统全局 /Library/Preferences。

未指定删除来源，因此采用保留来源的迁移方式。配置副本不具备恢复聊天能力。没有目标聊天恢复点，故已覆盖聊天不能完整回滚；执行确认、停止/后台提示、任务记录均反映这一点。单文件校验临时文件仍需要空间，不承诺零额外空间。

主要变更：App 下首页/实例/目录/映射/确认/配置/进度页面；AppStore 协调；Core/PreferencesService.swift 与 DirectMigrationService.swift；Tests/DirectMigrationTests.swift；UITests/MigrationUITests.swift；project.yml 版本和测试 target；Scripts/package-sdk26.sh 与 verify-ipa.py；当前 README 与 Docs。

未变更其他工程、原始 SDK、全局 Xcode 选择、最低 iOS17.0、Bundle ID、entitlements 和主应用签名结构。
