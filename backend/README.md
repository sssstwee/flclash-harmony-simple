# Xiaomao AI Proxy

Xiaomao AI Proxy（小猫AI代理）is a proxy client for HarmonyOS.

Download the HAP from [Releases](https://github.com/sssstwee/xiaomao-ai-proxy/releases). If unsigned, sign it with a HarmonyOS debug certificate and profile containing your phone’s UDID, then install it using DevEco Studio with developer mode and USB debugging enabled on your HarmonyOS phone.

## 同步 VPS 订阅（D1）

在 `backend` 目录执行 `npm ci`，通过环境变量 `SUBSCRIPTION_URL` 提供 HTTPS 订阅地址，不要提交地址或凭据。先按现有流程应用本地 D1 migrations，再执行：

```bash
npm run sync-subscription -- --dry-run
npm run sync-subscription
npm run sync-subscription -- --scope user --key USER_ID --dry-run
```

默认使用本地 D1、`default` scope；可用 `--scope group --key GROUP_ID` 选择组配置，`--config PATH` 选择 Wrangler 配置。远程 D1 需显式传 `--remote` 并使用私有配置。dry-run 只下载、校验、读取旧配置并打印旧/新版本哈希，不写入或备份。写入前将旧记录（不存在时为 null）保存到临时目录中的私有 `config.json`，打印备份路径和新版本；备份含敏感配置，请妥善保管。要求 `proxy-groups`、`proxies` 非空，禁止 `rule-providers` 和 `RULE-SET`。仅支持 D1。

## Worker 定时同步（D1）

Cron 为 `*/5 * * * *`（每 5 分钟，UTC）。地址仅从 Worker secret `SUBSCRIPTION_URL` 读取；部署用私有配置须保留 `triggers.crons`。上线步骤（本次修改不执行生产操作）：

```bash
npx wrangler secret put SUBSCRIPTION_URL --config wrangler.local.jsonc
npm run migrate
npm run deploy
```

下载限制 30 秒、90,000 字节，不跟随重定向；要求 HTTPS、非空 `proxies` / `proxy-groups` / `rules`，禁止 `rule-providers` / `RULE-SET`，规则目标必须存在。失败保留旧配置，日志不含地址或内容。仅内容变化时更新 D1 `default` / 空 key，版本沿用 scope、key、原始内容的 SHA-256 前 16 位。迁移 `0004_config_backup.sql` 原子保存上一版到 `proxy_config_backup`（含敏感配置），相同内容不覆盖备份。回滚 SQL（同时备份被替换版本）：

```sql
UPDATE proxy_config
SET content = (SELECT content FROM proxy_config_backup WHERE scope = 'default' AND scope_key = ''),
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE scope = 'default' AND scope_key = ''
  AND EXISTS (SELECT 1 FROM proxy_config_backup WHERE scope = 'default' AND scope_key = '');
```

已有 KV 配置仍按现有优先级先读取 KV；Cron 只更新 D1。
