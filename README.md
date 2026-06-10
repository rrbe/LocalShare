# LocalShare（局域网文件分享）

一个 macOS 小工具，启动一个静态文件托管服务，分享你电脑上的特定文件/文件夹，在同一个局域网下的其他设备中访问。

<p align="left">
  <img src="screenshot.png" alt="LocalShare 界面截图" width="380">
</p>

## 功能

- 二维码分享，相机 app 扫一下浏览器中打开
- 支持 html\pdf\视频\图片 等
- 支持命令行 localshare 命令启动 GUI，或 headless 模式在终端显示链接和二维码

## 为什么有这个 app

- iPhone 不支持 html 文件直接在手机 Safari 中打开，需要托管到静态文件服务器才能预览
- 如果你并不想把文件通过 AirDrop/LocalSend 传到手机，只是想在手机预览
- 想同时浏览多个文件
- 分享文件给局域网内的其他人使用

## 使用

1. 打开 app，拖拽文件到 app 窗口，或手动点「选择文件夹/单个文件」。
2. 手机连上**与电脑相同的 WiFi**，用相机扫描窗口里的二维码。
3. 首次启动若系统弹出防火墙提示，点「允许」。

二维码地址形如 `http://192.168.x.x:8080/?t=随机令牌`：链接里带一次性令牌，扫码者无感进入，单纯知道 IP:端口 的人无法访问。

## 终端用法

在「设置 → 命令行工具」里点「安装」，之后可以在终端一键分享：

```bash
localshare a.html b.pdf        # 唤起 LocalShare 窗口分享这些文件
localshare ~/Documents/报告    # 文件夹同理，可混合多选
localshare --headless ./dist   # 不开窗口，直接在终端打印链接和二维码（Ctrl-C 停止）
```

## 下载

https://github.com/rrbe/LocalShare/releases

## 注意事项

ad-hoc 签名，**打开**可能被 Gatekeeper 拦截（提示「已损坏」或「无法打开」）

- 可以在「系统设置 → 隐私与安全性 → 安全性」中找到拦截提示，点「仍要打开」；
- 或在终端执行下面这条去掉隔离属性，之后正常打开 app 即可

```bash
xattr -dr com.apple.quarantine /Applications/LocalShare.app
```
