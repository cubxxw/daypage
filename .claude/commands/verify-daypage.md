---
allowed-tools: [Skill, Bash, Read, Write, Edit, Glob, Grep]
description: "DayPage 端到端自动验证：跑 PRD User Story + 自动建 issue"
argument-hint: "[--wave w1|w2|w3|w4|w5|all] [--smoke] [--dry-run-issues] [--device \"iPhone 15\"]"
---

# /verify-daypage — 跑端到端验证 + 自动建 issue

## 意图

主理人想一键跑 DayPage 的端到端验证（UI + 存储 + AI），发现问题自动在 GitHub 建 issue。

## 动作

**立刻调用 Skill 工具**，`skill: "verify-daypage"`，把 `$ARGUMENTS` 作为 args 透传。

不要在这里实现任何验证逻辑——所有脚本、流程、issue 模板都在 skill 里。这个 command 只是个快捷入口。

### 默认参数

如果用户没传参数，按 `--wave all --smoke` 跑（每个 Wave 最关键的 1 个 story，~15 分钟）。

### 参数转发

把用户原样的 `$ARGUMENTS` 传给 skill，让 skill 里的 `lib/parse-args.sh` 解析。

## 失败兜底

如果 skill 调用失败、或 `.claude/skills/verify-daypage/SKILL.md` 不存在，提示用户：

> verify-daypage skill 未就绪。检查 `.claude/skills/verify-daypage/` 是否存在，或重新执行 skill 初始化。

## 相关

- Skill 实现：`.claude/skills/verify-daypage/SKILL.md`
- PRD：`tasks/prd-daypage-v3-experience.md`
