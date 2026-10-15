# 数据层远程更新（不部署示例）

首页日常调整优先使用独立的 [首页 JSON 配置](../homepage/README.md)。`/v1/home` 与线路下载分开，可在登录前加载并独立更新、缓存；下面的 `runtime` 仍兼容已有版本化配置。

首次需要发包安装支持本协议的客户端。之后沿用 HTTPS `/v1/config/version` 轮询、`/v1/config` 条件 GET（ETag/304），每个数据包使用唯一 `version`。账户鉴权和下载仍由 harmony_account.dart 负责，节点更新复用 ProfilesAction.updateProfile，在线更新通过 SetupAction.applyProfile 应用，不下载 Dart/JS/原生可执行代码。

## 配置格式与发布

先复制示例到已被 Git 忽略的私有文件，再编辑其中的真实配置；不要把节点密码或订阅地址写入受跟踪的 `payload.example.json` 或 `config.example.json`：

```sh
cp backend/remote-config/payload.example.json private-config-payload.json
```

编辑 `private-config-payload.json` 后，用 Node 内置模块打包，无需安装依赖。输出文件同样被 Git 忽略：

```sh
node backend/remote-config/package-config.mjs private-config-payload.json 2026-10-14.2 0.8.94+2026101206 > private-config-envelope.json
```

输出与 `config.example.json` 同格式。`schemaVersion=1`；`minClientVersion` 为三段版本，可含 `+build`。`payload` 是 JSON 字符串，`sha256` 校验它的原始 UTF-8 字节，不能在计算哈希后重排或改写字符串。客户端严格验证 HTTPS 证书、禁止重定向、限制下载 1 MiB、校验 SHA-256、版本门槛和字段白名单，再由内核验证配置。SHA-256 用于完整性检测，发布者身份依赖 HTTPS/账户服务；这不是独立数字签名。不得使用自签证书或关闭证书校验。

`worker.mjs` 为 Cloudflare Worker 示例：绑定私有 KV `CONFIGS`，配置 HTTPS `AUTH_ORIGIN`；先调用现有 `/api/auth/get-session` 验证 token，再读取 `user:<username>` 的配置包。必须按真实账户响应调整 `session.user.username`，沿用上游登录/退出路由，禁止将带节点密码的配置放到公开 URL。示例没有部署，没有提供绕过鉴权的静态路由。上线前用正式 OHOS SDK 验证并检查实际账户响应。

## 可免打包的内容

- `profile`：内联节点 `proxies`、节点组 `proxy-groups`、DNS `dns`、分流 `rules`、`hosts`。Harmony 不再以固化 DNS/规则覆盖版本化包。当前允许 ss/ssr/vmess/vless/trojan/hysteria/hysteria2/tuic/wireguard/socks5/http/snell/anytls/direct/reject；组允许 select/url-test/fallback/load-balance。具体协议必须已被当前内核支持。
- `runtime.announcement`：纯文本公告，最多 4096 字符。
- `runtime.texts`：主页/登录页已有的本地化字段名（白名单见 `HarmonyRemoteConfig.textKeys`），以及 ready/running/connecting/disconnecting/error/login/switchNode/retry/logout 简写，最多 256 字符；未配置时回退现有本地化文案。
- `runtime.defaults.showReconnectHint`：连接提示默认展示选项。
- `runtime.features.nodeSwitcher/manualRefresh`：节点切换入口和手动刷新入口开关；自动更新保持开启，不能被远程关闭。
- `runtime.parameters.refreshSeconds/checkSeconds`：刷新和检查周期，整数 60–86400 秒；服务端版本接口的 `min_check_seconds` 仍作为节流提示。

只接受已实现字段。顶层未知字段、DNS/组未知字段、远程脚本、命令、路径、provider、外部资源字段及 RULE-SET 均拒绝；内联节点参数由当前内核再验证。普通旧 YAML 下载继续兼容既有逻辑，启用此协议后应只发布版本化 JSON。

## 缓存、回滚与边界

校验后的节点配置和运行时数据写入同一私有 profile 文件，并使用已有按账户绑定的 SHA-256 缓存元数据验证。重启/离线再次检查最低客户端版本，并从已验证缓存恢复文案、公告和选项，304 不改变内容。在线应用完成后才提交缓存及版本验证器；校验、数据库安装或在线应用失败时恢复旧文件、旧 profile 和在线核心配置，版本未成功提交则下次仍会重试。首次安装失败清理新 profile；退出账号清理运行时内容，且等待正在进行的安装完成，避免账号串用。

远程发布回滚时，将旧 payload 以**新 version**发布，确保客户端能检测到。文件系统或安全存储本身不可写时不能保证持久化回滚，需要恢复存储后重新同步。

已有首页文案以及区块显示、隐藏和排列顺序可由首页 JSON 更新。仍需打包：新增字段及其行为、其他页面的文案接线、新语言支持、新的页面控件、业务逻辑/新功能、Flutter/Dart/原生代码、插件、VPN 权限和通知能力、内核或新协议、内置资源、API 根地址及信任机制。禁止把可执行代码作为配置下发。

示例验证：`node --test backend/remote-config/worker.test.mjs`；客户端验证：`flutter test test/common/harmony_remote_config_test.dart test/providers/harmony_simple_test.dart`。

## 生产实现（backend/src）

正式 Worker 已内置本协议：可选 KV 绑定 `CONFIGS`，使用现有 better-auth 会话鉴权后按 `user:<username>` → `group:<config_group>` → `default` 查找信封；均不存在时回退到原 D1 YAML（旧客户端行为不变）。服务端在下发前再次校验信封字段、`minClientVersion` 格式和 `sha256`，不合法返回 503。`/v1/config` 返回 JSON 信封，`X-Config-Version` 等于信封 `version`，ETag 随 key/version/sha256/minClientVersion 变化，`If-None-Match` 命中返回 304；`/v1/config/version` 额外返回 `minClientVersion` 与 `sha256`。KV 元数据 `{"updatedAt": <unix秒>}` 可选，用于 `updated_at`/`Last-Modified`。注意：一旦写入 `default`，所有账户（含不支持 JSON 的旧客户端）都会收到 JSON。
