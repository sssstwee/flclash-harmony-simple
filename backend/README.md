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
