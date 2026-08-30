---
title: LocalShare 文档
description: 通过局域网或自托管 Server，把 Mac 上的文件和文本安全地送到浏览器。
---

# 从 Mac 分享到任何浏览器

<p class="doc-lead">LocalShare 是原生 macOS 文件分享工具。选择文件或文件夹后，手机、平板和电脑只需打开链接或扫描二维码，就能在浏览器中查看内容；需要跨网络访问时，可以接入自托管的 LocalShare Server。</p>

<ZoomImage compact src="./images/screenshot-main-page.png" alt="LocalShare 主界面，显示文件分享和文本传递入口" />

## 选择使用方式

<div class="feature-grid">
  <a class="feature-card" href="./client/getting-started">
    <h3>局域网分享</h3>
    <p>无需部署服务。Mac 直接提供访问地址和二维码，适合同一 Wi-Fi 下快速查看文件或传递文本。</p>
  </a>
  <a class="feature-card" href="./server/">
    <h3>远程浏览器分享</h3>
    <p>部署自托管 Server 后，Client 主动建立连接，让不同网络中的浏览器只读访问当前分享。</p>
  </a>
</div>

## 工作方式

局域网模式下，LocalShare Client 本身就是文件服务器，内容从 Mac 直接发送到访问者的浏览器。

<div class="flow">浏览器  ── 同一局域网 ──▶  LocalShare Client  ──▶  Mac 上的文件</div>

远程模式下，Client 主动连接 LocalShare Server。Server 只转发浏览器请求与文件流，不保存分享内容，也不需要向公网暴露 Mac 的本地端口。

<div class="flow">远程浏览器  ──▶  LocalShare Server  ◀── WebSocket ──  LocalShare Client</div>

::: info 远程访问始终只读
通过 LocalShare Server 访问时，不开放访客上传和浏览器向 Mac 发送文本的能力。本地局域网分享仍可按需启用这些功能。
:::

## 主要能力

- 分享单个文件、文件夹或多个混合项目
- 浏览 HTML、PDF、视频与图片，并预览 Markdown、JSON 和 CSV
- 在 Mac 与局域网浏览器之间双向传递文本
- 可选访客上传、在线访客显示和命令行分享
- 通过自托管 Server 提供纯浏览器远程只读访问

## 从这里开始

第一次使用请阅读[快速开始](./client/getting-started)。如果准备跨网络分享，请先了解 [LocalShare Server](./server/)。
