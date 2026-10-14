# Xiaomao AI Proxy

Xiaomao AI Proxy（小猫AI代理）is a proxy client for HarmonyOS.

Download the HAP from [Releases](https://github.com/sssstwee/xiaomao-ai-proxy/releases). If unsigned, sign it with a HarmonyOS debug certificate and profile containing your phone’s UDID, then install it using DevEco Studio with developer mode and USB debugging enabled on your HarmonyOS phone.

## VPS 推送订阅（D1）

Worker 已取消 Cron 和 URL 拉取，无需 `SUBSCRIPTION_URL`。私有 Wrangler 配置也应设置 `"triggers": { "crons": [] }`。先应用 migrations（含 0004 原子备份、0005 限流表），再设置 Worker secret `SUBSCRIPTION_PUSH_TOKEN`（建议随机 base64url 字符串）；此处不执行部署。

接口：`POST /v1/admin/subscription`，`Authorization: Bearer <token>`，请求体为原始 YAML。默认 `scope=default&key=`；可选 `?scope=user&key=USER_ID` 或 `?scope=group&key=GROUP_ID`。key 最长 128 字符、不能含控制字符，非 default 必须非空。返回 `{changed, oldVersion, newVersion}`，首次 oldVersion 为 null。鉴权失败 401、参数/内容错误 400、超 90,000 字节 413、每分钟全局最多 10 次（鉴权后计数）超限 429。

沿用非空 proxies / proxy-groups / rules 校验，禁止 rule-providers / RULE-SET，规则目标须存在。仅原始内容变化时写入，事务内保存上一版到 `proxy_config_backup`；版本沿用 scope、key、内容的 SHA-256 前 16 位。已有 KV 配置仍优先于 D1。

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
