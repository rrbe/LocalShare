# LocalShare Remote Sharing Plan

> 目标：让浏览器通过一个自托管的 LocalShare Server 访问 Mac 上正在分享的文件。Server 是单个二进制，不依赖 SSH、frp、Nginx、Tailscale 或其他运行时组件。

## 1. 方案

```text
浏览器
  │ GET /share/<share-token>/...
  ▼
LocalShare Server :8080
  ├─ Control Plane：Enrollment Key、Device Token、设备连接、分享注册
  ├─ Data Relay：把浏览器 HTTP 请求转成 WebSocket 消息
  └─ HTTP endpoint：认证分享 token、流式返回文件
       ▲ 一个长连接 WebSocket
       │
LocalShare Client（Mac）
  └─ RemoteAgent → 本机 FileServer → 用户选择的文件
```

Server 不保存文件。文件内容始终由 Client 从本机 `FileServer` 读取，再经过 Server 流式转发给浏览器。

V1 的边界：

- 一个 Server 可管理多个设备，但每台设备最多一个当前分享；
- 一个 Client 只连接一个 Server；
- 只转发 `GET` / `HEAD`，支持 `Range`，支持取消请求；
- 远程模式强制只读，不开放上传和 Text Transfer；
- 不做 Server 端文件缓存、用户账号、浏览器账号登录或多租户计费。

## 2. 用户配置体验

### Server 管理员

下载并运行一个二进制：

```bash
localshare-server serve \
  --listen :8080 \
  --public-url https://ls.example.com \
  --tls-cert /etc/localshare/server.crt \
  --tls-key /etc/localshare/server.key \
  --state-dir /var/lib/localshare
```

首次配对时生成一次性 Enrollment Key：

```bash
localshare-server key create --name macbook
# 输出 key 只显示一次
```

管理命令：

```bash
localshare-server key list
localshare-server key revoke <key-id>
localshare-server device list
localshare-server device revoke <device-id>
```

`state.json` 只保存 Enrollment Key 和 Device Token 的 SHA-256，不保存可直接使用的明文密钥；目录和文件权限分别为 `0700` / `0600`。

### Client 用户

第一次在 LocalShare 设置中填写：

1. Server address，例如 `https://ls.example.com`；
2. Enrollment Key。

点击保存并连接后，Client 调用 `/api/v1/enroll` 换取 Device Token，并把 Device Token 保存到 macOS Keychain。Enrollment Key 不落盘。

之后设置页只需要保留 Server address；分享页提供：

- `Connect`：建立 WebSocket 长连接并注册当前分享；
- `Disconnect`：断开当前连接，但保留已配对的 Device Token；
- `Forget Device`：删除 Keychain 中的 Device Token，下一次需要新的 Enrollment Key。

应用重启后不自动恢复远程分享；用户在当前分享页点击 `Connect` 即可重新连接。连接断开时，Client 自动重试，退避上限 60 秒。

## 3. 连接与请求流程

```text
管理员生成 Enrollment Key
  → Client 输入 Server address + Enrollment Key
  → POST /api/v1/enroll
  → Server 一次性消费 Enrollment Key，返回 Device ID + Device Token
  → Client 将 Device Token 写入 Keychain
  → WebSocket /api/v1/agent（Authorization: Bearer Device Token）
  → Client 发送 share.start
  → Server 返回 /share/<share-token>
  → 浏览器访问 /share/<share-token>/path
  → Server 发送 request.begin
  → Client 请求本机 FileServer，并发送 response.begin / 二进制数据 / response.end
  → Server 原样流式返回浏览器
```

WebSocket 文本消息使用 JSON；文件数据使用带 request ID 的二进制帧：

```text
4 bytes big-endian request-id length
request-id bytes
file bytes
```

Server 只转发必要的请求头：`Accept`、`Accept-Language`、`If-Modified-Since`、`If-None-Match`、`Range`、`User-Agent`。响应会移除 `Set-Cookie`、`Connection` 和 `Transfer-Encoding`，并重写站内 `Location` 到 `/share/<share-token>`。

## 4. Server 实现

Server 使用 Go 标准库 HTTP；WebSocket 只需要一个小型、纯 Go 的协议依赖，最终编译进单个静态二进制。Control Plane 和 Data Relay 共用同一个 HTTP 端口。

