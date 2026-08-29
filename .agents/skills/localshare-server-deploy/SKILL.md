---
name: localshare-server-deploy
description: 在 Linux 主机上安装、配置、升级或排查自托管 LocalShare Server，并验证 systemd、健康检查和一次性配对 key。用于用户要求部署 LocalShare 远程分享 Server；不用于 macOS Client 或纯局域网分享。
license: MIT
metadata:
  author: rrbe
  version: "1.0.0"
---

# LocalShare Server 部署

部署一个可持久运行的 `localshare-server`，验证公开地址可用，并为 LocalShare Client 生成一次性 Enrollment Key。Server 只转发请求与文件流，不保存 Mac 上的分享内容。

目标环境是使用 systemd 的 Linux，需具备 `curl`、sudo 或 root 权限，以及访问 GitHub Releases 的出站 HTTPS 网络。

## 确认部署边界

- 只操作用户明确指定的主机。用户说“当前服务器”时操作当前 Linux 主机；未指定远程目标时不要猜测 SSH 主机。
- 开始写入前确定公开基地址、监听端口，以及使用 HTTP 还是 Server 直接终止 TLS。公开基地址不能带额外 path 或 query。
- HTTPS 需要域名匹配的证书和私钥路径。不要自行申请证书、配置反向代理或修改 DNS，除非用户明确要求。
- 修改防火墙、覆盖已有 systemd unit、替换已有二进制或调整已有 TLS 文件前，先展示检测结果并取得确认。
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

如果最新 Release 没有对应 Server 资产，停止并说明情况；可以询问用户是否改为从源码构建，但不要静默下载未经发布的构建。

## 创建运行账户和状态目录

如不存在，创建系统用户：

```bash
sudo useradd --system --home /var/lib/localshare --shell /usr/sbin/nologin localshare
sudo install -d -o localshare -g localshare -m 0700 /var/lib/localshare
```

状态目录必须持久化。不得删除、清空或重新生成已有 `state.json`。保持状态目录权限为 `0700`；Server 会把状态文件和锁文件权限收敛为 `0600`。

## 配置 systemd

使用 `/etc/systemd/system/localshare-server.service`。基础 `ExecStart` 为：

```text
/usr/local/bin/localshare-server serve --listen :<port> --public-url <public-base-url> --state-dir /var/lib/localshare
```

Server 直接终止 TLS 时追加 `--tls-cert <certificate-path> --tls-key <private-key-path>`，并确认 `localshare` 用户可以读取这两个文件。

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
2. 请求 `<public-base-url>/healthz`，必须返回 HTTP 200 和包含 `{"status":"ok"}` 的 JSON。
3. 如果失败，查看 `journalctl -u localshare-server --no-pager -n 100`，修复真实原因后重新验证；不要在健康检查失败时生成 key 或宣布完成。
4. 健康检查通过后运行：

   ```bash
   sudo -u localshare /usr/local/bin/localshare-server key create \
     --name <device-name> \
     --state-dir /var/lib/localshare
   ```

5. 把一次性 Enrollment Key 只返回给用户，并提醒在 macOS Client 的“设置 → 远程访问”中填写公开地址和 key。

## 交付结果

报告已安装版本和架构、公开地址、监听端口、TLS 模式、systemd 状态、健康检查结果、状态目录，以及 Enrollment Key。明确列出任何没有执行的防火墙、DNS、证书或外部连通性工作。
