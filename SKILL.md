---
name: github-repo-publish
description: 把本地文件夹整理并一键发布到 GitHub 仓库（发布前泄密/PII 扫描、BOM/git 归一化、创建仓库、commit & push、描述/topics、可选 Release+zip、发布后校验），基于一次真实发布的踩坑经验沉淀。适用于用户说"上传/发布/推到我的 GitHub"、"整理成仓库/个人项目"、"开源这个文件夹"。
whenToUse: 用户要求把本地项目/文件夹发布到 GitHub；创建 GitHub 仓库并推送；整理开源仓库；发布 Release/源码包；或需要检查待发布项目是否含密钥/隐私信息。触发词：GitHub、上传、发布、仓库、开源、推到 github、个人项目、release。
---

# github-repo-publish

**目标：用 1–2 条命令完成"整理 + 发布 + 验收"，不要重新调研 GitHub API/gh 行为。**
本 skill 目录：`%USERPROFILE%\.dsh\skills\github-repo-publish`（脚本在其 `scripts\` 下）。PowerShell 里先设一次 `$skill = "$env:USERPROFILE\.dsh\skills\github-repo-publish"`，下文统一用 `"$skill\scripts\..."` 调用；若把本 repo 克隆/复制到别处，把 `$skill` 指向实际目录即可。

## 总流程

| 步骤 | 做什么 | 消耗 |
|---|---|---|
| 0 | 收集输入（一次问清，见下） | 0–1 次提问 |
| 1 | 干跑：`-DryRun`（扫描泄漏+BOM+git 状态+认证检查，无副作用） | 1 条命令 |
| 2 | 按需清理项目（扫描报错/公开化清单） | 少量编辑 |
| 3 | 正式发布（脚本内部完成创建/提交/推送/topics/Release/校验） | 1 条命令 |
| 4 | 把脚本输出的 JSON 摘要贴给用户（不要手工再验一遍） | 0 |

## 0) 先要到的输入（缺的只问一次）

- `SourceDir`：要发布的本地文件夹绝对路径（可以是新目录，脚本会 `git init`/提交）。
- `Owner`：GitHub 账户（如 `Red-Rayux`）；从用户话里取，不要再问。
- `Repo`：仓库名；没指定就由你从项目名/README 取一个 kebab-case 名字，并告知用户。
- `Visibility`：默认 `public`（"个人项目/开源"语境）；用户说私有才 `private`。
- 可选：`Description`、`Topics`（逗号分隔）、`-Release -ReleaseTag vX.Y.Z`。

**认证**：脚本自动找 `GH_TOKEN`/`GITHUB_TOKEN`/`gh auth token`/`-Token`。若都没有，只问一次，二选一（不要来回拉扯）：
- 推荐：用户在普通终端执行（gh 缺失时脚本会自动下载便携版）：
  `"$skill\scripts\ensure-gh.ps1"` 找到 gh.exe 后运行 `gh auth login --hostname github.com --git-protocol https`；
- 或用户给一个 classic PAT：`repo` 权限（若必须推送 `.github/workflows/` 再加 `workflow`）。用户贴了 PAT 就直接 `-Token` 用，**用完后必须提醒轮换**；绝不写入文件、remote URL、git config。

## 1) 干跑（无副作用，先看计划）

```powershell
$skill = "$env:USERPROFILE\.dsh\skills\github-repo-publish"
& "$skill\scripts\publish-github.ps1" `
  -SourceDir 'D:\path\to\project' -Owner 'Red-Rayux' -Repo 'my-project' `
  -Description '...' -Topics 'tag1,tag2' -DryRun
