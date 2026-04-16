---
allowed-tools: [Bash, Read, Grep, Glob]
description: "切分支 → 提交未提交改动 → 推送 → 创建 PR 一条龙"
argument-hint: "[可选：PR 标题或分支名提示，如 \"fix archive border\"]"
---

# /ship-pr — 一键切分支、提交、推送、建 PR

## 用户意图
把当前工作区未提交的改动（已修改 + 未跟踪）放到一个新分支上，生成一个语义化 commit，推送到 origin，并用 `gh` 开一个 PR。**不在 main/master 上直接提交**。

可选参数 `$ARGUMENTS`：作为分支命名和 PR 标题的语义提示。未提供时，基于 diff 内容自动推断。

## 执行流程

### Step 1 — 前置检查（并行）
- `git status --short`（**不要**加 `-uall`）
- `git diff`（已修改）
- `git diff --staged`（已暂存）
- `git branch --show-current`
- `git log --oneline -10`（学习项目的 commit 风格）
- `git remote -v`（确认 origin 存在）

### Step 2 — 安全校验
- 如果工作区**完全干净**（无 modified、无 untracked）：直接告诉用户没东西可提交，退出。
- 如果当前已经不在 `main` / `master` 上：询问用户是复用当前分支还是再切一个新分支。默认复用当前分支。
- 检查 untracked 文件里是否有敏感文件（`.env`、`*.key`、`*.pem`、`credentials*`、`GeneratedSecrets.swift` 等）。发现就**列出来并等用户确认**，不要默默 `git add`。

### Step 3 — 分支命名
从 main/master 切新分支时遵循：
- 前缀根据改动内容选择：`fix/` `feat/` `refactor/` `docs/` `chore/` `test/`
- kebab-case，≤50 字符
- 如果 `$ARGUMENTS` 有内容，基于它生成；否则读 diff 推断
- 例子：`fix/archive-calendar-border`、`feat/voice-transcript-cache`

切分支命令：`git checkout -b <branch-name>`（从当前 main/master 切出）。
如果已经在 feature 分支上，跳过切分支。

### Step 4 — 暂存与提交
- **逐个按文件名** `git add <file>`，不要用 `git add -A` / `git add .`（防止误加敏感文件）
- 跳过 Step 2 中标记为敏感的文件，除非用户明确同意
- 提交信息规范（参考项目 commit 历史的风格，比如 DayPage 项目常见 `fix: [P2][US-010] ...` 这种格式）：
  - 首行 ≤72 字符，祈使句，英文小写起头
  - 不要包含 `Generated with Claude Code` / `Co-Authored-By: Claude` 之类的水印
  - 用 HEREDOC 传递：

```bash
git commit -m "$(cat <<'EOF'
<type>: <concise subject>

<可选 body：解释为什么，不要复述 what>
EOF
)"
```

- 如果 pre-commit hook 失败：**不要** `--no-verify`。修复 hook 报的问题后，重新 `git add` 并**新建一个 commit**（绝对不要 `--amend`）。

### Step 5 — 推送
- `git push -u origin <branch-name>`
- 如果 push 失败（权限 / 分支保护），把报错原样展示，停下问用户。

### Step 6 — 创建 PR
用 `gh pr create`。**必须用 HEREDOC** 传 body：

```bash
gh pr create --title "<短标题 ≤70 字符>" --body "$(cat <<'EOF'
## Summary
- <1-3 条要点，说清这个 PR 做了什么 & 为什么>

## Test plan
- [ ] <具体的验证步骤>
- [ ] <边界情况>
EOF
)"
```

PR 标题规范：
- 与 commit 首行一致或更精炼
- 如果项目有 `[P2][US-010]` 这种标签约定（看 `git log` 判断），保留

### Step 7 — 收尾
把 `gh pr create` 返回的 PR URL 贴给用户，并跑一次 `git status` 确认工作区干净。

## 红线（不要做）
- ❌ 在 `main` / `master` 上直接 commit
- ❌ `git add -A` / `git add .`（用具体文件名）
- ❌ `--no-verify` 跳 hook
- ❌ `git commit --amend` 修复 hook 失败（应该新建 commit）
- ❌ `git push --force`（除非用户明确要求）
- ❌ 在 commit / PR 里放 Claude 水印
- ❌ 未问过用户就提交 `.env` / secrets / 大二进制

## 边界情况
- **已有 PR**：`gh pr view` 检测到当前分支已有开放 PR → 问用户是追加 commit 还是放弃
- **无 gh auth**：`gh auth status` 失败 → 提示用户运行 `! gh auth login`（用 `!` 前缀让命令在当前会话里执行）
- **远端不是 github**：`git remote -v` 不是 github.com → 跳过 `gh`，只推送，提示用户手动建 PR
- **冲突分支名**：本地或 origin 已存在同名分支 → 加 `-2`、`-3` 后缀

$ARGUMENTS
