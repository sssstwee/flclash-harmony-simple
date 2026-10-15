# Xiaomao AI Proxy

Xiaomao AI Proxy（小猫AI代理）is a proxy client for HarmonyOS.

Download the HAP from [Releases](https://github.com/sssstwee/xiaomao-ai-proxy/releases). If unsigned, sign it with a HarmonyOS debug certificate and profile containing your phone’s UDID, then install it using DevEco Studio with developer mode and USB debugging enabled on your HarmonyOS phone.

## VPS 推送订阅（D1）

VPS 上的完整 YAML 订阅文件是分流配置的唯一来源。电脑直接订阅该文件，文件监听任务将同一份内容推送到 Worker，手机登录后从 Worker 下载。导入、推送、存储和下载均保留原始内容；Worker 只校验配置和访问权限，不改写规则、代理组、节点顺序或 DNS，避免两端产生不同策略。`routing-policy.json` 和 `src/routing_policy.mjs` 仅保留为离线迁移工具，不参与自动下发链路。

HarmonyOS 客户端校验并原样执行下发的规则、代理组和 DNS，不生成分流规则、排序节点或追加本地 DNS。各端仅覆盖 VPN、监听端口等必要的平台运行参数；连接健康检查不改动代理组选择。

后续调整分流只修改 VPS 订阅文件，先验证代理组和回退出口，再由监听任务同步 Worker 并刷新两端。不要分别维护 Worker 策略，也不为域名、节点顺序或 DNS 变更发布客户端。仅协议支持、配置解析、必要校验或客户端功能缺陷需要修改客户端。源 YAML 中的 `harmony-runtime: {}` 继续兼容旧版；新版客户端不会把它视为改写策略的开关。

客户端清理鸿蒙旧版保存的节点选择，不再通过缓存强制覆盖云端代理组。连接健康检查在 VPN 启动后运行并遵循云端 URL 和预期状态码，失败只更新状态，不阻止启动或停止内核；故障切换及恢复由云端代理组执行。配置安装等待应用完成内核初始化，避免重复预热造成竞争；在服务端最小检查间隔内，首次连接复用已在线校验且本地哈希一致的配置，缺失、损坏或过期则重新同步。

国内和内网（含 `100.64.0.0/10`）直连；国内 AI 直连；已知海外 AI、Google、YouTube、GitHub 和开发站点先按域名分流，再判断国内 IP。海外 AI 使用独立 `fallback` 组，依次尝试清单内经过核验的原生节点，然后尝试 WARP。该组只允许已知协议的叶子节点，拒绝链式代理；没有合格节点时使用 `REJECT`，没有本地 `DIRECT` 兜底。AI 健康检查要求 OpenAI `/v1/models` 返回 401（无需 API 密钥），不以普通测速成功作为可用依据。更新节点拓扑时必须重新核验实际出口并维护清单。

Worker 已取消 Cron 和 URL 拉取，无需 `SUBSCRIPTION_URL`。私有 Wrangler 配置也应设置 `"triggers": { "crons": [] }`。先应用 migrations（含 0004 原子备份、0005 限流表），再设置 Worker secret `SUBSCRIPTION_PUSH_TOKEN`（建议随机 base64url 字符串）；此处不执行部署。

接口：`POST /v1/admin/subscription`，`Authorization: Bearer <token>`，请求体为原始 YAML。默认 `scope=default&key=`；可选 `?scope=user&key=USER_ID` 或 `?scope=group&key=GROUP_ID`。key 最长 128 字符、不能含控制字符，非 default 必须非空。返回 `{changed, oldVersion, newVersion}`，首次 oldVersion 为 null。鉴权失败 401、参数/内容错误 400、超 90,000 字节 413、每分钟全局最多 10 次（鉴权后计数）超限 429。

沿用非空 proxies / proxy-groups / rules 校验，禁止 rule-providers / RULE-SET，规则目标须存在。仅原始内容变化时写入，事务内保存上一版到 `proxy_config_backup`；版本沿用 scope、key、内容的 SHA-256 前 16 位。已有 KV 配置仍优先于 D1。

VPS 推送地址应使用 Worker 的直接域名或自定义路由，私有配置需保留 `"workers_dev": true`（或等价的公开路由）。Pages 网关只转发客户端接口，不转发 `/v1/admin/subscription`。部署时应保留既有 `SUBSCRIPTION_PUSH_TOKEN`，并验证推送入口无凭据时返回 401。

VPS 安装脚本到 `/usr/local/bin/vps-push-subscription`，在 `/etc/subscription-push.env`（chmod 600）配置：
```sh
SUBSCRIPTION_FILE=/var/lib/subscription/config.yaml
SUBSCRIPTION_PUSH_URL=https://auth.example.com/v1/admin/subscription
SUBSCRIPTION_PUSH_TOKEN_FILE=/etc/subscription-push.token
```
token 文件仅包含密钥，由服务用户持有且权限 600；也可直接设置环境变量 `SUBSCRIPTION_PUSH_TOKEN`。手动加载环境后执行脚本即可；脚本通过 stdin 传鉴权头，带超时和重试，不打印密钥。

systemd 示例，分别保存到 `/etc/systemd/system/`：

```ini
# subscription-push.service
[Unit]
Description=推送订阅
[Service]
Type=oneshot
EnvironmentFile=/etc/subscription-push.env
ExecStart=/usr/local/bin/vps-push-subscription

# subscription-push.path
[Unit]
Description=订阅文件变更时推送
[Path]
PathChanged=/var/lib/subscription/config.yaml
Unit=subscription-push.service
[Install]
WantedBy=multi-user.target

# subscription-push.timer
[Unit]
Description=每小时补偿推送
[Timer]
OnCalendar=hourly
Persistent=true
Unit=subscription-push.service
[Install]
WantedBy=timers.target
```

执行 `systemctl daemon-reload && systemctl enable --now subscription-push.path subscription-push.timer`。更新程序应原子替换 YAML 文件。备份包含敏感配置，勿公开。

## 登录与客户端更新

登录响应通过 Better Auth 的官方 after hook 附带新建会话的 `session.expiresAt`，客户端继续使用 `set-auth-token` 的签名令牌，可省去紧接登录的一次 `get-session` 往返。旧服务端缺少该字段时，新客户端仍查询会话；恢复已有登录仍在线校验会话。过期或无效的响应不保存凭据。

鸿蒙客户端在启动、返回前台和 VPN 连通后检查 GitHub Releases。同版本号下增加构建号也会提示；启动查询尚未完成时，VPN 连通后的补查会等待后重试。同一版本在本次运行内只提示一次，取消不会关闭后续版本提醒。1502 及更早版本需要手动安装一次 1503 或更新版本以启用提示。
