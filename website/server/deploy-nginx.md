---
title: 已有 Nginx + Let’s Encrypt
description: 复用现有 Nginx 和证书续期，将 HTTPS 与 WebSocket 转发到本机 LocalShare Server。
---

# 已有 Nginx + Let’s Encrypt

复用现有 Nginx 和 Certbot，新增一个中继站点即可。Server 只在本机监听，HTTPS 由 Nginx 提供。

<div class="flow">LocalShare / 浏览器  ── HTTPS ──▶  Nginx:443  ──▶  Server:18080</div>

下文使用 `share.example.com`，请换成自己的域名。先完成[程序安装](./deployment#_1-安装-server)。中继使用独立域名或子域名，不部署在主站的 `/share` 子路径下。

## 1. 准备域名与证书

让域名的 A 记录指向服务器公网 IP，云安全组和本机防火墙允许 TCP 80、443。该域名直接解析到服务器；需要经过 CDN 时请看 [CDN 方案](./deploy-cdn)。

若现有证书已覆盖该域名，直接复用。否则使用已安装的 Certbot 申请：

```bash
sudo certbot certonly --nginx -d share.example.com
```

下文证书路径假定为 `/etc/letsencrypt/live/share.example.com/`，可用 `sudo certbot certificates` 确认实际路径。

## 2. 启动本机 Server

创建 `/etc/systemd/system/localshare-server.service`：

```ini
[Unit]
Description=LocalShare Server
After=network-online.target
Wants=network-online.target

[Service]
User=localshare
Group=localshare
ExecStart=/usr/local/bin/localshare-server serve --listen 127.0.0.1:18080 --public-url https://share.example.com --behind-proxy
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/localshare

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now localshare-server
curl --fail --max-time 10 http://127.0.0.1:18080/healthz
```

18080 仅供同机 Nginx 使用，无需开放公网端口。

## 3. 新增 Nginx 站点

将下面配置保存为 `/etc/nginx/conf.d/localshare.conf`。若现有 Nginx 使用其他站点目录，放到其已启用的 include 目录中。

```nginx
server {
    listen 80;
    server_name share.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name share.example.com;
    ssl_certificate /etc/letsencrypt/live/share.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/share.example.com/privkey.pem;

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
        proxy_cache off;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 65s;
        proxy_send_timeout 65s;
    }
}
```

这是一个独立站点配置，保留现有主站的配置。`Upgrade` 和 `Connection` 用于 [WebSocket 转发](https://nginx.org/en/docs/http/websocket.html)，关闭缓存与缓冲可让分享内容实时从 Mac 传到浏览器。

```bash
sudo nginx -t
sudo systemctl reload nginx
curl --fail --max-time 10 https://share.example.com/healthz
```

从服务器外执行最后一条命令，确认返回 HTTP 200 且 JSON 的 `status` 为 `ok`。

## 4. 确保证书续期后重新加载

沿用现有 Certbot 自动续期任务。若已有成功续期后重新加载 Nginx 的 hook，无需新增；否则创建：

```bash
sudo install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/localshare-nginx >/dev/null <<'SH'
#!/bin/sh
set -eu
nginx -t
systemctl reload nginx
SH
sudo chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/localshare-nginx
sudo certbot renew --cert-name share.example.com --dry-run --run-deploy-hooks
```

`--cert-name` 使用 `certbot certificates` 中的实际名称。此方式只重新加载 Nginx，Server 无需重启。

## 5. 在 LocalShare 中使用

[选择设备注册方式](./deployment#_3-选择设备注册方式)，服务器地址填 `https://share.example.com`，然后[连接 Client](./connect-client)。默认使用配对码；Server 开放自动注册后，配对码可留空。
