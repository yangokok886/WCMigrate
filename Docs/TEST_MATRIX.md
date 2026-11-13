# 测试说明

## 已验证

2026-11-12本机执行：

- 72项核心测试通过（含可选大文件测试）；1.0构建再测72项、其中1项可选大文件测试跳过，其余无失败。覆盖路径安全、覆盖语义、配置导入、递归plist过滤、哈希校验、中断恢复、来源/目标变更拒绝和交换不重复执行。
- WQArchive host测试通过，覆盖ZIP/ZIP64往返、兼容性、CRC及危险路径拒绝。
- 17项模拟器UI回归通过，覆盖迁移/合并/转换、配置备份恢复、系统选择器实际点击ZIP/plist、长诊断全文复制与分页、进度与恢复入口。
- 0.6最终再测2项进度/实际屏幕常亮状态/plist开关/历史恢复通过。
- 1.0修改为版本、应用列表文案、设置四行信息与开源声明，设置版本/作者/TG/开源链接的定向回归通过；最终结果记录在本机build/v100-settings-colors-light.log与v100-settings-colors-dark.log。
- 两份2147483665/2147483679字节稀疏文件交换，完整SHA-256与inode交换验证通过。256MiB密集文件克隆及强制流复制通过。稀疏文件不能作为手机大数据吞吐性能证据。
- 操作中独立进程直接_exit(77)，新进程恢复复制、转换、配置备份，完整内容校验通过。不同目录URL构造方式的恢复身份判断也有回归覆盖。

## 复现

```sh
./Scripts/test.sh
WCMIGRATE_LARGE_TEST=1 ./Scripts/test.sh
./Scripts/test-archive.sh
./Scripts/test-process-recovery.sh
./Scripts/test-ui.sh DEDICATED_SIMULATOR_UDID
```

UI测试使用专用模拟器及合成数据，真实文件选择器测试需预先在该模拟器Files中准备PickerBundle.zip、PickerPlugin.plist（参见UITests相应测试）。不要对有个人数据的设备做破坏性测试。

## 未验证与限制

真实iPhone安装/运行、iOS26–27.3每个小版本、容器授权、特定应用图标、微信数据库可用性、几十GiB真实文件及手机速度均未完成验证。iOS 27.3 的 LaunchServices 布局根据 WQFiles 公开适配增加，本机没有 27.3 设备日志供验证。Mac测试结果不能代表iPhone速度。

恢复是经校验的文件级继续，不是字节偏移续传；未知/外部变更状态拒绝继续。无全任务回滚，也不保证任意掉电或存储故障恢复。文件合并不是数据库行级合并。
