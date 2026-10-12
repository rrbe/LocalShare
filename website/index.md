---
title: LocalShare 文档
description: 通过局域网、默认公共服务或自托管 Server，把 Mac 上的文件和文本分享到浏览器。
---

<script setup>
import mainScreenshot from "./images/screenshot-main-page.png"
</script>

# 从 Mac 分享到任何浏览器

<p class="doc-lead">LocalShare 是原生 macOS 文件分享工具。选择文件或文件夹后，手机、平板和电脑只需打开链接或扫描二维码，就能在浏览器中查看内容。跨网络分享可以使用 App 内置默认服务，也可以连接自己的中继服务器。</p>

<ZoomImage compact :src="mainScreenshot" alt="LocalShare 主界面，显示文件分享和文本传递入口" />

## 选择使用方式

<div class="feature-grid">
  <a class="feature-card" href="./client/getting-started">
    <h3>局域网分享</h3>
    <p>无需部署服务。Mac 直接提供访问地址和二维码，适合同一 Wi-Fi 下快速查看文件或传递文本。</p>
  </a>
  <a class="feature-card" href="./server/connect-client">
    <h3>远程浏览器分享</h3>
    <p>在分享页连接默认服务，将远程链接发给接收者。也可以在设置中换成自托管服务器。</p>
  </a>
</div>

## 工作方式

局域网模式下，LocalShare Client 本身就是文件服务器，内容从 Mac 直接发送到访问者的浏览器。

<div class="flow">浏览器  ── 同一局域网 ──▶  LocalShare Client  ──▶  Mac 上的文件</div>

远程模式下，Client 主动连接 LocalShare Server。Server 只转发浏览器请求与文件流，不保存分享内容，也不需要向公网暴露 Mac 的本地端口。

<div class="flow">远程浏览器  ──▶  LocalShare Server  ◀── WebSocket ──  LocalShare Client</div>

::: info 互联网访问范围
远程文件只读，文本支持读取和独立的可选接收。局域网权限不受影响，Mac 需在线，中继可读取内容。
:::

## 主要能力

- 分享单个文件、文件夹或多个混合项目
- 浏览 HTML、PDF、视频与图片，并预览 Markdown、JSON 和 CSV
- 在 Mac 与局域网浏览器之间双向传递文本
- 可选访客上传、在线访客显示和命令行分享
- 通过默认服务或自托管 Server 提供浏览器文件和文本分享

## 从这里开始

第一次使用请阅读[快速开始](./client/getting-started)。跨网络访问请阅读[远程分享](./server/connect-client)；准备自托管时，从[安装与部署](./server/deployment)选择适合的方案。
