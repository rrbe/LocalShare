# LocalShare Server

单文件 Go 中继，为浏览器转发 Mac 上的文件和文本，内容不落盘。公网强制 HTTPS/WSS；中继可读取内容。要求 Go 1.23+，协议 v2，Client 与 Server 需一起升级。

## 编译和验证

```bash
go test -race ./...
go vet ./...
go build -trimpath -ldflags '-s -w' -o localshare-server .
# Linux amd64，也可将 GOARCH 改为 arm64
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags '-s -w' -o localshare-server-linux .
```

## 同机开发测试

```bash
state_dir=$(mktemp -d)
./localshare-server key create --name test-mac --state-dir "$state_dir"
./localshare-server serve --listen 127.0.0.1:18080 --public-url http://127.0.0.1:18080 --state-dir "$state_dir"
curl --fail --max-time 5 http://127.0.0.1:18080/healthz
```

在 Client 的「设置 → 网络 → 使用自托管服务器」填写回环地址和一次性配对码，配对后在文件或文本页连接。HTTP 仅适合回环测试，跨机器使用 HTTPS。

自动注册测试可追加 `--registration`，通过 `POST /api/v1/register` 创建独立设备凭据。自托管默认关闭该入口。普通用户使用 App 内置默认服务，不需要管理 Server。

## 生产部署和管理

先阅读 [安装与部署](../website/server/deployment.md)，再选择 [只有公网 IP](../website/server/deploy-ip.md)、[已有 Nginx + Let’s Encrypt](../website/server/deploy-nginx.md) 或 [已接入 CDN](../website/server/deploy-cdn.md)。文档包含 systemd、证书续期、配对和验证步骤，域名可选。状态默认在 `/var/lib/localshare`，升级必须保留 state.json；本机代理方式需使用回环监听及 `--behind-proxy`。

```bash
localshare-server key create --name macbook
localshare-server key list
localshare-server key revoke <key-id>
localshare-server device list
localshare-server device revoke <device-id>
localshare-server device prune
```

撤销在一秒检查周期内停止在线连接、分享和在途请求；prune 删除已撤销设备及已消费配对码。独立凭据只保存哈希，状态写入由跨进程锁保护。不要输出或提交明文凭据。

默认：每 IP 每小时 5 次注册/配对、每分钟 60 次建连、每设备一个连接、8 个设备请求、64 个全服务请求、4/32 MiB/s 设备/服务速率、1000 个自动注册记录。数据块最多 64 KiB，每块 HTTP 写入后确认，60 秒空闲/写入期限，浏览器取消释放本机任务。详见 [方案与协议](../docs/REMOTE_SHARING_PLAN.md)。

在仓库根目录运行 `./tools/smoke-remote-e2e.sh` 验证真实 Browser → Go → WSS/WS → Swift → FileServer 链路；本地测试使用回环 HTTP，生产 TLS 需另行验证。
