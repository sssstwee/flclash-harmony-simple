# FlClash 鸿蒙简洁版

基于 [tljk/FlClash-ohos 的 v0.8.94-ohos 分支](https://github.com/tljk/FlClash-ohos/tree/v0.8.94-ohos)，上游基线 `017c08b8f842fef37ffb3220605b2477380a6dc4`。保留 GPL-3.0 许可和上游版权；本分支并非 FlClash 官方发行版。

目标设备为用户提供的 Pura X View / HarmonyOS 7；该设备兼容性和后台稳定性需要真机验证。

鸿蒙包名为 `com.follow.clash.simple`，与上游独立安装；签名配置需要对应这个包名。Flutter/ArkTS 内部 MethodChannel 名称沿用上游，避免改变平台通信协议。

## 日常操作

1. 点击「导入订阅」，粘贴有效的 Clash / Mihomo 订阅链接。应用不提供节点。
2. 点击「连接」，自动选择可用线路；首次使用需要允许系统 VPN 授权。
3. 点击「断开」停止代理。

首页只有订阅、线路、连接按钮和设置入口。配置管理、手动选线、日志、语言等沿用上游页面，可在设置中访问。连接过程中禁用重复操作和配置替换。布局可滚动、限制最大内容宽度，以适配窄屏和展开后的折叠屏。

## 自动选线

- 使用订阅末尾 MATCH / FINAL 的目标组，保留订阅中的规则与广告拦截组。
- 优先使用可连通的 Mihomo 自动组，由内核持续维护其选线。
- 没有可用自动组时，按订阅顺序分批测速，从首个有可用节点的批次选择最低正延迟节点；同时最多探测六条线路，单次探测超时八秒，连续失败约 24 秒后停止。
- 跳过 DIRECT、REJECT、循环引用和不支持的 relay；没有可用线路时提示错误，不启动代理。
- 连接时使用规则模式并开启 VPN。线路变化会通过现有动作持久化。

## GitHub 验证与构建

使用上游 CI 指定的鸿蒙 Flutter SDK：`CPF-Flutter/flutter_flutter` 的 `3.44.9+ohos-0.0.1-canary1`，以及仓库的 `.github/flutter_ohos.patch`。普通 Flutter SDK 不支持此项目的 `Platform.isOhos` 与 `TargetPlatform.ohos`。

推送到 `main` 或手动运行 Actions 的 **HarmonyOS Simple** 工作流，会依次安装依赖、静态检查、运行全部 Flutter 测试、编译鸿蒙 Go 内核并构建 HAP / APP。构建产物与 SHA-256 校验文件保存在对应运行的 Artifacts 中，保留 14 天。

工作流沿用上游 CI 的 SDK 和工具链，输出未签名 HAP。安装前需要使用与 `com.follow.clash.simple` 对应、包含目标手机 UDID 的 HarmonyOS 调试证书和 profile 签名；证书、私钥和订阅链接不得提交进公开仓库。真机的 VPN 授权仍需设备所有者完成。

Profile 的 ACL 授权需包含 `ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM`，以支持手机后台任务。简洁版移除了分应用选择及旧媒体访问的权限声明；鸿蒙分应用选择不提供应用列表，订阅导入仍使用系统文件选择器。

## 真机验收

- 导入成功、错误链接、订阅到期、全部节点超时、取消 VPN 授权。
- 手机折叠/展开、较大字号、重复点击、后台锁屏、Wi-Fi/移动网络切换。
- 首次连接与重新启动后，规则流量、DNS、实际外网访问和断开后网络恢复。
- 上游 [鸿蒙 7 全局模式联网反馈 #11](https://github.com/tljk/FlClash-ohos/issues/11) 尚未解决。本分支使用规则模式；这不代表已修复该问题，也不代表所有鸿蒙 7 设备已验证。

「代理已启动」沿用上游运行状态，不作为实际外网可达或 VPN 授权成功的证明；真机验收必须核对真实流量。
