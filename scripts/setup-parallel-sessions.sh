#!/usr/bin/env bash
# setup-parallel-sessions.sh
#
# 为 issue #19~#23 批量启动独立的 Claude Code worktree session。
# 每个 session 在独立的 git worktree + 独立分支中运行，互不影响。
#
# 用法:
#   bash scripts/setup-parallel-sessions.sh <issue-number>
#   bash scripts/setup-parallel-sessions.sh all       # 顺序启动全部（交互式，不推荐）
#   bash scripts/setup-parallel-sessions.sh prep      # 只预备 worktree + GeneratedSecrets，不启动 claude
#   bash scripts/setup-parallel-sessions.sh cleanup   # 清理所有 worktree
#   bash scripts/setup-parallel-sessions.sh list      # 列出当前 worktree 状态
#
# 注意:
#   - 必须在 daypage 仓库根目录下执行
#   - 依赖: git >= 2.17, gh CLI（已登录）, claude CLI, tmux（可选）
#   - GeneratedSecrets.swift 会自动从主 worktree 复制到新 worktree

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT}" ]] || [[ "$(basename "${REPO_ROOT}")" != "daypage" ]]; then
  echo "❌ 请在 daypage 仓库根目录下运行此脚本"
  exit 1
fi

cd "${REPO_ROOT}"

SECRETS_SRC="${REPO_ROOT}/DayPage/Config/GeneratedSecrets.swift"

# issue_id | worktree_name | branch_name | short_title
ISSUES=(
  "19|19-search|feat/19-archive-search|Archive 搜索功能"
  "20|20-banner|feat/20-daily-page-banner|Daily Page 图片 banner"
  "21|21-dots|feat/21-calendar-dots|日历小圆点"
  "22|22-status|feat/22-system-status|SYSTEM STATUS artifact"
  "23|23-opacity|feat/23-metadata-opacity|Metadata Only 灰化"
)

color() { printf '\033[%sm%s\033[0m' "$1" "$2"; }

prompt_for() {
  local issue="$1"
  cat <<EOF
你在 daypage iOS 项目的独立 worktree 中工作，负责实现 GitHub issue #${issue}。

执行步骤:
1. 运行 \`gh issue view ${issue}\` 阅读完整需求与验证标准 checklist
2. 读 CLAUDE.md 了解项目约定（SwiftUI + 文件持久化 + 不引入外部依赖）
3. 对照 design/stitch/screenshots/*.png 与 design/stitch/html/*.html 实现 UI
4. 实现过程中逐项对照 issue 的验证标准 checklist
5. 完成后:
   - 运行 \`xcodebuild -scheme DayPage build\` 必须通过
   - 在 iPhone 15 Pro Simulator 里实际运行并肉眼对比设计稿
   - 用 \`git commit\` 提交（消息格式: "feat: #${issue} <简述>"）
   - \`git push -u origin HEAD\`
   - \`gh pr create\` 创建 PR，body 里写 "Closes #${issue}"，并在 Test plan 里对应 issue 的验证标准
EOF
}

prep_worktree() {
  local name="$1" branch="$2" issue="$3"
  local path="${REPO_ROOT}/../daypage-${name}"

  if [[ -d "${path}" ]]; then
    echo "  ⏭  worktree ${path} 已存在，跳过创建"
  else
    echo "  ➕ 创建 worktree: ${path} (branch: ${branch})"
    git worktree add "${path}" -b "${branch}" origin/main
  fi

  if [[ -f "${SECRETS_SRC}" ]]; then
    mkdir -p "${path}/DayPage/Config"
    cp "${SECRETS_SRC}" "${path}/DayPage/Config/"
    echo "  🔐 已复制 GeneratedSecrets.swift"
  else
    echo "  ⚠️  ${SECRETS_SRC} 不存在，请先在主 worktree 跑一次 build 或 scripts/generate_secrets.sh"
  fi

  echo "${path}"
}

start_session() {
  local issue="$1" name="$2" branch="$3" title="$4"
  echo ""
  color "1;36" "▶ Issue #${issue} — ${title}"
  echo ""

  local path
  path="$(prep_worktree "${name}" "${branch}" "${issue}" | tail -n 1)"

  local prompt
  prompt="$(prompt_for "${issue}")"

  echo ""
  color "1;33" "  启动命令:"
  echo ""
  echo "  cd ${path} && claude --tmux \\"
  echo "    \"${prompt//$'\n'/ }\""
  echo ""
  read -r -p "  按 Enter 启动此 session（Ctrl+C 取消）... " _
  (
    cd "${path}"
    claude --tmux "${prompt}"
  )
}

cmd_prep() {
  for entry in "${ISSUES[@]}"; do
    IFS='|' read -r issue name branch title <<< "${entry}"
    color "1;36" "═══ Issue #${issue} — ${title} ═══"
    echo ""
    prep_worktree "${name}" "${branch}" "${issue}" >/dev/null
    echo "  ✅ 准备完成"
    echo ""
  done

  echo ""
  color "1;32" "全部 worktree 已就绪。接下来在 5 个独立 terminal 标签中分别执行:"
  echo ""
  for entry in "${ISSUES[@]}"; do
    IFS='|' read -r issue name branch title <<< "${entry}"
    echo "  cd ../daypage-${name} && claude --tmux \"阅读并实现 issue #${issue}，完成所有验证标准后 commit + 推送 + 创建 PR（Closes #${issue}）。\""
  done
  echo ""
}

cmd_one() {
  local target="$1"
  for entry in "${ISSUES[@]}"; do
    IFS='|' read -r issue name branch title <<< "${entry}"
    if [[ "${issue}" == "${target}" ]]; then
      start_session "${issue}" "${name}" "${branch}" "${title}"
      return 0
    fi
  done
  echo "❌ 未找到 issue #${target}"
  exit 1
}

cmd_all() {
  for entry in "${ISSUES[@]}"; do
    IFS='|' read -r issue name branch title <<< "${entry}"
    start_session "${issue}" "${name}" "${branch}" "${title}"
  done
}

cmd_cleanup() {
  color "1;33" "将清理以下 worktree："
  echo ""
  for entry in "${ISSUES[@]}"; do
    IFS='|' read -r issue name branch title <<< "${entry}"
    echo "  ../daypage-${name} (branch: ${branch})"
  done
  echo ""
  read -r -p "确认清理? [y/N] " confirm
  [[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || { echo "已取消"; exit 0; }

  for entry in "${ISSUES[@]}"; do
    IFS='|' read -r issue name branch title <<< "${entry}"
    local path="${REPO_ROOT}/../daypage-${name}"
    if [[ -d "${path}" ]]; then
      git worktree remove "${path}" --force && echo "  ✅ 移除 ${path}"
    fi
    if git show-ref --verify --quiet "refs/heads/${branch}"; then
      git branch -D "${branch}" && echo "  ✅ 删除分支 ${branch}"
    fi
  done
}

cmd_list() {
  echo ""
  color "1;36" "当前 worktree 列表:"
  echo ""
  git worktree list
  echo ""
}

cmd_help() {
  head -n 15 "$0" | tail -n 14
}

main() {
  local arg="${1:-help}"
  case "${arg}" in
    prep)    cmd_prep ;;
    all)     cmd_all ;;
    cleanup) cmd_cleanup ;;
    list)    cmd_list ;;
    help|-h|--help) cmd_help ;;
    19|20|21|22|23) cmd_one "${arg}" ;;
    *) echo "未知命令: ${arg}"; cmd_help; exit 1 ;;
  esac
}

main "$@"
