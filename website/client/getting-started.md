---
title: 快速开始
description: 安装 LocalShare Client，并通过二维码或链接开始第一次局域网分享。
---

# 快速开始

LocalShare Client 运行在 macOS 13 或更高版本。访问者不需要安装应用，只需要与 Mac 位于同一局域网并使用现代浏览器。

## 1. 安装 Client

从 [GitHub Releases](https://github.com/rrbe/LocalShare/releases) 下载最新版 LocalShare，将应用移动到“应用程序”目录后打开。

如果 Gatekeeper 提示应用“已损坏”或“无法打开”，可以在“系统设置 → 隐私与安全性”中选择仍要打开，或者执行：

```bash
xattr -dr com.apple.quarantine /Applications/LocalShare.app
```

首次分享时，macOS 可能询问是否允许接收传入网络连接。请选择“允许”。

## 2. 选择内容

在主窗口中选择文件或文件夹。LocalShare 会启动本地只读服务，并生成访问链接和二维码。

你也可以混合选择多个文件和文件夹。浏览器会看到一个虚拟根目录，但不能访问所选项目之外的文件。

## 3. 在浏览器中打开

让手机扫描二维码，或者把链接发送给同一 Wi-Fi 下的其他设备。链接中的随机令牌负责访问验证；浏览器首次验证后会跳转到不含令牌的干净地址。

::: warning 公共网络
局域网分享使用 HTTP，不提供传输加密。机场、咖啡厅等不可信网络中不建议分享敏感内容；跨网络访问建议使用配置了 HTTPS 的 LocalShare Server。
:::

## 命令行使用

在“设置 → 命令行工具”中安装 `localshare` 后，可以直接从终端发起分享：

```bash
localshare a.html b.pdf
localshare ~/Documents/报告
localshare --headless ./dist
```

前两条命令会唤起 LocalShare 窗口，`--headless` 会直接在终端输出链接和二维码，按 `Ctrl-C` 停止。

## 下一步

- 了解[文件分享](./file-sharing)支持的内容和访问规则
- 使用[文本传递](./text-transfer)在 Mac 与手机之间复制文字
- 需要远程访问时，部署 [LocalShare Server](../server/)
