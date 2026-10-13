---
title: 安装与部署
description: 按现有环境选择：只有公网 IP、已有 Nginx 与证书、已接入 CDN。
---

# 安装与部署

自托管需要一台有公网入口的 Linux 服务器，运行一个 LocalShare Server，并提供 HTTPS 地址。**域名可选**；接收者始终只需要浏览器。

如果使用 App 内置默认服务，可以直接[开始远程分享](./connect-client)，无需部署。

## 按现有环境选择

| 你的环境 | 部署方式 | 需要做的工作 |
| --- | --- | --- |
| [只有公网 IP](./deploy-ip) | Server 直接提供 HTTPS | 安装程序、申请 IP 证书、配置自动续期 |
| [已有 Nginx + Let’s Encrypt](./deploy-nginx) | Nginx 提供 HTTPS，转发到本机 Server | 新增一个站点、配置 WebSocket 转发、复用证书续期 |
| [已接入 EdgeOne 等 CDN](./deploy-cdn) | CDN → Nginx → Server，或中继子域名直连 | 配置回源、WebSocket 和缓存；直连时按 Nginx 方案部署 |

先完成下面的程序安装，再进入对应方案。命令以使用 systemd 的 Ubuntu / Debian 为例。也可以[让 Codex 准备部署方案](./codex-deploy)。

## 1. 安装 Server

Server 是一个独立二进制，运行时无需安装 Go。从 [GitHub Releases](https://github.com/rrbe/LocalShare/releases) 下载对应版本的 Linux 二进制和校验文件。`<version>` 替换为版本号；下面使用 amd64，arm64 机器改用对应文件。

```bash
sha256sum --ignore-missing -c LocalShare-Server-<version>-checksums.txt
sudo install -m 0755 LocalShare-Server-<version>-linux-amd64 /usr/local/bin/localshare-server
```

只有校验结果为 `OK` 才继续安装。若 Release 尚未提供 Server 文件，使用下面的源码构建方式。

::: details 从源码构建（需要 Go 1.23+）
在仓库中选择与 Client 配套的版本，再构建 Linux 程序：

```bash
git clone https://github.com/rrbe/LocalShare.git
cd LocalShare/server
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags '-s -w' -o localshare-server .
```

把生成的 `localshare-server` 复制到目标服务器，然后安装：

```bash
sudo install -m 0755 localshare-server /usr/local/bin/localshare-server
```

arm64 服务器将 `GOARCH` 改为 `arm64`。Client 与 Server 协议需一致，当前为 v2。
:::

首次安装时，创建运行账户与持久化目录：

```bash
sudo useradd --system --home /var/lib/localshare --shell /usr/sbin/nologin localshare
sudo install -d -o localshare -g localshare -m 0700 /var/lib/localshare
```

已有部署跳过账户创建，保留 `/var/lib/localshare/state.json`，其中保存已配对设备的状态。

## 2. 配置 HTTPS 并启动

选择一种方案继续，每页都有对应的 systemd 配置和验证步骤：

- [只有公网 IP](./deploy-ip)
- [已有 Nginx + Let’s Encrypt](./deploy-nginx)
- [已接入 EdgeOne 等 CDN](./deploy-cdn)

## 3. 选择设备注册方式

Server 默认使用一次性配对码。是否允许免配对码连接，由 Server 的 `--registration` 参数决定；设置了域名或 HTTPS 地址不会自动开启注册。

| 方式 | Server 配置 | App 操作 |
| --- | --- | --- |
| 配对码注册（默认） | 不加 `--registration` | 首次填写管理员提供的配对码 |
| 自动注册 | 加 `--registration` | 配对码留空，App 自动获取并保存设备凭据 |

### 使用配对码

服务启动且公开地址的 `/healthz` 验证通过后，生成一个一次性配对码：

```bash
sudo -u localshare /usr/local/bin/localshare-server key create --name macbook
```

在 LocalShare 的「设置 → 网络 → 使用自托管服务器」填入 HTTPS 地址和配对码。之后只需在分享页开启「互联网」开关，将生成的链接发给接收者。详见[连接 Client](./connect-client)。

### 开放自动注册

在 systemd 服务的 `ExecStart` 末尾加上 `--registration`。例如，使用同机 Nginx 的完整启动命令是：

```ini
ExecStart=/usr/local/bin/localshare-server serve --listen 127.0.0.1:18080 --public-url https://share.example.com --behind-proxy --registration
```

修改后执行：

```bash
sudo systemctl daemon-reload
sudo systemctl restart localshare-server
```

此方式允许访问这个 Server 的 App 自助注册，无需执行 `key create`。自托管用户填写服务器地址，配对码留空，点击「配对」或保存后在分享页开启「互联网」开关。已注册设备会复用保存的凭据。

App 内置默认服务通过自动注册连接；运营默认服务的 Server 也必须加上 `--registration`。使用默认服务的用户无需填写地址或配对码。

## 日常维护

升级前备份二进制和服务配置，保留状态目录。直接 TLS 模式续期后要重启 Server；Nginx 模式只需重新加载 Nginx。**Server 重启会使当前分享链接失效**，Client 重连后会获得新链接。

::: details 查看状态、撤销设备与调整带宽
查看运行状态与日志：

```bash
sudo systemctl status localshare-server
sudo journalctl -u localshare-server --no-pager -n 50
```

管理配对码与设备：

```bash
sudo -u localshare /usr/local/bin/localshare-server key list
sudo -u localshare /usr/local/bin/localshare-server key revoke <key-id>
sudo -u localshare /usr/local/bin/localshare-server device list
sudo -u localshare /usr/local/bin/localshare-server device revoke <device-id>
sudo -u localshare /usr/local/bin/localshare-server device prune
```

撤销设备会终止其在线连接和分享。`prune` 清理已撤销设备与已消费配对码，保留有效设备。

按服务器的带宽套餐调整 `ExecStart` 中的参数：

| 参数 | 默认值 |
| --- | --- |
| `--device-bytes-per-second` | 4194304（每设备 4 MiB/s） |
| `--total-bytes-per-second` | 33554432（整体 32 MiB/s） |
| `--device-requests` / `--total-requests` | 每设备 8 / 整体 64 个请求 |

例如整体限制为 1 MiB/s，可追加 `--total-bytes-per-second 1048576`。修改后执行 `systemctl daemon-reload` 和 `systemctl restart localshare-server`。`/healthz` 的累计转发字节数会在重启后归零，实际流量账单以云平台为准。

设备容量和注册频率等完整参数见 [Server README](https://github.com/rrbe/LocalShare/tree/master/server)。
:::
