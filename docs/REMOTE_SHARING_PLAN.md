# LocalShare 互联网分享方案

## 产品目标

用户选择文件或发送文本，点击「互联网分享 → 连接」，把生成的链接发给访问者。访问者用浏览器打开，Mac 保持在线即可。功能默认关闭，冷启动不会自动发布，关闭窗口仍继续服务，停止分享会撤销链接。

默认服务地址为 `https://share.fairydog.net`。首次明确连接时自动注册独立设备凭据，存入 macOS Keychain；后续连接复用。自托管入口位于「设置 → 网络 → 使用自托管服务器」，使用管理员提供的一次性配对码。凭据按服务器分别保存；「忘记服务器」删除当前服务器凭据。

## 内容、权限与加密

- 支持文件、文件夹、多项选择、纯文本及文件附带文本；文件支持预览、缩略图、单文件下载和 Range。
- 远程文件只读。局域网上传和文本权限继续按原设置运行。
- Mac 发文本无需额外权限。远程收文本有独立开关，默认关闭，只放行 `POST /ls/text`，单条最多 64 KiB，空文本拒绝。
- 更新文本、调整接收权限保持同一分享链接；更换所选文件、停止、断线和 Server 重启使旧远程链接失效。
- 公网注册、配对、访问和连接强制 HTTPS/WSS；仅回环地址允许 HTTP 开发测试。
- 使用可信中继，**中继可以读取分享内容**。当前实现提供链路加密，端到端加密不属于本轮交付。

## 请求链路

```text
浏览器 HTTPS → LocalShare Server → WSS → RemoteAgent → FileServer → 文件或文本
```

Mac 主动建立一个出站 WebSocket，不需要开放 Mac 的公网端口。Server 不缓存文件和文本，也不保存这些内容到磁盘。运行时只保存当前连接、分享和有界的请求队列。

| 端点 | 用途 | 身份 |
| --- | --- | --- |
| `GET /healthz` | 聚合健康与资源计数 | 无 |
| `POST /api/v1/register` | 默认服务的受限设备注册 | 需 `--registration` 开启 |
| `POST /api/v1/enroll` | 自托管配对 | 一次性配对码 |
| `GET /api/v1/agent` | Mac 长连接 | Device Token |
| `GET/HEAD /share/<token>/...` | 文件和文本浏览 | Share Token |
| `POST /share/<token>/ls/text` | 可选文本接收 | Share Token 和接收开关 |

Server 将浏览器请求转换成 `request.begin`。只转发 Accept、Accept-Language、条件缓存、Range、User-Agent 和 Content-Type；不转发 Cookie、Authorization 或访问者提供的内部身份头。本机请求附带当前本机 token 和独立随机 `X-LocalShare-Relay` 标记。FileServer 依据可信标记区分远程权限，继续统一处理路径、鉴权、预览和文本。

`request.begin.client_ip` 由 Server 从连接来源取得；本机 HTTPS 代理部署仅信任回环代理覆盖的 X-Real-IP。Client 将这个字段写入内部来源头，FileServer 只在随机转发标记有效时使用它，缺失或无效 IP 返回 400。访客按来源 IP 近似去重，同一公网出口会合并计数；远程收件箱显示来源 IP，不反查公网设备名。

公开 URL 挂载在 `/share/<token>/` 下。页面和心跳使用相对路径，站内 Location 由 Server 重写；缺少尾斜杠的入口先规范化。

## 协议与生命周期

协议版本为 **2**，Client 与 Server 必须一起升级。不匹配的连接明确失败。

控制消息为 JSON：`hello`、`share.start`、`share.ready`、`share.update`、`share.stop`、`request.begin`、`request.cancel`、`response.begin`、`response.ack`、`response.end` 和 `error`。请求体使用 JSON base64，限于 64 KiB 文本；`text_inbox` 表示远程接收权限。

二进制帧为 4 字节大端 request ID 长度、request ID、最多 64 KiB 数据。Mac 每个请求只发送一个等待确认的数据块；Server 写入并刷新 HTTP 响应后返回 `response.ack`。Client 使用 URLSession AsyncBytes 在后台读取，每块确认后再推进，完整结束后发送 `response.end`。

每个请求队列最多 4 个消息，WebSocket 消息最多 128 KiB。共享读循环不等待慢请求队列；越界请求取消。HTTP 写入与无数据等待使用 60 秒期限，浏览器取消、分享停止、设备离线或撤销会终止对应本机任务。有效大文件持续传输不受总时长限制。

`share_id` 绑定本机分享代次。旧远程请求即使尚在传输，Client 也拒绝读取新的分享。相同代次重复注册保持 token；文本更新通过原会话处理，接收权限通过 `share.update` 更新。连接任务有取消和代次检查，断开、换配置或忘记服务器后，过期注册结果不能写回凭据或发布内容。

临时网络故障按 1 秒开始退避，最多 60 秒；断开清空本机任务。凭据失效后停止重试，用户可以忘记当前服务，再注册或配对。

## 默认资源上限

| 资源 | 默认上限 |
| --- | --- |
| 自动注册设备记录 | 1,000 |
| 注册与配对尝试 | 每 IP 每小时 5 次 |
| WebSocket 建连尝试 | 每 IP 每分钟 60 次 |
| 设备在线连接 | 1 |
| 每设备请求 / 全服务请求 | 8 / 64，无额外等待队列 |
| 每设备 / 全服务传输速率 | 4 / 32 MiB/s，一秒速率桶 |
| 未完成或空闲 HTTP 连接 | 256 |
| 请求体读取 / 请求头等待 | 15 / 10 秒 |
| 转发请求头 / 请求 URI | 各 4 KiB，含转义与文本后符合 128 KiB 消息上限 |
| IP 频率记录 | 每类最多 4,096，窗口过期清理 |

速率、并发、注册频率和设备容量通过 serve 参数调整。速率上限不等于月流量预算；运营方需结合带宽套餐设定并监测。超限返回 429，容量不足返回 503；App 显示注册额度错误，浏览器得到明确 HTTP 结果。

`/healthz` 提供在线设备数、在途请求数、累计获准转发字节数、并发拒绝数及分类失败计数。日志不输出内容、完整分享 URL 或凭据。

## 设备管理与部署

设备和配对码只保存哈希、标识、名称和创建时间；状态目录 0700，文件 0600，并以跨进程锁和原子替换保护更新。运行中的 Server 每秒读取撤销状态；撤销在一秒检查周期内关闭在线设备、删除链接并取消在途请求，后续凭据认证失败。已下载内容无法收回。

`device prune` 删除已撤销设备及已消费配对码，释放注册记录容量；保留有效设备。离线时分享和请求清理，设备凭据保留供重连。自动注册不包含账号封禁机制，运营方仍需在代理层限制滥用来源。

Server 为纯 Go 单个二进制，可直接终止 TLS，也可在本机 HTTPS 代理后使用回环监听及 `--behind-proxy`。代理部署仅信任回环来源的 X-Real-IP，公开地址保持 HTTPS。详见 [部署说明](../website/server/deployment.md) 与 [Server README](../server/README.md)。

## 验证与上线

回归覆盖配对取消、未知长度响应、慢下载隔离、请求取消、在线撤销、注册与资源额度；完整链路覆盖文件、文本、远程接收和局域网权限。Debug、Release、依赖门禁和文档构建需通过。默认服务的 DNS、证书、部署和真实跨网络验收状态记在 [补全清单](REMOTE_SHARING_REVIEW.md)。