HTTP 路由：

| 路径 | 作用 | 认证 |
|---|---|---|
| `GET /healthz` | 健康检查 | 无 |
| `POST /api/v1/enroll` | Enrollment Key 换 Device Token | Enrollment Key |
| `GET /api/v1/agent` | Client WebSocket 长连接 | Device Token |
| `GET/HEAD /share/<token>/...` | 浏览器文件请求 | Share Token |

Server 内存中保存当前连接和分享注册；重启后设备凭据仍从 `state.json` 恢复，但 Client 需要重新连接，旧的 Share Token 失效。

请求必须有超时和取消传播。浏览器断开时，Server 发送 `request.cancel`，Client 取消对应的本机 `URLSessionDataTask`，避免大文件继续占用带宽。

## 5. Client 实现

`RemoteAgent.swift` 只负责远程控制和流转发，不复制 FileServer 的鉴权、路径解析或预览逻辑：

- 使用系统 `URLSessionWebSocketTask` 建立出站连接；
- Device Token 仅从 Keychain 读取；
- `share.start` 时把本机 FileServer 地址和当前 token 作为内部转发目标；
- Server 下发请求后，只允许白名单请求头进入本机 FileServer；
- 从本机响应按块发送数据，不把完整文件读入内存；
- 断线清理所有本地请求，重新连接后重新注册当前分享；
- 分享内容变化时更新本机目标并重新注册，Server 生成新的 Share Token。

AppState 继续作为唯一状态源：远程状态、公开 URL 和本地只读策略都由 AppState 管理。RemoteAgent 不直接修改 SwiftUI 状态。

## 6. 安全边界

- Enrollment Key 一次性使用；
- Device Token 和 Share Token 使用高熵随机值，Server 只保存 Device Token 哈希；
- 撤销 Device 后，新建 WebSocket 会被拒绝；
- Client 远程连接期间 FileServer 只接受 `GET` / `HEAD`，并禁用上传和接收文本；
- Server 不信任浏览器传来的代理身份头，也不把设备 token 转发给浏览器；
- Server 不记录文件内容；默认日志不打印 Enrollment Key、Device Token、Share Token；
- Share Token 随分享注册变化或停止立即失效；
- WebSocket 是 Client 主动发起的出站长连接，Server 不需要访问 Mac 的监听端口。

## 7. 交付阶段

1. 在 `server/` 新增 Go module、状态存储、CLI、Enrollment、设备认证和健康检查。
2. 实现同端口 WebSocket Agent 与浏览器 Data Relay，先支持只读 GET/HEAD 和流式数据。
3. 在 Client 增加 Keychain 配对、Connect/Disconnect、断线重连和远程只读策略。
4. 增加 Range、取消、旧 token 失效、设备撤销和连接状态测试。
5. 更新 CI、README、架构文档，并做本地 Server + headless Client 的端到端冒烟测试。

## 8. 明确放弃的方案

### SSH tunnel / frp / Nginx

它们可以转发 TCP，但要求用户额外准备 SSH 信任、端口、反向转发、代理配置和多个服务生命周期。对 LocalShare 来说，这些配置不提供用户价值，且文件请求协议、设备配对和分享注册仍然需要 Client 自己实现，因此改为一个自包含 Server。

### Tailscale / Cloudflare Tunnel

它们适合作为未来的底层网络或部署参考，但会引入外部控制面、账号/设备身份或特定供应商依赖。当前版本先把控制面和数据中继边界做清楚，后续如需要可替换 Client 的传输层，不改变浏览器 Data Relay 和 FileServer 协议。

### WebRTC / P2P

能减少中继流量，但需要 NAT 穿透、ICE、浏览器端连接协商和新的数据协议，无法复用当前 HTTP 文件服务。只有在中继成本成为真实问题时再考虑。

## 9. 暂不实现

- 多 Client 同时共享同一 Share Token；
- Server 端文件缓存和断点持久化；
- 上传、删除、编辑和远程 Text Transfer；
- Server Web 管理后台；
- 自动 DNS、证书和云厂商部署；
- 对不可信 Server 的端到端加密。
