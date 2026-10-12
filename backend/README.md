# Clash Harmony 服务端

使用 Cloudflare Workers 与 D1，以及 Better Auth 的用户名登录、scrypt 密码哈希、签名 Bearer 会话和数据库限流。公开注册关闭；管理员创建账号。手机登录及每次连接时下载 D1 中的统一配置，无需导入订阅。

## 部署

需要 Node.js 22 和 Cloudflare 免费账号。先执行 `npm ci` 和 `npx wrangler login`，再用 `npx wrangler d1 create clash-harmony-auth` 创建数据库并将返回的 ID 写入 `wrangler.jsonc`。其他部署使用自己的数据库 ID 和 Worker 地址。

1. 将 `AUTH_ORIGIN` 设置为实际 Worker 的 HTTPS 地址。
2. `npx wrangler secret put BETTER_AUTH_SECRET`：使用随机的至少 32 字符密钥。
3. `npx wrangler d1 migrations apply clash-harmony-auth --remote`。
4. `npm run types && npm run check && npm run deploy`。
5. `npm run account -- USERNAME --remote` 创建账号。随机密码只写入本机 `~/Library/Application Support/ClashHarmony/accounts/USERNAME.json`，文件权限为 `0600`。重置密码使用 `--reset`，同时撤销旧会话。
6. 将订阅地址保存在仓库外的私密 JSON 文件中，格式为 `{"SUBSCRIPTION_URL":"订阅地址"}`；执行 `npm run config -- /absolute/path/to/private-secrets.json --remote` 同步真实配置。订阅、节点和明文密码不得提交到仓库。

现有订阅使用 IP 与非标准端口，配置由管理员拉取后存入 D1。订阅内容更新后重新执行第 6 步；服务端不会定时刷新上游订阅，手机端会自动取得已同步的新配置。导入接受 Clash/Mihomo YAML，当前 SQL 导入限制约为 90 KB。

应用的默认 API 地址位于 `lib/common/harmony_account.dart`。部署到其他账号时同步修改该地址再用 GitHub Actions 构建应用。

## 免费访问入口

手机默认访问 `https://auth.example.com`，使用 Cloudflare 提供的免费域名；无需购买或续费自有域名。Pages 入口通过 Service Binding 调用 `clash-harmony-api` Worker，账号、认证密钥及配置继续保存在原来的 Worker / D1 中。

在 `backend/gateway` 目录执行 `npx wrangler pages project create clash-harmony-api --production-branch main --force` 首次创建 Pages 项目，然后执行 `npx wrangler pages deploy public --project-name clash-harmony-api --branch main` 部署。当前 Wrangler 首次创建需要 `--force` 保留 Pages 模式；项目创建后，后续部署不再使用该选项。其他账号若无法使用同名项目，修改网关配置及应用地址为实际分配的 pages.dev 地址。

网关使用原生 Service Binding 转发请求及响应，不通过手机无法解析的 workers.dev 公共地址发起网络请求。

## 接口与验证

- `POST /api/auth/sign-in/username`：用户名和密码登录，返回签名会话头 `set-auth-token`。
- `GET /api/auth/get-session`、`POST /api/auth/sign-out`：验证或撤销会话。
- `GET /v1/config`：需要有效签名 Bearer 会话，响应禁止缓存。
- `GET /health`：不含账号或配置信息的健康检查。

会话有效期七天；每 IP 每分钟最多尝试登录五次。密码、会话、配置和订阅 URL 不写入日志。原生客户端仅使用 HTTPS，服务器不开放其他认证接口。`npm run check` 执行 TypeScript 检查、Workers 运行时的认证/限流/配置访问测试和部署预检。GitHub Actions 也运行该检查。

部署只创建 Workers 与 D1 资源，没有付费计划或代理服务器。使用量应在账号的免费额度内；额度以 [Workers](https://developers.cloudflare.com/workers/platform/pricing/) 与 [D1](https://developers.cloudflare.com/d1/platform/pricing/) 官方页面为准。
