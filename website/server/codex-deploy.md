---
title: 让 Codex 部署
description: 复制一段提示，让 Codex 按 LocalShare 官方 Skill 部署并验证 Server。
---

# 让 Codex 部署

如果 Codex 正运行在目标 Linux 服务器上，可以把下面这段话直接发给它。Codex 会读取 LocalShare 官方部署 Skill，检查服务器环境，只在缺少必要信息或遇到已有部署时向你确认。

<CopyPrompt text="请在当前这台 Linux 服务器上部署 LocalShare Server；先读取并遵循官方部署 Skill：https://raw.githubusercontent.com/rrbe/LocalShare/master/.agents/skills/localshare-server-deploy/SKILL.md；检查系统架构、sudo、端口、公开地址、TLS 和已有服务，只在缺少必要信息、需要修改防火墙或可能覆盖现有部署时向我确认；完成二进制校验、systemd 配置和健康检查后，生成一个一次性 Enrollment Key，并汇总远程地址、服务状态和 Client 的下一步配置。" />

这段提示不会预设域名或证书路径。生产部署所需的公开地址、HTTPS 方式等信息无法从服务器可靠推断时，Codex 会继续询问。

## 为什么使用 Skill

Skill 适合描述可重复执行的操作流程。LocalShare 的 Skill 固化了以下边界：

- 只在明确的 Linux 主机上部署，不自行选择远程服务器
- 从 GitHub Release 下载与架构匹配的二进制并校验 SHA-256
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
