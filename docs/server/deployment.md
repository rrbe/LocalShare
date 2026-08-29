---
title: 安装与部署
description: 下载 LocalShare Server，配置状态目录、监听端口、TLS 与 systemd 服务。
---

# 安装与部署

LocalShare Server 是 Go 编写的单文件程序。GitHub Release 提供 Linux amd64 和 arm64 二进制，运行时不依赖 SSH、frp、Nginx 或其他 LocalShare 组件。

::: tip 交给 Codex 完成
如果 Codex 正运行在目标 Linux 服务器上，可以直接复制一段部署提示，让它检查环境、安装 Server、配置 systemd 并验证结果。参见[让 Codex 部署](./codex-deploy)。
:::

## 下载二进制

从 [GitHub Releases](https://github.com/rrbe/LocalShare/releases) 下载与服务器架构匹配的文件，然后安装：

```bash
chmod +x LocalShare-Server-*-linux-*
sudo install -m 0755 LocalShare-Server-*-linux-* \
  /usr/local/bin/localshare-server
```

也可以从源码构建：

```bash
cd server
go test ./...
go build -trimpath -ldflags "-s -w" -o localshare-server .
```

要求 Go 1.23 或更高版本。

## 准备运行用户和状态目录

```bash
sudo useradd --system \
  --home /var/lib/localshare \
  --shell /usr/sbin/nologin localshare

sudo install -d -o localshare -g localshare -m 0700 \
  /var/lib/localshare
```

状态目录必须持久化。删除其中的 `state.json` 会让全部已配对设备失效。

## 创建 Enrollment Key

```bash
sudo -u localshare /usr/local/bin/localshare-server key create \
  --name macbook \
  --state-dir /var/lib/localshare
```

命令会输出一个只允许成功配对一次的 key。复制它，下一步将在 Client 中使用。

## 启动 Server

先用 HTTP 验证部署：

```bash
sudo -u localshare /usr/local/bin/localshare-server serve \
  --listen :18080 \
  --public-url http://server.example:18080 \
  --state-dir /var/lib/localshare
```

`--public-url` 是浏览器和 Client 使用的 Server 基地址，不能包含额外路径或 query。防火墙只需要允许当前监听端口。

生产环境建议直接配置 HTTPS：

```bash
sudo -u localshare /usr/local/bin/localshare-server serve \
  --listen :18443 \
  --public-url https://share.example.com:18443 \
  --tls-cert /etc/localshare/server.crt \
  --tls-key /etc/localshare/server.key \
  --state-dir /var/lib/localshare
```

证书必须覆盖 `share.example.com`。使用 `https` 的 `--public-url` 时，必须同时提供 `--tls-cert` 和 `--tls-key`。

## 配置 systemd

创建 `/etc/systemd/system/localshare-server.service`：

```ini
[Unit]
Description=LocalShare Server
After=network-online.target
Wants=network-online.target

[Service]
User=localshare
Group=localshare
ExecStart=/usr/local/bin/localshare-server serve --listen :18080 --public-url http://server.example:18080 --state-dir /var/lib/localshare
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/localshare

[Install]
WantedBy=multi-user.target
```

启动服务并检查状态：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now localshare-server
curl http://server.example:18080/healthz
sudo journalctl -u localshare-server -f
```

健康检查应返回包含 `{"status":"ok"}` 的 JSON。

## 管理设备和 key

```bash
localshare-server key list --state-dir /var/lib/localshare
localshare-server key revoke --state-dir /var/lib/localshare <key-id>
localshare-server device list --state-dir /var/lib/localshare
localshare-server device revoke --state-dir /var/lib/localshare <device-id>
```

Enrollment Key、Device Token 和 Share Token 都不应写入公开日志或提交到代码仓库。

完成部署后，继续[连接 LocalShare Client](./connect-client)。
