---
title: LocalShare Server
description: LocalShare Server 为不同网络之间的临时文件和文本分享提供中继，接收者只需要浏览器。
---

# LocalShare Server

LocalShare Server 把远程浏览器的请求转发到 Mac 上的 LocalShare，让不同网络中的人也能打开当前分享。发送端运行 LocalShare，接收端只需浏览器。

普通用户可直接使用 App 内置默认服务；自托管用户在设置中更换服务器地址，首次用配对码连接。公网使用 HTTPS/WSS，中继可读取内容，分享内容不落盘。

## 它负责什么

<div class="feature-grid">
  <div class="feature-card">
    <h3>设备配对</h3>
    <p>默认服务自动完成注册。自托管使用一次性配对码，配对后 App 保存设备凭据，后续无需再次输入。</p>
  </div>
  <div class="feature-card">
    <h3>请求中继</h3>
    <p>接收远程浏览器请求，通过 Client 主动建立的 WebSocket 转发，再把响应流返回浏览器。</p>
  </div>
  <div class="feature-card">
    <h3>临时分享</h3>
    <p>同一连接的文本更新保持 Share Token。断开连接、更换分享内容或 Server 重启后，旧地址都会失效。</p>
  </div>
  <div class="feature-card">
    <h3>即时转发</h3>
    <p>访问者打开链接时，内容才从 Mac 传出。中继不保存文件，分享期间 Mac 需要保持在线。</p>
  </div>
</div>

## 请求路径

<div class="flow">远程浏览器
    │ HTTPS
    ▼
LocalShare Server
    │ 已认证 WebSocket
    ▼
LocalShare Client ──▶ 本地 FileServer ──▶ 分享内容</div>

Client 主动连接 Server，因此不需要端口转发、SSH 隧道或把 Mac 的 FileServer 暴露到公网。Server 只需要一个可供浏览器和 Client 访问的端口。

## 开始使用

| 你想做什么 | 下一步 |
| --- | --- |
| 使用默认公共服务 | [连接 Client](./connect-client#使用默认服务) |
| 在自己的服务器上运行中继 | [选择部署方式](./deployment) |
| 让 Codex 帮助准备和执行部署 | [让 Codex 部署](./codex-deploy) |

自托管可以使用公网 IP，也可以使用域名。已有 Nginx 或 CDN 时有对应的部署说明。

::: info 分享范围
远程文件只读；文本可以查看，也可单独开启远程收文本，单次最多 64 KiB。局域网的上传和收文本权限独立设置。HTTPS/WSS 加密传输链路，中继服务可以读取内容。
:::
