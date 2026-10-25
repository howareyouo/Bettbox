#!/usr/bin/env bash
# ============================================================================
# build_windows_only.sh — 从 fork main 重新生成 windows-only 分支
#
# 设计（"生成型"同步，无长期分叉历史）：
#   1. 以 main（或指定 ref）为起点新建 worktree（干净基线，零历史包袱）
#   2. 按 windows_only/delete_manifest.txt 删除非 Windows 平台目录/文件
#   3. 应用 windows_only/patches/*.patch（手工裁剪补丁，如引用摘除）
#   4. 提交并记录源 SHA（.source-sha），供 CI 对比自上次构建以来 main 是否变化
#   5. 新分支保存在 worktree 仓库中，CI 负责 push 到 windows-only
#
# 用法:
#   windows_only/build_windows_only.sh [源 ref] [输出分支名]
#     源 ref      默认 main（fork 主线；须已存在于本地 refs）
#     输出分支名   默认 windows-only-rebuild
# 退出码: 0 成功；非 0 失败（保留现场供排查）
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_REF="${1:-main}"
OUT_BRANCH="${2:-windows-only-rebuild}"
WT_DIR="$REPO_ROOT/.worktrees/$OUT_BRANCH"
PATCH_DIR="$REPO_ROOT/windows_only/patches"
MANIFEST="$REPO_ROOT/windows_only/delete_manifest.txt"

cd "$REPO_ROOT"

# --- 0. 前置校验 ---
if ! git rev-parse --verify --quiet "$SOURCE_REF^{commit}" >/dev/null; then
  echo "ERROR: ref '$SOURCE_REF' 不存在" >&2
  exit 1
fi
SOURCE_SHA=$(git rev-parse "$SOURCE_REF")
if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: 缺失清单 $MANIFEST" >&2
  exit 1
fi

# --- 1. 清理旧 worktree / 旧分支，重建干净基线 ---
if [ -e "$WT_DIR/.git" ] || [ -d "$WT_DIR" ]; then
  git worktree remove --force "$WT_DIR" >/dev/null 2>&1 || true
  rm -rf "$WT_DIR"
fi
git branch -D "$OUT_BRANCH" >/dev/null 2>&1 || true
git worktree add --quiet "$WT_DIR" "$SOURCE_REF" -b "$OUT_BRANCH"
cd "$WT_DIR"

echo "==> 基线: $SOURCE_REF ($SOURCE_SHA)"

# --- 2. 按清单删除非 Windows 文件/目录 ---
DELETED=0
while IFS= read -r line || [ -n "$line" ]; do
  # 兼容 CRLF 检出：Windows autocrlf 会让清单带尾 \r，剥掉再解析
  line="${line%$'\r'}"
  # 跳过空行与注释
  case "$line" in
    ""|\#*) continue ;;
  esac
  if git rm --quiet --ignore-unmatch -r -- "$line" 2>/dev/null; then
    DELETED=$((DELETED + 1))
    echo "    del  $line"
  else
    echo "    warn $line (不存在，跳过)"
  fi
done < "$MANIFEST"
echo "==> 删除 $DELETED 项"

# --- 3. 应用手工裁剪补丁（先整体校验，任一失败即中止并保留现场） ---
for p in "$PATCH_DIR"/*.patch; do
  [ -f "$p" ] || continue
  if ! git apply --check "$p" 2>"$WT_DIR/.apply.err"; then
    echo "ERROR: 补丁无法应用: $(basename "$p")" >&2
    cat "$WT_DIR/.apply.err" >&2
    echo "现场保留在 $WT_DIR；请更新补丁后重试。提示：git apply --3way 可辅助合并。" >&2
    exit 2
  fi
done
for p in "$PATCH_DIR"/*.patch; do
  [ -f "$p" ] || continue
  git apply --quiet "$p"
  echo "    appl $(basename "$p")"
done

# --- 4. 记录源 SHA 并提交 ---
echo "$SOURCE_SHA" > .source-sha
git add -A

SOURCE_LOG=$(git log --oneline "$SOURCE_REF" -5 2>/dev/null | sed 's/^/    /')
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-windows-only bot}" \
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-windows-only-bot@users.noreply.github.com}" \
GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-windows-only bot}" \
GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-windows-only-bot@users.noreply.github.com}" \
git commit --quiet -m "windows-only: rebuild from main $SOURCE_SHA" -m "Based on $SOURCE_REF:

$SOURCE_LOG"

echo "==> 完成: 分支 $OUT_BRANCH @ $(git rev-parse HEAD)"
echo "SOURCE_SHA=$SOURCE_SHA"
