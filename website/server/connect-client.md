---
title: 连接 LocalShare Client
description: 使用 Enrollment Key 配对 Client，并开始远程只读分享。
---

# 连接 LocalShare Client

Server 部署完成后，只需用 Enrollment Key 完成一次设备配对。之后 Client 会使用保存在 macOS Keychain 中的设备凭据重新连接。

## 开始之前

确认以下条件：

- `curl <server-address>/healthz` 返回 200
- Server address 是不含额外路径和 query 的基地址
- 已运行 `localshare-server key create` 并取得尚未使用的 Enrollment Key
- LocalShare Client 已选择要分享的文件或文件夹

## 1. 配置远程访问

在 LocalShare Client 中打开“设置 → 远程访问”，填写：

| 字段 | 内容 |
| --- | --- |
| Server address | Server 的公开基地址，例如 `https://share.example.com:18443` |
| Enrollment key | Server 生成的一次性配对 key |

保存设置。配对成功后，Device Token 会存入 macOS Keychain，Enrollment Key 不会持久化。

## 2. 发布当前分享

回到文件分享票据并点击 `Connect`。连接成功后，票据会显示 Server 生成的远程访问地址。

<div class="flow">选择分享内容  ──▶  Connect  ──▶  获得远程地址  ──▶  发给访问者</div>

访问者只需在浏览器中打开该地址。请求会经过 Server 转发到当前 Client，文件本身不会保存在 Server 上。

## 3. 后续连接

设备配对只需要进行一次。Client 重启后不会自动公开分享；选择文件或文件夹，再点击 `Connect`，即可使用 Keychain 中的凭据重新连接。

- `Disconnect`：断开当前长连接，使当前远程地址失效，但保留设备配对
- `Forget Device`：删除 Keychain 中的 Device Token，下次需要新的 Enrollment Key
- 更换分享内容：立即轮换本地访问令牌，远程分享也会使用新的身份

::: warning 远程访问范围
远程地址只开放文件和目录的只读浏览，不支持访客上传或 Text Transfer。不要把 Enrollment Key、Device Token 或 Share Token 公开发送给无关人员。
:::

## 排查连接问题

按以下顺序检查：

1. `curl <server-address>/healthz` 是否返回 200。
2. Server address 是否为正确的 HTTP 或 HTTPS 基地址。
3. Enrollment Key 是否已被使用；如果是，重新创建一个 key。
4. `device list` 是否能看到已经配对的设备。
5. Client 是否已选择分享内容；空分享时 `Connect` 不可用。
6. Client 状态是否为 `Connected`，票据上是否出现远程 URL。
7. 当前 URL 是否仍对应本次连接；断开连接、切换内容或 Server 重启后，旧 Share Token 会失效。
