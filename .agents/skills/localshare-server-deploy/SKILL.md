---
name: localshare-server-deploy
description: 在 Linux 主机上安装、配置、升级或排查自托管 LocalShare Server，并验证 systemd、健康检查和一次性配对 key。用于用户要求部署 LocalShare 远程分享 Server；不用于 macOS Client 或纯局域网分享。
license: MIT
metadata:
  author: rrbe
  version: "1.1.0"
---

# LocalShare Server 部署

部署一个可持久运行的 `localshare-server`，验证公开地址可用，并为 LocalShare Client 生成一次性 Enrollment Key。Server 只转发请求与文件流，不保存 Mac 上的分享内容。

目标环境是使用 systemd 的 Linux，需具备 `curl`、sudo 或 root 权限，以及访问 GitHub Releases 的出站 HTTPS 网络。

## 确认部署边界

- 只操作用户明确指定的主机。用户说“当前服务器”时操作当前 Linux 主机；未指定远程目标时不要猜测 SSH 主机。
- 先做只读检查，展示具体部署方案和对现有服务的影响，取得用户确认后再执行；已有确认覆盖的操作不重复询问。用户只要求方案、文档或本地预览时，停在该范围内。
- 根据现有环境选择：只有 IP 时由 Server 直接提供 HTTPS；已有 Nginx + Let’s Encrypt 时使用本机代理；已有 CDN 时说明中继直连与经过 CDN 两种方式。读取 [安装与部署](https://raw.githubusercontent.com/rrbe/LocalShare/master/website/server/deployment.md) 和对应的 [IP](https://raw.githubusercontent.com/rrbe/LocalShare/master/website/server/deploy-ip.md)、[Nginx](https://raw.githubusercontent.com/rrbe/LocalShare/master/website/server/deploy-nginx.md)、[CDN](https://raw.githubusercontent.com/rrbe/LocalShare/master/website/server/deploy-cdn.md) 步骤。
- 公开基地址可以是 IP 或域名，必须使用 HTTPS，不能带额外 path 或 query。证书必须覆盖所用 IP 或域名，HTTP 仅用于回环开发测试。
- 在方案中说明证书申请与自动续期、监听端口、DNS（使用域名时）和需要开放的防火墙端口。保留已有主站配置与设备状态；未包含在已确认方案中的现有服务变更需另行确认。
- Enrollment Key、Device Token 和 Share Token 不得写入公开日志或代码仓库。

## 只读预检

1. 检查 `uname -s` 为 Linux，并确认 `uname -m`：`x86_64` 映射为 `amd64`，`aarch64` 或 `arm64` 映射为 `arm64`。其他架构停止并报告不支持。
2. 确认 `systemctl`、`curl`、`sha256sum`、`sudo` 或 root 权限可用。
3. 检查目标端口是否被占用，并读取现有的 `localshare-server.service`、`/usr/local/bin/localshare-server` 和 `/var/lib/localshare` 状态。
4. 如果发现已有部署，保留 `/var/lib/localshare/state.json`；在用户确认升级或修复方案之前不要覆盖文件。

## 下载并校验 Release

从 `https://github.com/rrbe/LocalShare/releases/latest` 解析最新 `vX.Y.Z` tag，去掉 `v` 后得到版本号。下载：

```text
LocalShare-Server-<version>-linux-<arch>
LocalShare-Server-<version>-checksums.txt
```

在 `mktemp -d` 创建的临时目录中下载文件，用 checksums 文件和 `sha256sum -c` 校验目标二进制。只有校验通过后，才使用 `sudo install -m 0755` 安装到 `/usr/local/bin/localshare-server`。

如果最新 Release 没有对应 Server 资产，在方案中说明需从源码构建，指定与 Client 配套的版本和 Go 1.23+ 工具链。用户已确认源码构建时按安装文档执行；不要将源码构建描述成已发布二进制。

## 创建运行账户和状态目录

如不存在，创建系统用户：

```bash
sudo useradd --system --home /var/lib/localshare --shell /usr/sbin/nologin localshare
sudo install -d -o localshare -g localshare -m 0700 /var/lib/localshare
```

状态目录必须持久化。不得删除、清空或重新生成已有 `state.json`。保持状态目录权限为 `0700`；Server 会把状态文件和锁文件权限收敛为 `0600`。
Server 默认使用 `/var/lib/localshare`；只有用户明确选择其他目录时才追加 `--state-dir`，并同步调整 `ReadWritePaths`。

## 配置 systemd

使用 `/etc/systemd/system/localshare-server.service`。基础 `ExecStart` 为：

```text
/usr/local/bin/localshare-server serve --listen :<port> --public-url <public-base-url>
```

已有本机 HTTPS 代理时使用 `--listen 127.0.0.1:<port> --public-url <https-public-base-url> --behind-proxy`，检查代理覆盖 X-Real-IP 与 X-Forwarded-Proto、支持 WebSocket、关闭响应缓存/缓冲，并避免访问日志记录分享 token。

Server 直接终止 TLS 时追加 `--tls-cert <certificate-path> --tls-key <private-key-path>`，并确认 `localshare` 用户可以读取这两个文件。

只有 IP 时按 `website/server/deploy-ip.md` 使用 Certbot 5.4+ 的 `--ip-address` 和 `shortlived` 证书，配置成功续期后复制证书并重启 Server 的 hook。80 端口需可达且可供 standalone 验证使用。直接监听 443 的 unit 需添加 `AmbientCapabilities=CAP_NET_BIND_SERVICE`。

经过 CDN 时，`--public-url` 使用用户访问的 CDN 域名。按 `website/server/deploy-cdn.md` 配置 HTTPS 回源、Host/SNI、WebSocket、不缓存规则以及可信 CDN 网段的客户端 IP 转发。`/healthz` 成功不能替代实际分享验证。

Service 至少使用：

```ini
[Unit]
Description=LocalShare Server
After=network-online.target
Wants=network-online.target

[Service]
User=localshare
Group=localshare
ExecStart=<resolved command>
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/localshare

[Install]
WantedBy=multi-user.target
```

写入后运行 `systemctl daemon-reload` 和 `systemctl enable --now localshare-server`。

## 验证并生成配对 key

1. 确认 `systemctl is-active localshare-server` 返回 `active`。
2. 请求 `<public-base-url>/healthz`，必须返回 HTTP 200，JSON 的 status 为 ok（同时包含聚合资源计数）。
3. 如果失败，查看 `journalctl -u localshare-server --no-pager -n 100`，修复真实原因后重新验证；不要在健康检查失败时生成 key 或宣布完成。
4. 健康检查通过后运行：

   ```bash
   sudo -u localshare /usr/local/bin/localshare-server key create \
     --name <device-name>
   ```

5. 把一次性配对码只返回给用户，并提醒在 macOS Client 的「设置 → 网络 → 使用自托管服务器」中填写公开地址和配对码。
6. 验证证书自动续期及加载 hook。请用户用另一网络的浏览器打开分享链接、下载文件，并确认断开后旧链接失效；无法进行真实浏览器验证时明确报告尚未验证。

## 注册、升级和撤销

- 自托管默认关闭自动注册；只有明确运营公共服务时追加 `--registration`，同时确认注册频率、设备容量、请求并发和传输速率参数。
- Client 和 Server 协议 v2 必须一起升级。更新后验证文本、远程收文本开关、独立局域网权限和旧链接失效。
- `device revoke` 在一秒检查周期内停用在线连接、链接和在途请求；`device prune` 清理已撤销设备与已消费配对码。
- 直接 TLS 证书更新后重启服务；本机代理更新证书后校验并 reload 代理，确认公开 healthz 的有效证书。
- 中继可读取内容，HTTPS/WSS 不等于端到端加密。公网测试需使用真实跨网络浏览器。

## 交付结果

报告已安装版本和架构、公开地址、监听端口、TLS 模式、systemd 状态、健康检查结果、状态目录，以及 Enrollment Key。明确列出任何没有执行的防火墙、DNS、证书或外部连通性工作。
