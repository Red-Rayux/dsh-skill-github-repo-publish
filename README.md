# github-repo-publish — a DeepSeek Harness skill

**English (short)**: A user-level [DeepSeek Harness](https://deepseek-harness.github.io/deepseek-harness/en/) skill that publishes a local folder to a GitHub repository in one command — leak/PII scan, git normalization, repo creation, commit & push, description/topics, optional Release + source zip, and post-publish verification. Written from a real publishing session, including the Windows/PowerShell pitfalls.

**中文**：把本地文件夹一键发布到 GitHub 的 DSH（DeepSeek Harness）**用户级技能**。agent 只需 1–2 条命令即可完成"整理 + 发布 + 验收"，并输出一个 JSON 作为唯一需要阅读的结果。

## 为什么值得用

- **一条命令**完成：泄漏扫描 → BOM/CRLF 归一化 → `git init/commit` → 创建仓库 → 推送 → description/topics → 可选 Release + 源码 zip → 校验（remote HEAD、contents API blob sha）。
- **发布前拦截泄密**：PAT/私钥/云密钥按 ERROR 阻塞，内网 IP/个人路径/邮箱按 WARNING 提示；命中内容自动 redact，不会把密钥打进日志。
- **token 不落盘**：只用 `GH_TOKEN` / `-Token` 进程内传递，推送用一次性 credential helper；不写 remote URL、不写 git config、不改全局 git 设置。
- **失败可读**：失败输出 `{"ok":false,"step":"auth|secrets|create|push|release|...","hints":[...]}`，按 hints 处理，不需要重新调研 GitHub API/gh 行为。

## 安装（DSH 技能目录）

把本仓库放到用户级技能根下（或克隆到该路径）：

```powershell
git clone https://github.com/Red-Rayux/dsh-skill-github-repo-publish.git `
  "$env:USERPROFILE\.dsh\skills\github-repo-publish"
```

DSH 会扫描 `~/.dsh/skills/<name>/SKILL.md`；技能目录被监听，新技能无需重启应用即可进入目录。之后任意对话里说：

> 用 github-repo-publish 技能把 `D:\path\to\project` 发布到我的 GitHub（Red-Rayux），仓库名 my-project，带 v1.0.0 release。

若你把仓库放在别处，可在对话/命令里把 `$skill` 指向实际目录。

## 使用

```powershell
$skill = "$env:USERPROFILE\.dsh\skills\github-repo-publish"

# 1) 干跑：扫描泄漏 + 检查认证 + 打印发布计划（无副作用）
& "$skill\scripts\publish-github.ps1" `
  -SourceDir 'D:\path\to\project' -Owner 'Red-Rayux' -Repo 'my-project' `
  -Description '一句话介绍' -Topics 'tag1,tag2' -DryRun

# 2) 正式发布（-Token 或先设 $env:GH_TOKEN；已存在的仓库加 -Update）
& "$skill\scripts\publish-github.ps1" `
  -SourceDir 'D:\path\to\project' -Owner 'Red-Rayux' -Repo 'my-project' `
  -Description '一句话介绍' -Topics 'tag1,tag2' `
  -Release -ReleaseTag v1.0.0
```

主要参数：`-SourceDir -Owner -Repo [-Description] [-Visibility public|private] [-Topics] [-Update] [-Release -ReleaseTag] [-PrebuildCommand] [-Branch main] [-Token] [-DryRun] [-SkipScan] [-SkipBomStrip] [-ToolsDir]`。

## 脚本

| 脚本 | 作用 |
|---|---|
| `scripts\publish-github.ps1` | 一键发布主入口；成功/失败都输出单个 JSON |
| `scripts\scan-secrets.ps1` | 发布前泄漏/PII 扫描（可独立使用；默认退出码 0/1/2） |
| `scripts\ensure-gh.ps1` | 查找或下载便携 GitHub CLI（无需管理员，缓存复用） |

## 安全模型

- `scan-secrets.ps1` 的命中预览会替换为 `<redacted>`，避免把密钥写入日志；
- 账号校验：token 的 `GET /user.login` 必须等于 `-Owner`，防止推错账号；
- 不 `git push --force` 用户既有仓库；只设置 **repo-local** git identity，不动全局配置；
- 用户把 PAT 贴在对话里时：用完提醒轮换；本技能不持久化 token。

## 已验证（真实端到端）

- 一次性仓库：创建 + push + topics + Release v0.0.1 + zip → `headMatch=true`、`blobMatch=true`；再次 `-Update` 幂等通过；
- 泄漏门禁：伪造 GitHub token / AWS key → `step:"secrets"` 阻塞，输出 redact；
- `-DryRun` 对非 git 文件夹不产生 `.git` 等副作用；
- 兼容 Windows PowerShell 5.1 的 3 个坑已内修：`@(List[object])` → `.ToArray()`、native stderr 与 `$ErrorActionPreference='Stop'` 的误抛、git 命令必须 `-C <源目录>`。

## 环境要求

- Windows PowerShell 5.1+（或 pwsh 7）；`git`；
- 首次运行需联网下载便携 gh CLI（约 15 MB，缓存在 `%LOCALAPPDATA%\dsh-tools\gh`）；
- GitHub 认证：`GH_TOKEN` / `GITHUB_TOKEN` 环境变量、`-Token`，或已登录的 `gh`。

## 目录结构

```
.
├── SKILL.md              # 技能正文（DSH 加载入口）
├── scripts/
│   ├── publish-github.ps1
│   ├── scan-secrets.ps1
│   └── ensure-gh.ps1
├── README.md
├── CHANGELOG.md
└── LICENSE
```

## License

[MIT](LICENSE) © 2026 Red-Rayux
