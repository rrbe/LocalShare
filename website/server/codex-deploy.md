---
title: 让 Codex 部署
description: 复制一段提示，让 Codex 按 LocalShare 官方 Skill 部署并验证 Server。
---

# 让 Codex 部署

可以把下面这段话发给 Codex，并指定目标 Linux 服务器。Codex 会先检查环境，给出适合的部署方案，经过你确认后执行。

<CopyPrompt text="请帮我在指定的 Linux 服务器部署 LocalShare Server。先读取官方部署 Skill：https://raw.githubusercontent.com/rrbe/LocalShare/master/.agents/skills/localshare-server-deploy/SKILL.md。先做只读检查，确认系统架构、端口、公开 IP、已有 Nginx、证书续期和 CDN，按只有 IP、已有 Nginx + Let’s Encrypt、已有 CDN 三种环境说明适用方案；域名可选，公网使用 HTTPS/WSS。展示拟执行的配置和对现有服务的影响，说明默认使用配对码，也可用 --registration 开放自动注册，等我确认方案后再执行。部署时校验二进制，保留已有 state.json，验证 systemd、公开 healthz、证书自动续期及 WebSocket。采用配对码时生成一次性配对码；采用自动注册时告诉我配对码可留空，并给出 Client 应填的服务器地址。若只需方案或本地预览，请停在该范围内。" />

三种流程的手动步骤见[安装与部署](./deployment)。只使用 IP 时申请 IP 证书；已有 Nginx 时复用代理和续期；已有 CDN 时确认中继直连还是经过 CDN。

## 为什么使用 Skill

Skill 适合描述可重复执行的操作流程。LocalShare 的 Skill 固化了以下边界：

- 只在明确的 Linux 主机上部署，不自行选择远程服务器
- 先展示具体方案，确认后再修改服务器
- 从 GitHub Release 下载并校验二进制；尚无 Server 资产时说明源码构建方式
- 保留 `/var/lib/localshare/state.json`，不让升级破坏已配对设备
- 检查已有端口和 systemd 服务，避免直接覆盖未知配置
- 启动后验证 `/healthz`，最后才生成一次性 Enrollment Key

完整内容可以在仓库中查看：[`localshare-server-deploy/SKILL.md`](https://github.com/rrbe/LocalShare/blob/master/.agents/skills/localshare-server-deploy/SKILL.md)。

## 是否需要先安装 Skill

不需要。上面的提示会让 Codex 直接读取官方 `SKILL.md`，适合只部署一次的用户。

如果经常管理 LocalShare Server，可以把 Skill 安装到 Codex。Codex 官方提供的 `$skill-installer` 可以从其他仓库下载 Skill；社区常用的 [skills CLI](https://skills.sh/) 也支持从 GitHub 路径安装：

```bash
npx skills add \
  https://github.com/rrbe/LocalShare/tree/master/.agents/skills/localshare-server-deploy \
  --global --agent codex --yes
```

安装后可以直接告诉 Codex：

```text
使用 $localshare-server-deploy 在当前 Linux 服务器上完成部署。
```

## `llms.txt` 的作用

[`llms.txt`](/llms.txt) 是文档索引，不是安装脚本。它帮助模型快速找到 Client、Server、部署文档和 Skill，但不会让 Codex 自动获得执行流程或服务器权限。

因此 LocalShare 同时提供：

| 入口 | 用途 |
| --- | --- |
| 复制给 Codex 的提示 | 一次性部署，用户无需预先安装任何内容 |
| `SKILL.md` | 可复用、可安装的部署流程 |
| `llms.txt` | 帮助模型发现相关文档和 Skill |

相关规范：[Codex Skills](https://developers.openai.com/codex/skills/)、[Agent Skills specification](https://agentskills.io/specification)、[`llms.txt` proposal](https://llmstxt.org/)。
