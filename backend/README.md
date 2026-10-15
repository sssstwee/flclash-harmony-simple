# Xiaomao AI Proxy

Xiaomao AI Proxy（小猫AI代理）is a proxy client for HarmonyOS.

Download the HAP from [Releases](https://github.com/sssstwee/xiaomao-ai-proxy/releases). If unsigned, sign it with a HarmonyOS debug certificate and profile containing your phone’s UDID, then install it using DevEco Studio with developer mode and USB debugging enabled on your HarmonyOS phone.

## VPS 推送订阅（D1）

分流策略统一在 `routing-policy.json` 维护；修改后运行 `node tool/generate_routing_policy.mjs`（仓库根目录），生成客户端清单。D1 订阅导入、VPS 推送和下载响应都应用同一策略，HarmonyOS 客户端也会检查 YAML 和 JSON 配置，保留额外的服务端代理域名规则。

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