```

- 返回 JSON：`scan.errors/warnings`、`trackedFiles`、`auth.ok/login`、`repoExists`、`plan`。
- `scan.errors` 非空=发现密钥/私钥，**停止发布并要求用户处理**；`scan.warnings`=内网 IP/个人路径/邮箱，公开仓库建议先清理（按公开化清单）。
- 只读这份 JSON 即可，不要自己去逐文件 grep（省 token）。

## 2) 公开发布前的整理清单（只在项目尚未整理时做）

| 项 | 要求 |
|---|---|
| README | 公开受众能看懂：是什么/为什么/安装/用法/限制；英文或中英双语更通用 |
| LICENSE | 默认 MIT（版权 `2026 <Owner>`），除非用户指定 |
| CHANGELOG.md | 至少一条当前版本记录 |
| .gitignore | 依赖/构建产物/运行时状态/日志/真实配置（`config.json`）/证据与调研目录 |
| .gitattributes | `* text=auto eol=lf`（避免 Windows CRLF 造成无意义 diff） |
| 配置 | 提交 `config.example.json`（占位符），**不提交真实配置**；文档用占位路径/域名 |
| 包元数据 | 若有 package.json：去掉 `private`（公开时）、补 `license/repository/homepage/bugs/keywords/engines` |
| 私有内容 | 删除/移出 `research/`、`evidence/`、`state/`、日志、spike 输出、内部截图、测试产物 |
| 去个人化 | 内网/私网 IP、Tailscale/CGNAT IP、个人 home 路径（`C:\Users\xxx`、`/home/xxx`）、邮箱、真实主机名、SSH key 文件名 → 占位符或写进 `.gitignore` |
| CI | 若 PAT 无 `workflow` scope：CI 放 `docs/ci.yml.example`（不要放 `.github/workflows/`），并说明如何启用 |
| BOM | 脚本会自动去掉非 `.ps1` 文本文件的 UTF-8 BOM；`.ps1` 保留 BOM（PS 5.1 中文需要） |

## 3) 正式发布

```powershell
# 无 token 时先设环境变量（推荐）：
$env:GH_TOKEN = '<PAT>'   # 或 -Token '<PAT>'
$skill = "$env:USERPROFILE\.dsh\skills\github-repo-publish"
& "$skill\scripts\publish-github.ps1" `
  -SourceDir 'D:\path\to\project' -Owner 'Red-Rayux' -Repo 'my-project' `
  -Description '一句话介绍' -Topics 'dsh-plugin,jetson,ros1' `
  -Release -ReleaseTag v1.0.0 -ReleaseNotesFile 'D:\path\to\release-notes.md'
```

- 仓库已存在时加 `-Update` 才会推送（防止误覆盖）。
- 需要构建产物（如 `dist/`）时加 `-PrebuildCommand 'node build.mjs'`，脚本会先构建再提交。
- 想要 zip 源码包：加 `-Release`，脚本用 `git archive` 生成 `Repo-tag.zip` 并作为 Release 资产上传。
- 全部成功输出 `{"ok":true,...}`：`url/head/remoteHead/headMatch/blobMatch/release`；失败输出 `{"ok":false,"step":"auth|push|release|secrets|create|...","error":..,"hints":[..]}`——按 hints 处理，不要盲目重试。

## 4) 常见失败 → 处理（都是踩过的坑）

