---
title: 安装与部署
description: 安装单文件中继，使用 HTTPS/WSS，配置设备与资源权限。
---

# 安装与部署

LocalShare Server 是纯 Go 单文件程序，要求 Go 1.23+。公网必须使用 HTTPS；可由 Server 直接终止 TLS，也可使用本机反向代理。默认自动注册关闭，自托管由管理员发放配对码。

## 获取程序

从 [GitHub Releases](https://github.com/rrbe/LocalShare/releases) 下载匹配 Linux amd64 或 arm64 的二进制和校验文件，按 SHA-256 校验后安装。首次安装：

```bash
sha256sum -c LocalShare-Server-<version>-checksums.txt
sudo install -m 0755 LocalShare-Server-<version>-linux-amd64 /usr/local/bin/localshare-server
sudo useradd --system --home /var/lib/localshare --shell /usr/sbin/nologin localshare
sudo install -d -o localshare -g localshare -m 0700 /var/lib/localshare
```

也可从源码构建：

```bash
cd server
go test -race ./...
go vet ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags '-s -w' -o localshare-server .
```

升级前备份二进制和服务配置，保留 `/var/lib/localshare/state.json`。不要重新生成状态文件。Client 与 Server 协议均为 v2，需一起升级。

## 直接终止 TLS

准备覆盖 `share.example.com` 的有效证书，并让 localshare 用户能读取证书与私钥；私钥仅授权该服务用户读取。创建 `/etc/systemd/system/localshare-server.service`：

```ini
[Unit]
Description=LocalShare Server
After=network-online.target
Wants=network-online.target

[Service]
User=localshare
Group=localshare
ExecStart=/usr/local/bin/localshare-server serve --listen :18443 --public-url https://share.example.com:18443 --tls-cert /etc/localshare/server.crt --tls-key /etc/localshare/server.key
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/localshare

[Install]
WantedBy=multi-user.target
```

防火墙只开放该 TLS 端口。证书更新后以部署 hook 执行 `systemctl restart localshare-server`，让进程加载新证书。证书续期由部署者已有的 ACME 工具负责。

## 使用本机 HTTPS 代理

已有 Nginx 等代理时，将上面的 ExecStart 替换为：

```ini
ExecStart=/usr/local/bin/localshare-server serve --listen 127.0.0.1:18080 --public-url https://share.example.com --behind-proxy
```

`--behind-proxy` 强制回环监听，TLS 在同一台机器的代理处终止。代理需覆盖并重新设置身份头，支持 WebSocket，关闭响应缓存、缓冲与访问日志中的分享路径。Nginx 的 HTTPS server 内可配置：

```nginx
access_log off;
client_max_body_size 64k;
location / {
    proxy_pass http://127.0.0.1:18080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_read_timeout 65s;
    proxy_send_timeout 65s;
}
```

使用独立的子域名和 server 配置，HTTP 入口跳转到 HTTPS。证书需覆盖该子域名。代理层建议增加连接与请求频率上限；健康检查和分享响应均不缓存。证书续期后先 `nginx -t`，再 `systemctl reload nginx`；回环 Server 无需重启。

## 启动与验证

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now localshare-server
sudo systemctl is-active localshare-server
curl --fail --max-time 10 https://share.example.com/healthz
sudo journalctl -u localshare-server --no-pager -n 50
```

直接 TLS 示例的健康地址应包含 `:18443`。健康 JSON 含 status、connected_devices、in_flight、relayed_bytes 、rejected_requests 和 failures 分类计数；计数在进程重启后归零。relayed_bytes 为限速器获准转发的字节数，不能替代云厂商账单。

## 注册与资源额度

自托管默认关闭自动注册。健康检查通过后生成一次性配对码：

```bash
sudo -u localshare localshare-server key create --name macbook
```

仅公开默认服务等明确需要自助准入的部署才追加 `--registration`。自动注册生成每设备独立随机凭据，客户端不内置共享密钥。

| 参数 | 默认值 |
| --- | --- |
| `--max-devices` | 1,000 个自动注册设备记录 |
| `--registrations-per-hour` | 每 IP 每小时 5 次注册或配对尝试 |
| `--device-requests` / `--total-requests` | 8 / 64 个请求 |
| `--device-bytes-per-second` / `--total-bytes-per-second` | 4194304 / 33554432 |

另有每 IP 每分钟 60 次建连、每设备一个 WebSocket、256 个 HTTP 连接、64 KiB 数据块和 4 消息请求队列。转发头与请求 URI 各限 4 KiB，元数据超限返回 431。超限返回 429，注册容量耗尽返回 503。按带宽套餐调整速率，配合云平台账单告警和代理层准入；服务没有用户账号或月流量计费系统。

## 撤销与清理

```bash
sudo -u localshare localshare-server key list
sudo -u localshare localshare-server key revoke <key-id>
sudo -u localshare localshare-server device list
sudo -u localshare localshare-server device revoke <device-id>
sudo -u localshare localshare-server device prune
```

撤销在运行 Server 的一秒检查周期内关闭连接、作废分享链接并取消在途下载；后续连接拒绝。prune 删除已撤销设备和已消费配对码，保留有效设备。离线设备凭据保留以便重连。

设备名称与 token 哈希持久化，内容不落盘；目录权限 0700，状态和锁文件 0600。不要记录明文凭据、分享 URL 或请求内容。中继可读取分享内容；HTTPS/WSS 提供链路加密。

完成后[连接 Client](./connect-client)，再使用不同网络的真实浏览器验证文件、文本和停止分享。
