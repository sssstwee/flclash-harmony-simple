# Clash Harmony 服务端

使用 Cloudflare Workers 与 D1，以及 Better Auth 的用户名登录、scrypt 密码哈希、签名 Bearer 会话和数据库限流。公开注册关闭；管理员创建账号。手机登录及连接时下载 D1 中的配置（默认 / 按用户 / 按组），无需导入订阅。

## 部署

需要 Node.js 22 和 Cloudflare 免费账号。先执行 `npm ci` 和 `npx wrangler login`，再用 `npx wrangler d1 create clash-harmony-auth` 创建数据库。

1. 复制 `wrangler.local.jsonc.example` 为本地 `wrangler.local.jsonc`（已 gitignore），填入 **D1 database_id**、实际 **AUTH_ORIGIN**；仓库内 `wrangler.jsonc` 仅保留占位 ID，默认 `workers_dev: false`。
2. `npx wrangler secret put BETTER_AUTH_SECRET`：使用随机的至少 32 字符密钥。
3. `npx wrangler d1 migrations apply clash-harmony-auth --remote`。
4. `npm run types && npm run check && npm run deploy`。
5. `npm run account -- USERNAME --remote --print-password` 创建账号。默认只在 `~/.clash-harmony/accounts/` 写入**不含密码**的元数据；使用 `--out PATH` 自定义输出路径。重置密码 `--reset` 会撤销旧会话。
6. 将订阅地址保存在仓库外的私密 JSON 中：`{"SUBSCRIPTION_URL":"..."}`。`npm run config -- /path/secrets.json --remote` 写入 **default** 配置；`--scope=user --scope-key=<userId>` 或 `--scope=group --scope-key=<name>` 写入覆盖。用户表 `config_group` 可指向组配置。订阅与密码不得提交到仓库。

现有订阅使用 IP 与非标准端口，配置由管理员拉取后存入 D1。订阅内容更新后重新执行第 6 步；服务端不会定时刷新上游订阅，手机端会自动取得已同步的新配置。导入接受 Clash/Mihomo YAML，当前 SQL 导入限制约为 90 KB。

客户端 API 地址通过 **`CLASH_HARMONY_API_URL`** 注入（见仓库根目录 `env.json.example` → 本地 `env.json`，或 GitHub Actions 变量 `CLASH_HARMONY_API_URL`）。仓库内默认仅为 `https://auth.example.com` 占位，不含真实域名。

## 免费访问入口（Pages 网关）

推荐使用 Cloudflare **Pages** 作为公网 HTTPS 入口（`*.pages.dev` 或自定义域名），通过 **Service Binding** 转发到同名 Worker；账号、密钥与配置仍在 Worker / D1。在 `backend/gateway` 创建 Pages 项目并 `wrangler pages deploy public`；项目名与 Worker 服务名按你的账号调整。网关仅转发白名单路径（见 `gateway/public/_worker.js`），不在仓库中保存具体域名。

## 密钥与变量（仅名称）

| 名称 | 类型 | 说明 |
|------|------|------|
| `BETTER_AUTH_SECRET` | Cloudflare Secret | Better Auth 签名密钥 |
| `AUTH_ORIGIN` | Worker 变量 / `wrangler.local.jsonc` | 对外 HTTPS 源，与客户端一致 |
| D1 `database_id` | 绑定 | 仅写在 gitignore 的 `wrangler.local.jsonc` |
| `SUBSCRIPTION_URL` | 运维 JSON（gitignore） | `npm run config` 拉取订阅；模板 `secrets.example.json` |
| `CLASH_HARMONY_API_URL` | App `env.json` / GitHub Variable | 打包进 HAP 的 API 根地址 |

## 接口与验证

- `POST /api/auth/sign-in/username`：用户名和密码登录，返回签名会话头 `set-auth-token`。
- `GET /api/auth/get-session`、`POST /api/auth/sign-out`：验证或撤销会话。
- `GET /v1/config`：需要有效签名 Bearer 会话；支持 `If-Modified-Since`（304）；每用户每分钟 30 次；拉取写入审计表 `config_fetch_audit`。
- `GET /health`：不含账号或配置信息的健康检查。

会话有效期七天；每 IP 每分钟最多尝试登录五次。密码、会话、配置和订阅 URL 不写入日志。原生客户端仅使用 HTTPS，服务器不开放其他认证接口。`npm run check` 执行 TypeScript 检查、Workers 运行时的认证/限流/配置访问测试和部署预检。GitHub Actions 也运行该检查。

部署只创建 Workers 与 D1 资源，没有付费计划或代理服务器。使用量应在账号的免费额度内；额度以 [Workers](https://developers.cloudflare.com/workers/platform/pricing/) 与 [D1](https://developers.cloudflare.com/d1/platform/pricing/) 官方页面为准。