| 现象 | 原因 | 处理 |
|---|---|---|
| `step:"secrets"` | 扫到 PAT/私钥/云密钥 | 删除/改占位符后重跑；预览已做 redact，不会把密钥打进日志 |
| `missing required scope 'read:org'`（gh auth login） | PAT 缺 scope | 不要用 `gh auth login --with-token`；改为 `$env:GH_TOKEN=<PAT>` 或 `-Token` 直接调 API/推送 |
| push 报 `refusing to allow a Personal Access Token to create or update workflow` | PAT 无 `workflow` scope | 把 `.github/workflows/*` 移到 `docs/ci.yml.example`，或换带 `workflow` 的 token |
| `step:"repo-exists"` | 仓库已存在 | 确认后可 `-Update`；否则换 `-Repo` 名 |
| push 报 non-fast-forward | 远端有本地没有的提交 | 先手动 fetch/rebase；或换新仓库名（不要 force push 别人的历史） |
| `step:"release"` 已存在/标签冲突 | tag 建过；或 amend 后 tag 仍指向旧 commit | `gh release delete <tag> --cleanup-tag` 后重跑；先推送最终 commit 再建 release |
| 校验 raw.githubusercontent 看到的还是旧内容 | CDN 缓存 | 脚本已改用 contents API 的 blob sha 对比，**不要**再用 raw URL 判断是否推送成功 |
| GitHub 网页中文/BOM 首字符异常 | 文件带 BOM/CRLF | 脚本已处理；手动改文件后重跑脚本即可 |
| 账号不对（推到了别人仓库） | token 属于另一个账号 | 脚本会校验 `GET /user.login` 必须等于 `-Owner`，不一致会直接失败 |
| gh CLI 缺失 | Windows 常见 | 脚本自动下载便携版到 `%LOCALAPPDATA%\dsh-tools\gh`（无需管理员）；也可 `-ToolsDir` 指定缓存目录 |
| 删除测试仓库返回 403 | classic PAT 没有 `delete_repo` scope（`repo` 不够） | 不要建测试仓库（`-DryRun` 足够）；已经建了就先 PATCH 转 private 并告知用户手动删，或换带 `delete_repo` 的 token |
| `git warning: LF will be replaced by CRLF` 被当成错误 | PowerShell `$ErrorActionPreference=Stop` + 原生命令 `2>&1` 合并 stderr 会抛 NativeCommandError | 脚本内部已用安全捕获并给新仓库设 `core.autocrlf=false`；自写脚本时注意这个坑 |

## 5) Token 安全（硬规则）

- 只在进程内使用：`-Token` 或 `$env:GH_TOKEN`；**不写文件、不写 git remote URL、不写 git config**（推送用一次性 credential helper，失败才用一次性 URL）。
- 用户把 PAT 贴在对话里：用完提醒去 GitHub Settings → Developer settings 撤销/轮换；不要复述 token。
- 不要为了省事把 token 写进脚本、README、`.env` 并提交；泄露扫描会拦，但不要制造。

## 6) 脚本速查

| 脚本 | 作用 | 输出 |
|---|---|---|
| `scripts\ensure-gh.ps1 [-ToolsDir <dir>]` | 找/下载便携 gh CLI | stdout 一行 gh.exe 绝对路径 |
| `scripts\scan-secrets.ps1 -Path <dir> [-Json] [-NoExit]` | 发布前泄漏扫描（密钥=ERROR，隐私=WARN，命中文本 redact） | 文本或 JSON；默认退出码 0/1/2 |
| `scripts\publish-github.ps1 ...` | 一键发布（见上面参数） | 单个 JSON（成功/失败） |

`publish-github.ps1` 主要参数：`-SourceDir -Owner -Repo [-Description] [-Visibility public|private] [-Topics] [-Update] [-Release -ReleaseTag] [-PrebuildCommand] [-Branch main] [-Token] [-DryRun] [-SkipScan] [-SkipBomStrip] [-ToolsDir]`。

## 7) 不要做的事（省 token / 防事故）

- 不要为"确认 GitHub API 怎么用"重新读文档/搜索：本 skill + 脚本已经覆盖 create/push/topics/release/verify。
- 不要创建多余临时仓库做测试；`-DryRun` 足够验证 preflight。确实要端到端自测时：只建一次性仓库，且仅当 token 带 `delete_repo` scope 才建（否则无法删除，只能转 private 并请用户手动删）。
- 不要用 `git push --force` 推用户既有仓库；不要改用户全局 git config（脚本只设 repo-local identity）。
- 不要为了让 CI 生效去申请额外权限；默认走 `docs/ci.yml.example`。
- 不要重启用户应用、不要动用户其它仓库；失败时按 JSON 的 `hints` 处理并汇报。
- 发布完只汇报：仓库 URL、Release URL、commit、校验结果、需要用户注意的事（token 轮换 / CI 启用 / 私有配置未提交）。
