---
title: 只有公网 IP
description: 无需域名，使用 Let’s Encrypt IP 证书，让 LocalShare Server 直接提供 HTTPS。
---

# 只有公网 IP

无需购买域名，也无需安装 Nginx。Server 直接监听 443，使用浏览器信任的 IP 证书。

<div class="flow">LocalShare / 浏览器  ── HTTPS ──▶  公网 IP:443  ──▶  Server</div>

下文以 `1.2.3.4` 为例，部署时换成自己的公网 IP。先完成[程序安装](./deployment#_1-安装-server)。

## 1. 准备端口与 Certbot

服务器的云安全组和本机防火墙需允许入站 TCP **80、443**。80 用于申请和续期证书，443 用于分享；本方案要求这两个端口未被其他服务占用。

安装官方 Snap 版 Certbot，使用 5.4 或更新版本：

```bash
sudo apt-get update
sudo apt-get install -y snapd
sudo snap install --classic certbot
sudo /snap/bin/certbot --version
```

已有 Certbot 可直接使用符合版本要求的安装。其他发行版参考 [Certbot 官方安装说明](https://certbot.eff.org/instructions?ws=other&os=snap)。

## 2. 申请 IP 证书

```bash
sudo /snap/bin/certbot certonly --standalone \
  --preferred-profile shortlived \
  --ip-address 1.2.3.4 \
  --cert-name localshare
```

按照 Certbot 提示填写邮箱并确认服务条款。证书保存在 `/etc/letsencrypt/live/localshare/`。

[Let’s Encrypt 支持公网 IP 证书](https://letsencrypt.org/2026/03/11/shorter-certs-certbot.html)，有效期约 6 天，所以要完成第 4 步的自动续期。无需让接收者手动信任证书。

## 3. 配置并启动 Server

把证书复制到服务账户可读取的目录：

```bash
sudo install -d -o root -g localshare -m 0750 /etc/localshare
sudo install -o root -g localshare -m 0640 /etc/letsencrypt/live/localshare/fullchain.pem /etc/localshare/server.crt
sudo install -o root -g localshare -m 0640 /etc/letsencrypt/live/localshare/privkey.pem /etc/localshare/server.key
```

创建 `/etc/systemd/system/localshare-server.service`，记得替换示例 IP：

```ini
[Unit]
Description=LocalShare Server
After=network-online.target
Wants=network-online.target

[Service]
User=localshare
Group=localshare
ExecStart=/usr/local/bin/localshare-server serve --listen :443 --public-url https://1.2.3.4 --tls-cert /etc/localshare/server.crt --tls-key /etc/localshare/server.key
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/localshare

[Install]
WantedBy=multi-user.target
```

`AmbientCapabilities` 允许非 root 服务账户监听 443。

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now localshare-server
curl --fail --max-time 10 https://1.2.3.4/healthz
```

从服务器外执行最后一条命令，确认返回 HTTP 200 且 JSON 的 `status` 为 `ok`。

## 4. 配置自动续期

Snap 版 Certbot 自带续期任务。Server 在启动时加载证书，需要在续期成功后复制新证书并重启。

创建部署 hook：

```bash
sudo install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/localshare-server >/dev/null <<'SH'
#!/bin/sh
set -eu
[ "${RENEWED_LINEAGE:-}" = /etc/letsencrypt/live/localshare ] || exit 0
install -o root -g localshare -m 0640 "$RENEWED_LINEAGE/fullchain.pem" /etc/localshare/server.crt
install -o root -g localshare -m 0640 "$RENEWED_LINEAGE/privkey.pem" /etc/localshare/server.key
systemctl restart localshare-server
SH
sudo chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/localshare-server
```

检查续期任务并试运行；第二条命令会执行 hook、重启 Server，让当前分享链接失效：

```bash
systemctl list-timers --all | grep certbot
sudo /snap/bin/certbot renew --cert-name localshare --dry-run --run-deploy-hooks
curl --fail --max-time 10 https://1.2.3.4/healthz
```

80 端口需保持可达，供后续自动验证。续期 hook 的行为见 [Certbot 文档](https://eff-certbot.readthedocs.io/en/stable/using.html#renewing-certificates)。

## 5. 在 LocalShare 中使用

[生成配对码](./deployment#_3-配对与分享)，服务器地址填 `https://1.2.3.4`，然后[连接 Client](./connect-client)。接收者直接在浏览器打开分享链接。

::: details 进阶：之后换成域名
把域名的 A 记录指向该公网 IP，再为域名申请证书，将 `--public-url` 改为域名地址并更新证书配置。续期 hook 也需指向新证书。

更换服务器地址后，Client 需用新的配对码连接。若已有 Nginx，可以改用 [Nginx 方案](./deploy-nginx)。
:::
