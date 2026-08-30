# LocalShare —— 共享 Mac 文件，扫码在手机浏览器里查看/保存

简体中文 | [English](README.md)

一个 macOS 小工具，在本机和手机等设备之间通过 WiFi 互通文件和文本，也支持可选的纯浏览器跨网络分享，对端无须安装客户端。

- 选中文件或文件夹，相机扫描出现的二维码，或直接打开链接，在手机浏览器里浏览这些文件（HTML、PDF、Markdown、图片……）
- 支持双向传送文本，编辑文字通过二维码分享后传输，并可从手机端发送文本回 Mac

<table>
  <tr>
    <td align="center"><img src="website/images/screenshot-main-page.png" alt="主界面" width="260"><br>主界面</td>
    <td align="center"><img src="website/images/screenshot-share-file.png" alt="分享文件" width="260"><br>分享文件</td>
    <td align="center"><img src="website/images/screenshot-share-text.png" alt="传递文本" width="260"><br>传递文本</td>
  </tr>
</table>

## 功能

- 二维码分享或直接打开链接分享文件、文本
- 支持 HTML / PDF / 视频 / 图片，Markdown / JSON / CSV 预览
- 支持分享后，由对端反向传输文件、文本
- 显示当前在线访客
- 命令行 `localshare` 命令：唤起窗口分享，或 `--headless` 在终端显示链接和二维码
- 可选通过自托管 LocalShare Server 远程访问浏览器；远程分享只读

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

### 远程浏览器分享

运行自包含的 [`localshare-server`](server/README.md)，生成一次性 Enrollment Key，在「设置」里填写 Server 地址和 key。配对后设备凭据会保存到 Keychain；正在分享时只需点击 Connect/Disconnect，对端设备只需浏览器。详见[远程分享计划](docs/REMOTE_SHARING_PLAN.md)。

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

## 协议

MIT —— 见 [LICENSE](LICENSE)。

## 参考项目

本项目受到如下项目的启发

- [localsend](https://github.com/localsend/localsend)
- [dufs](https://github.com/sigoden/dufs)
