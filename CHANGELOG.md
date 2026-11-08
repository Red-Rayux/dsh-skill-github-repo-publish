# Changelog

## 1.0.0 — 2026-11-08

- 首个公开版本：DSH 用户级技能 `github-repo-publish`。
- `publish-github.ps1`：泄漏扫描 → BOM/CRLF 归一化 → git init/commit → 创建仓库（缺失时）→ 推送 → description/topics → 可选 Release + 源码 zip → 校验（remote HEAD、contents API blob sha）→ 输出单个 JSON。
- `scan-secrets.ps1`：令牌/私钥/云密钥（ERROR）+ 内网 IP/个人路径/邮箱（WARN）扫描，命中文本 redact。
- `ensure-gh.ps1`：查找或下载便携 GitHub CLI（无需管理员，缓存复用）。
- 内修 Windows PowerShell 5.1 兼容性问题：泛型 List 数组包装、native stderr 与 `$ErrorActionPreference='Stop'` 的误抛、git 命令的工作目录（统一 `-C <源目录>`）。
