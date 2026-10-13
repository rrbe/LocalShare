---
title: 已接入 EdgeOne 等 CDN
description: 中继子域名可直连服务器，也可经过 CDN；分别说明回源、WebSocket、缓存与验证。
---

# 已接入 EdgeOne 等 CDN

主站使用 CDN 时，中继有两种接入方式。只为中继域名配置规则即可。

| 方式 | 请求路径 | 需要配置 |
| --- | --- | --- |
| 中继子域名直连 | 浏览器 → Nginx → Server | A 记录、Nginx、证书续期 |
| 中继也经过 CDN | 浏览器 → CDN → Nginx → Server | 源站部署，加上 CDN 的 HTTPS 回源、WebSocket、缓存和客户端 IP |

## 方式一：中继子域名直连

为 `share.example.com` 创建指向服务器公网 IP 的 A 记录，关闭该记录的 CDN 代理 / 加速，按 [Nginx 方案](./deploy-nginx) 部署。

主站可以继续使用 CDN。LocalShare 中填写 `https://share.example.com`，无需填写主站地址。

## 方式二：中继也经过 CDN

以下以 EdgeOne 为例。其他 CDN 需具备相同的 WebSocket、HTTPS 回源和不缓存能力。

### 1. 先部署源站

按 [Nginx 方案](./deploy-nginx) 安装 Server 和 Nginx。`--public-url` 始终填写用户访问的地址，例如 `https://share.example.com`。

Nginx 的 `server_name` 与证书覆盖 CDN 的回源 Host。可以使用同一个 `share.example.com`；若它已解析到 CDN，申请源站证书时使用现有 ACME 的 DNS 验证，或让 CDN 正确透传 HTTP 验证请求。

CDN 的边缘证书和源站证书是两处配置：边缘证书用于访问者连接 CDN，源站证书用于 CDN 连接 Nginx。两者都需保持有效并自动续期。

### 2. 设置 CDN 回源与转发

在 EdgeOne 中添加中继加速域名，为这个 Host 单独设置规则：

| 项目 | 设置 |
| --- | --- |
| DNS | 按 EdgeOne 指引将中继域名指向其 CNAME |
| 边缘 HTTPS | 为中继域名启用有效证书，HTTP 跳转 HTTPS |
| 源站地址 | 服务器公网 IP；不要填解析回 CDN 的中继域名 |
| 回源协议与端口 | HTTPS，443 |
| 回源 Host | 与 Nginx 的 `server_name` 和源站证书一致 |
| WebSocket | 开启，空闲超时可设为 120 秒 |
| 节点缓存 | 整个中继 Host 设为「不缓存」，包含所有路径和状态码 |
| 离线缓存 | 关闭，停止分享后不再提供缓存副本 |
| 请求转发 | 保留路径、查询参数、请求方法、Authorization 与 Range 头 |
| 交互验证 | App 的 API 和 WebSocket 路径不启用需要浏览器操作的验证 |

EdgeOne 的 [WebSocket 默认关闭](https://edgeone.ai/zh/document/46971)，空闲超时指没有数据收发的时间，最大可设 300 秒；不是每隔 300 秒强制断开。LocalShare 会发送心跳。

按照 [节点缓存 TTL](https://edgeone.ai/document/46175) 为整个中继 Host 创建不缓存规则，并检查没有其他缓存规则覆盖它。如果此前缓存过分享内容，清除该 Host 的已有缓存。媒体文件同样需要实时回源。

EdgeOne 的 [回源 SNI 默认与回源 Host 一致](https://edgeone.ai/document/67728)，因此回源 Host、Nginx 站点与证书需要对应。启用源站证书校验时，使用能通过校验的证书，参见 [源站证书校验](https://edgeone.ai/document/74344)。

### 3. 把访问者 IP 传给 Server

Server 依据访问者 IP 统计和限制配对尝试。经过 CDN 时，Nginx 默认看到的是 CDN 节点 IP，需要恢复客户端 IP。

EdgeOne 使用 [`EO-Connecting-IP`](https://edgeone.ai/zh/document/54211) 传递客户端 IP。在中继的 Nginx HTTPS `server` 中加入以下配置，**先将占位符替换为 EdgeOne 当前公布的回源网段**，每个网段一行：

```nginx
set_real_ip_from <EdgeOne 回源网段>;
real_ip_header EO-Connecting-IP;
```

保留 Nginx 方案中的 `proxy_set_header X-Real-IP $remote_addr;`。`set_real_ip_from` 只填 CDN 的回源网段，避免直连请求伪造这个头。网段从 EdgeOne 的「源站防护 / 回源 IP 网段」获取；其他 CDN 使用其对应的客户端 IP 头和网段。

Nginx 需包含 [realip 模块](https://nginx.org/en/docs/http/ngx_http_realip_module.html)；Ubuntu / Debian 的常用 Nginx 包已包含。保存后执行：

```bash
sudo nginx -t
sudo systemctl reload nginx
```

### 4. 验证真实分享

```bash
curl --fail --max-time 10 https://share.example.com/healthz
```

健康检查返回 200 后，[选择设备注册方式](./deployment#_3-选择设备注册方式)并[连接 Client](./connect-client)，用另一网络的浏览器完成以下验证：

1. 打开分享链接，查看目录并下载一个文件。
2. 保持连接几分钟，再查看文本或下载文件，确认 WebSocket 持续可用。
3. 在 App 中断开，重新请求旧分享链接，确认无法继续读取内容。

`/healthz` 通过只说明 HTTP 入口可用；文件与文本的实际访问才能验证 WebSocket、缓存和回源配置。
