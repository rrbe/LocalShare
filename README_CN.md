# LocalShare（局域网文件分享）

简体中文 | [English](README.md)

一个 macOS 小工具，启动一个静态文件托管服务，分享你电脑上的特定文件/文件夹，在同一个局域网下的其他设备中访问。

<table>
  <tr>
    <td align="center"><img src="screenshot-main-page.png" alt="主界面" width="260"><br>主界面</td>
    <td align="center"><img src="screenshot-share-file.png" alt="分享文件" width="260"><br>分享文件</td>
    <td align="center"><img src="screenshot-share-text.png" alt="传递文本" width="260"><br>传递文本</td>
  </tr>
</table>

## 功能

- 二维码分享，相机 app 扫一下浏览器中打开
- 一次分享多个文件 / 文件夹
- 支持 HTML / PDF / 视频 / 图片，Markdown / JSON / CSV 在浏览器里直接预览
- 可选开启访客上传（默认只读），手机里的照片、文档能传回电脑
- 显示当前在线访客（能反查到就显示设备名，否则显示 IP 尾号）
- 可选「仅当前网络可见」：只在当前 WiFi 开放，电脑连着的其它网络访问不到
- 自动更新（发现新版会提示，确认后再装）
- 命令行 localshare：唤起窗口分享，或 --headless 在终端显示链接和二维码

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

> ⚠️ 传输是明文 HTTP（没有加密）。在家里 / 公司这种可信网络下没问题；但在咖啡馆、机场等公共 WiFi 下，同一网络的人有可能看到传输内容——别在这种网络分享敏感文件。需要时可在窗口里开「仅当前网络可见」收窄暴露面。

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

## 参考项目

本项目受到如下项目的启发

- [localsend](https://github.com/localsend/localsend)
- [dufs](https://github.com/sigoden/dufs)
