---
title: LocalShare Server
description: LocalShare Server 是用于跨网络只读分享的自托管控制面和数据中继。
---

# LocalShare Server

LocalShare Server 是远程分享的控制面和数据中继。它让外部浏览器访问当前在线的 LocalShare Client，同时保持 Mac 位于防火墙或 NAT 之后。

## 它负责什么

<div class="feature-grid">
  <div class="feature-card">
    <h3>设备配对</h3>
    <p>使用一次性 Enrollment Key 注册 Client，并用保存在 Keychain 中的 Device Token 进行后续认证。</p>
  </div>
  <div class="feature-card">
    <h3>请求中继</h3>
    <p>接收远程浏览器请求，通过 Client 主动建立的 WebSocket 转发，再把响应流返回浏览器。</p>
  </div>
  <div class="feature-card">
    <h3>临时分享</h3>
    <p>每次连接发布新的 Share Token。断开连接、更换分享内容或 Server 重启后，旧地址都会失效。</p>
  </div>
  <div class="feature-card">
    <h3>最小持久化</h3>
    <p>只保存 Enrollment Key 和 Device Token 的 SHA-256，不保存 Mac 上的文件、目录或明文凭据。</p>
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

## 适用场景

- 手机和 Mac 不在同一个 Wi-Fi
- 希望使用自己的域名与 TLS 证书
- 需要让外部人员通过浏览器临时只读访问文件
- 不希望把文件预先上传到云盘或长期存放在中继服务中

## 不提供的能力

- Server 不保存或同步分享内容
- 远程访问不支持访客上传
- 远程访问不支持 Text Transfer
- Server 不替代长期对象存储或用户账号系统

准备开始部署时，请继续阅读[安装与部署](./deployment)。
