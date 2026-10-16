#!/usr/bin/env bash
# ============================================================================
# build_windows_only.sh — 从上游（upstream/main）重新生成 windows-only 分支
#
# 设计（"生成型"同步，无长期分叉历史）：
#   1. 以 upstream ref 为起点新建 worktree（干净基线，零历史包袱）
#   2. 按 windows_only/delete_manifest.txt 删除非 Windows 平台目录/文件
#   3. 依次应用 windows_only/windows_only_patches/*.patch（功能补丁 + 引用摘除）
#   4. 提交并记录上游 SHA（.upstream-sha），供下次对比是否变化
#   5. 新分支保存在 worktree 仓库中，CI 负责 push 到 windows-only
#
# 用法:
#   windows_only/build_windows_only.sh [upstream-ref] [输出分支名]
#     upstream-ref   默认 upstream/main（须已存在于本地 refs）
#     输出分支名      默认 windows-only-rebuild
# 退出码: 0 成功；非 0 失败（保留现场供排查）
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_REF="${1:-upstream/main}"
OUT_BRANCH="${2:-windows-only-rebuild}"
WT_DIR="$REPO_ROOT/.worktrees/$OUT_BRANCH"
PATCH_DIR="$REPO_ROOT/windows_only/windows_only_patches"
MANIFEST="$REPO_ROOT/windows_only/delete_manifest.txt"

cd "$REPO_ROOT"

# --- 0. 前置校验 ---
if ! git rev-parse --verify --quiet "$UPSTREAM_REF^{commit}" >/dev/null; then
  echo "ERROR: ref '$UPSTREAM_REF' 不存在（先 git fetch upstream main）" >&2
  exit 1
fi
UPSTREAM_SHA=$(git rev-parse "$UPSTREAM_REF")
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
git worktree add --quiet "$WT_DIR" "$UPSTREAM_REF" -b "$OUT_BRANCH"
cd "$WT_DIR"

echo "==> 基线: $UPSTREAM_REF ($UPSTREAM_SHA)"

# --- 2. 按清单删除非 Windows 文件/目录 ---
DELETED=0
while IFS= read -r line || [ -n "$line" ]; do
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

# --- 3. 应用补丁（先整体校验，任一失败即中止并保留现场） ---
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

# --- 4. 记录上游 SHA 并提交 ---
echo "$UPSTREAM_SHA" > .upstream-sha
git add -A

UPSTREAM_LOG=$(git log --oneline "$UPSTREAM_REF" -5 2>/dev/null | sed 's/^/    /')
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-windows-only bot}" \
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-windows-only-bot@users.noreply.github.com}" \
GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-windows-only bot}" \
GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-windows-only-bot@users.noreply.github.com}" \
git commit --quiet -m "windows-only: rebuild from upstream $UPSTREAM_SHA" -m "Based on $UPSTREAM_REF:

$UPSTREAM_LOG"

echo "==> 完成: 分支 $OUT_BRANCH @ $(git rev-parse HEAD)"
echo "UPSTREAM_SHA=$UPSTREAM_SHA"