# 首页 JSON 配置

首页使用独立的 `home.json`，与节点、DNS 和分流订阅分开维护。客户端从现有 VPS 入口的 `/v1/home` 获取显示配置；接口只返回公开显示数据，不读取会话、账号或代理配置。

首次启用需要安装支持此接口的客户端（`0.8.94+2026101602` 起）。之后调整支持的文案、区块显示和顺序，只需发布 JSON，不需要重打包、重装客户端或重新部署 Worker。

## 修改与发布

编辑本目录的 [home.json](home.json)，然后在 `backend/` 中执行：

```sh
npm run home:publish -- homepage/home.json --remote
```

命令先使用 `@cfworker/json-schema` 校验 [schema.json](schema.json)，再写入现有 `CONFIGS` KV 的 `ui:home`。它不会修改节点、分流、账号或登录信息。Cloudflare 登录和绑定沿用 `wrangler.local.jsonc`；省略 `--remote` 只写本地测试存储。

客户端启动、回到前台时会同步；首页在前台时每分钟检查一次。现有的配置刷新按钮仍会刷新线路，同时检查首页 JSON。ETag 自动随配置内容变化，未修改时返回 304，不需要手动改版本号。KV 的传播和缓存可能使新配置稍后生效。

## 可以调整的内容

- `texts`：首页标题、连接状态、按钮、栏目标签、错误提示和登录页文字。字段名见 `schema.json` 的 `texts.propertyNames.enum`。不填写或删除某个字段时，回退到原有语言文案；文件中的运营文案会覆盖本地语言默认值。
- `announcement`：纯文本公告；空字符串不展示。
- `home.sections`：区块数组，顺序就是展示顺序；删除某项就隐藏对应区块。省略整个字段则使用当前默认界面。
- `home.details`：连接说明里的信息行，支持隐藏和排序；省略时使用当前默认行。

`home.sections` 支持：

| 配置值 | 显示内容 |
| --- | --- |
| `announcement` | 公告 |
| `connection` | 盾牌连接按钮及状态，必须保留，可调整位置 |
| `config` | 配置检查状态和刷新按钮 |
| `issue` | 连接异常说明及重试入口 |
| `node` | 当前节点及延迟 |
| `insights` | 连接说明 |
| `traffic` | 上传和下载流量 |
| `account` | 账号和退出登录 |

相邻的 `node` 和 `insights` 保留当前共用卡片的样式；分开排列时各自显示。`home.details` 支持 `route`（线路）、`ai`（AI）、`network`（网络）、`health`（健康检查）；信息尚不可用时仍按原有逻辑隐藏。

例如将流量放到连接按钮下，并隐藏当前节点和连接说明：

```json
{
  "schemaVersion": 1,
  "texts": {
    "homeTitle": "CC保镖",
    "simpleReady": "轻点盾牌，开始保护",
    "harmonySessionTraffic": "本次保护流量"
  },
  "home": {
    "sections": ["connection", "traffic", "config", "account"]
  }
}
```

动态文案可保留占位符：`harmonyConfigFreshUpToDate` 支持 `{version}`、`{time}`；`harmonyConfigFreshCheckFailed` 支持 `{reason}`；`harmonyHealthCheckOk` 和 `harmonyHealthCheckFailed` 支持 `{time}`。

整行格式也可以调整：`harmonyLatencyValue` 支持 `{label}`、`{delay}`；`harmonyAccountValue` 支持 `{label}`、`{username}`；`harmonySpeedValue` 支持 `{value}`。例如将延迟设为 `"{label}：{delay} 毫秒"`，账号设为 `"当前账号：{username}"`。刷新成功、失败和频繁操作提示分别使用 `harmonyConfigRefreshSuccess`、`harmonyConfigRefreshFailed`、`harmonyConfigRefreshDebounced`。

```json
{
  "schemaVersion": 1,
  "texts": {
    "harmonyConfigFreshUpToDate": "配置 {version} · {time} 已检查",
    "harmonyHealthCheckOk": "连接正常（{time}）"
  }
}
```

## 缓存与回退

下载失败或新配置无效时，保留最近一次有效显示；没有有效缓存时使用内置默认界面。首页请求独立运行，不阻塞登录、下载线路或启动 VPN；自动同步首页只更新显示，不触发线路切换或重启 VPN。公开显示缓存可在退出登录后继续用于登录页，不包含账号数据。

回滚时恢复 Git 中上一版 `home.json` 并重新执行发布命令即可。仍需客户端更新的范围是新增区块或功能、连接行为、字体和颜色方案、内置图标等；现有文字、区块开关和顺序通过本文件更新。
