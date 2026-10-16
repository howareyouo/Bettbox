#!/usr/bin/env bash
# ============================================================================
# export_patch.sh — 把 main 上自己开发的功能导出为流水线补丁
#
# 用法（二选一）:
#
#   A. 按提交导出（推荐，功能是独立提交时最干净）:
#      tools/export_patch.sh feature_my_thing <提交范围>
#      例: tools/export_patch.sh feature_my_thing 8ae54f3..2b5f376
#          tools/export_patch.sh feature_my_thing HEAD~2..HEAD
#          验证基线 = 范围的左端点（A..B 中的 A）
#
#   B. 按文件路径导出（改动未提交或散在多个提交里时）:
#      tools/export_patch.sh feature_my_thing <base-ref> -- <路径...>
#      例: tools/export_patch.sh feature_my_thing upstream/main -- \
#            lib/common/my_thing.dart lib/views/profiles/my_thing.dart
#          验证基线 = base-ref
#
# 行为:
#   1. 生成 tools/windows_only_patches/<名字>.patch
#   2. 立即在干净基线 worktree 上验证补丁可应用（失败则退出非零）
#   3. 若同名字补丁已存在，自动覆盖前先备份为 .bak
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="$REPO_ROOT/tools/windows_only_patches"
PATCH_NAME="${1:?用法: export_patch.sh <补丁名> <提交范围|base-ref> [-- 路径...]}"
shift

TARGET="$PATCH_DIR/$PATCH_NAME.patch"

# 校验补丁名只是文件名（防路径穿越）
case "$PATCH_NAME" in
  */*|*..*|*\\*) echo "ERROR: 补丁名应为简单文件名，如 feature_my_thing" >&2; exit 1 ;;
esac

cd "$REPO_ROOT"
mkdir -p "$PATCH_DIR"

if [ "${2:-}" = "--" ]; then
  # ================= 模式 B：按路径导出 =================
  BASE_REF="$1"
  shift 2
  [ $# -ge 1 ] || { echo "ERROR: 至少需要一个路径" >&2; exit 1; }
  if ! git rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null; then
    echo "ERROR: base-ref '$BASE_REF' 不存在（先 git fetch upstream main）" >&2
    exit 1
  fi
  VERIFY_BASE="$BASE_REF"
  git diff "$BASE_REF"..HEAD -- "$@" > "$TARGET"
else
  # ================= 模式 A：按提交范围导出 =================
  RANGE="${1:?用法: export_patch.sh <补丁名> <提交范围>}"
  if [[ "$RANGE" == *".."* ]]; then
    FROM="${RANGE%%..*}"
    git rev-parse --verify --quiet "$FROM^{commit}" >/dev/null \
      || { echo "ERROR: 提交范围 '$RANGE' 无效（形如 A..B，A 须为提交）" >&2; exit 1; }
    VERIFY_BASE="$FROM"
  else
    # 单个提交：验证基线为其父提交
    git rev-parse --verify --quiet "$RANGE^{commit}" >/dev/null \
      || { echo "ERROR: 提交 '$RANGE' 无效" >&2; exit 1; }
    VERIFY_BASE="$RANGE^"
  fi
  git format-patch --stdout "$RANGE" > "$TARGET"
fi

echo "==> 已生成 $(basename "$TARGET")（$(wc -l < "$TARGET") 行）"

# ================= 在干净基线上验证可应用 =================
[ -s "$TARGET" ] || { echo "ERROR: 补丁为空——检查范围/路径是否正确" >&2; rm -f "$TARGET"; exit 1; }

git rev-parse --verify --quiet "$VERIFY_BASE^{commit}" >/dev/null \
  || VERIFY_BASE=upstream/main

WT="$REPO_ROOT/.worktrees/verify-patch"
git worktree remove --force "$WT" >/dev/null 2>&1 || true
if git worktree add --quiet "$WT" "$VERIFY_BASE" 2>/dev/null; then
  if git -C "$WT" apply --check "$TARGET" 2>/dev/null; then
    echo "OK: 补丁可干净应用于基线 $VERIFY_BASE"
    git worktree remove --force "$WT" >/dev/null 2>&1 || true
  else
    echo "WARN: 补丁无法干净应用于基线 $VERIFY_BASE（基线可能比功能的开发起点新）" >&2
    git worktree remove --force "$WT" >/dev/null 2>&1 || true
    # 兜底：若基线不是上游，再试上游 main
    if [ "$VERIFY_BASE" != "upstream/main" ] && git rev-parse --verify --quiet upstream/main >/dev/null; then
      if git worktree add --quiet "$WT" upstream/main 2>/dev/null && \
         git -C "$WT" apply --check "$TARGET" 2>/dev/null; then
        echo "OK: 补丁可干净应用于上游基线 upstream/main"
        git worktree remove --force "$WT" >/dev/null 2>&1 || true
      else
        git worktree remove --force "$WT" >/dev/null 2>&1 || true
        echo "ERROR: 补丁也无法应用于 upstream/main。" >&2
        echo "      上游可能已改动相关文件。补丁仍已生成，但 CI 将报错，请人工修复。" >&2
        exit 2
      fi
    else
      echo "ERROR: 请人工检查补丁。上游可能已改动相关文件。" >&2
      exit 2
    fi
  fi
else
  echo "WARN: 无法创建验证 worktree（基线 $VERIFY_BASE 不可用），跳过验证" >&2
fi