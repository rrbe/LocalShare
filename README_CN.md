# LocalShare —— 共享 Mac 文件，扫码在手机浏览器里查看/保存

简体中文 | [English](README.md)

一个 macOS 小工具，在本机和手机等设备之间通过 WiFi 互通文件和文本，对端使用浏览器，无须安装客户端。

- 选中文件或文件夹，相机扫描出现的二维码，或直接打开链接，在手机浏览器里浏览这些文件（HTML、PDF、Markdown、图片……）
- 支持双向传送文本，编辑文字通过二维码分享后传输，并可从手机端发送文本回 Mac

<table>
  <tr>
    <td align="center"><img src="docs/images/screenshot-main-page.png" alt="主界面" width="260"><br>主界面</td>
    <td align="center"><img src="docs/images/screenshot-share-file.png" alt="分享文件" width="260"><br>分享文件</td>
    <td align="center"><img src="docs/images/screenshot-share-text.png" alt="传递文本" width="260"><br>传递文本</td>
  </tr>
</table>

## 功能

- 二维码分享或直接打开链接分享文件、文本
- 支持 HTML / PDF / 视频 / 图片，Markdown / JSON / CSV 预览
- 支持分享后，由对端反向传输文件、文本
- 显示当前在线访客
- 命令行 `localshare` 命令：唤起窗口分享，或 `--headless` 在终端显示链接和二维码

## 为什么有这个 app

- 避免 AirDrop 的不稳定，或对端并非苹果设备
- iPhone 不支持 html 文件直接在手机 Safari 中打开，不便预览你 Vibe Coding 的网页
- 不需要配置 python 启动 `python3 -m http.server`
- 不需要安装 LocalSend 等客户端
- 可以只预览，不需要传递文件到手机存储
- 快速传递文本，避免 handoff 不稳定

## GUI 使用

扫描二维码或通过局域网连接地址打开，首次启动若系统弹出防火墙提示，点「允许」。

二维码地址形如 `http://192.168.x.x:8080/?t=随机令牌`：链接里带一次性令牌，扫码者无感进入，单纯知道 IP:端口 的人无法访问。

> ⚠️ 传输是明文 HTTP（没有加密）。机场咖啡厅等公共网络下最好不要使用。

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

## 常见问题

**怎么在 iPhone 上打开本地 HTML 文件？**
iPhone Safari 不能直接打开 `file://` 的 HTML。用 LocalShare 分享这个文件（或它所在的文件夹），扫码即可——Safari 从本地服务打开它，链接、CSS、图片都能正常解析。

**对方设备需要装什么吗？**
不用。有相机和浏览器就行——iPhone、iPad、安卓、另一台 Mac 都可以。只有分享方的 Mac 跑 LocalShare。

**需要联网吗？**
不需要。一切都在本地网络里（Mac 和手机连同一个 WiFi 即可），不经过云端。

**安全吗？**
链接带一次性令牌，光知道 IP:端口 进不来。传输是明文 HTTP，在家里 / 公司网络下没问题——别在公共 WiFi 分享敏感文件，需要时开「仅当前网络可见」收窄暴露面。

**手机能把文件传回 Mac 吗？**
可以。开启访客上传后（默认关闭），手机就能把照片、文档传进被分享的文件夹。

**能把链接或一段文字发到手机上吗？**
可以。在 Mac 上粘好文字，照样分享出去——手机在浏览器里打开，带一个「复制」按钮。也可以开启文本收件箱（默认关闭），让手机把文本发回 Mac。

**Windows 或 Linux 能用吗？**
LocalShare 只支持 macOS。其它平台上 dufs 或 LocalSend 能覆盖类似需求。

## 协议

MIT —— 见 [LICENSE](LICENSE)。

## 参考项目

本项目受到如下项目的启发

- [localsend](https://github.com/localsend/localsend)
- [dufs](https://github.com/sigoden/dufs)
