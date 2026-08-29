# LocalShare Server

LocalShare Server 是远程分享的控制面和数据中继。它只转发请求与文件流，不保存 Mac 上的分享内容。Server 使用一个端口，要求 Go 1.23+。

## 一、下载或编译

GitHub Release 提供 Linux amd64 / arm64 单文件二进制和 SHA-256 校验文件。下载与服务器架构匹配的
`LocalShare-Server-<version>-linux-<arch>` 后安装：

```bash
chmod +x LocalShare-Server-*-linux-*
sudo install -m 0755 LocalShare-Server-*-linux-* /usr/local/bin/localshare-server
```

也可以在仓库根目录从源码编译：

```bash
cd server
go test ./...
go test -race ./...
go build -trimpath -ldflags "-s -w" -o localshare-server .
```

如果部署到 Linux，可以在 macOS 上交叉编译：

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags "-s -w" -o localshare-server .
```

把生成的 `localshare-server` 复制到目标服务器即可，不需要安装 SSH/frp/Nginx 或其他 LocalShare 运行时组件。

## 二、本机快速测试

打开两个终端。

终端 A：生成测试目录和一次性配对 key：

```bash
cd server
state_dir=$(mktemp -d)
./localshare-server key create --name test-mac --state-dir "$state_dir"
```

复制命令输出的 `key`。它只允许成功配对一次。

终端 A 继续启动 Server：

```bash
./localshare-server serve \
  --listen 127.0.0.1:18080 \
  --public-url http://127.0.0.1:18080 \
  --state-dir "$state_dir"
```

终端 B 检查 Server：

```bash
curl http://127.0.0.1:18080/healthz
```

预期返回包含：

```json
{"status":"ok"}
```

这里的 `127.0.0.1` 只适合 Server 和 LocalShare Client 在同一台 Mac 上测试。若 Client 在另一台 Mac，Server 必须监听可访问地址，例如 `--listen :18080`，并使用服务器局域网地址作为 Client 的 Server address。

## 三、配置 LocalShare Client

1. 编译并启动 macOS Client：

   ```bash
   cd ..
   swift build
   .build/debug/LocalShare
   ```

   或使用 `./build.sh` 生成，再执行 `open dist/LocalShare.app`。

2. 在 Client 中选择一个文件或文件夹，让本地分享先运行。
3. 打开「设置 → 远程访问」：

   - `Server address`：填写 `http://127.0.0.1:18080`，或远程服务器的可访问地址；
   - `Enrollment key`：填写终端 A 生成的 `key`。

4. 点击保存，回到分享票据，点击 `Connect`。
5. 配对成功后，Client 会把 Device Token 保存到 macOS Keychain；Enrollment Key 不会持久化。
6. 连接成功后，分享票据上会显示 Server 生成的远程访问地址。用浏览器打开这个地址即可测试文件浏览和下载。

之后再次使用只需要点击 `Connect`，不需要重新填写 key。`Disconnect` 只断开当前长连接，`Forget Device` 才会删除 Keychain 中的 Device Token。

Client 重启后不会自动公开分享；选择文件并点击 `Connect` 即可使用已经配对的设备凭据重新连接。

## 四、Linux 服务器部署

生产部署只需要持久化二进制、状态目录和一个监听端口：

```bash
sudo install -m 0755 localshare-server /usr/local/bin/localshare-server
sudo useradd --system --home /var/lib/localshare --shell /usr/sbin/nologin localshare
sudo install -d -o localshare -g localshare -m 0700 /var/lib/localshare
```

先生成配对 key：

```bash
sudo -u localshare /usr/local/bin/localshare-server key create \
  --name macbook \
  --state-dir /var/lib/localshare
```

然后启动：

```bash
sudo -u localshare /usr/local/bin/localshare-server serve \
  --listen :18080 \
  --public-url http://server.example:18080 \
  --state-dir /var/lib/localshare
```

`--public-url` 必须是浏览器和 Client 使用的 Server 基地址，不能带额外路径或 query。`state-dir` 必须持久化；删除其中的 `state.json` 会使已配对设备全部失效。

如果使用 HTTPS，Server 可以直接终止 TLS：

```bash
sudo -u localshare /usr/local/bin/localshare-server serve \
  --listen :18443 \
  --public-url https://ls.example.com \
  --tls-cert /etc/localshare/server.crt \
  --tls-key /etc/localshare/server.key \
  --state-dir /var/lib/localshare
```

`https` 的 `--public-url` 必须同时提供 `--tls-cert` 和 `--tls-key`；证书的域名必须匹配 Server address。HTTP 配置不应传入 TLS 参数。

如使用 systemd，可创建 `/etc/systemd/system/localshare-server.service`：

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

启动并检查：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now localshare-server
curl http://server.example:18080/healthz
sudo journalctl -u localshare-server -f
```

防火墙只需要允许 Server 的这个端口。Client 不需要把 Mac 的 FileServer 端口暴露给外部；Client 会主动向 Server 建立 WebSocket 长连接。

## 五、管理命令

```bash
localshare-server key list
localshare-server key revoke <key-id>
localshare-server device list --state-dir /var/lib/localshare
localshare-server device revoke --state-dir /var/lib/localshare <device-id>
```

Server 只在 `state.json` 中保存 Enrollment Key 和 Device Token 的 SHA-256，不保存明文 token。Enrollment Key、Device Token 和 Share Token 都不应写入公开日志或提交到代码仓库。
运行中的 Server 与管理 CLI 通过状态目录里的 `.state.lock` 串行化修改，避免创建 Key、配对和撤销并发时丢更新；目录权限会收敛为 `0700`，`state.json` 与锁文件为 `0600`。

## 六、排查顺序

1. `curl <server-address>/healthz` 是否返回 200。
2. Server address 是否为基地址，例如 `http://server.example:18080`，没有额外 path/query。
3. Enrollment Key 是否已经被使用；已使用时重新运行 `key create`。
4. `device list` 是否能看到配对设备。
5. Client 是否已经选择文件并点击 `Connect`；空分享时 Connect 会被禁用。
6. Client 状态是否为 `Connected`，并且分享票据是否出现远程 URL。
7. 远程 URL 是否仍然对应当前连接；Disconnect、换分享内容或 Server 重启后旧 Share Token 都会失效。

完整架构、消息协议和取舍见 [`docs/REMOTE_SHARING_PLAN.md`](../docs/REMOTE_SHARING_PLAN.md)。
