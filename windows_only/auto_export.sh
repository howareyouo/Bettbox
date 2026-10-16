#!/usr/bin/env bash
# ============================================================================
# auto_export.sh — 按 own_files.txt 清单自动导出自有功能补丁（幂等）
#
# 每次 push 到 main 后由 CI 调用（也可本地手动跑）：
#   1. 读 windows_only/own_files.txt（每行「补丁名 路径」）
#   2. 对每个补丁名：git diff upstream/main..HEAD -- <路径> 生成 .patch
#      （空 diff 且旧补丁存在 → 删除，表示功能已回退到上游）
#   3. 有变更时在干净上游 worktree 上按字母序验证 patches/ 下
#      所有补丁可应用（与 build_windows_only.sh 的应用 glob 顺序一致，
#      能抓到手工补丁与清单补丁的冲突）
#   4. 输出 CHANGED（有增删改）或 CLEAN（无变化），由 workflow 决定是否提交
#
# 用法:
#   windows_only/auto_export.sh [upstream-ref]   (默认 upstream/main)
# 退出码: 0 成功；非 0 失败（保留现场供排查，不提交任何东西）
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/windows_only/own_files.txt"
PATCH_DIR="$REPO_ROOT/windows_only/patches"
UPSTREAM_REF="${1:-upstream/main}"

cd "$REPO_ROOT"

# --- 0. 前置校验 ---
if ! git rev-parse --verify --quiet "$UPSTREAM_REF^{commit}" >/dev/null; then
  echo "ERROR: ref '$UPSTREAM_REF' 不存在（先 git fetch upstream main）" >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: 缺失清单 $MANIFEST" >&2
  exit 1
fi
mkdir -p "$PATCH_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. 解析清单，按补丁名分组路径 ---
declare -a NAME_LIST=()
while IFS= read -r line || [ -n "$line" ]; do
  # 兼容 CRLF 检出：Windows autocrlf 会让清单带尾 \r，剥掉再解析
  line="${line%$'\r'}"
  case "$line" in
    ""|\#*) continue ;;
  esac
  name="${line%% *}"
  path="${line#* }"
  case "$name" in
    */*|*..*|*\\*) echo "ERROR: 补丁名应为简单文件名: $name" >&2; exit 1 ;;
  esac
  [ -n "$path" ] || { echo "ERROR: 缺路径（应为「补丁名 路径」）: $line" >&2; exit 1; }
  echo "$path" >> "$TMP/$name.paths"
  found=0
  for n in "${NAME_LIST[@]}"; do [ "$n" = "$name" ] && found=1; done
  [ "$found" = "1" ] || NAME_LIST+=("$name")
done < "$MANIFEST"

[ "${#NAME_LIST[@]}" -gt 0 ] || { echo "ERROR: 清单中没有有效条目" >&2; exit 1; }

# --- 2. 导出补丁，记录是否变更 ---
changed=0
for name in "${NAME_LIST[@]}"; do
  target="$PATCH_DIR/$name.patch"
  old_hash=""
  [ -f "$target" ] && old_hash="$(git hash-object "$target")"
  if git diff --quiet "$UPSTREAM_REF"..HEAD -- $(<"$TMP/$name.paths"); then
    if [ -n "$old_hash" ]; then
      rm -f "$target"
      echo "    del  $name.patch (改动已回退到上游)"
      changed=1
    else
      echo "    skip $name (无改动)"
    fi
    continue
  fi
  git -c core.abbrev=8 diff "$UPSTREAM_REF"..HEAD -- $(<"$TMP/$name.paths") > "$target"
  new_hash="$(git hash-object "$target")"
  if [ "$old_hash" != "$new_hash" ]; then changed=1; fi
  echo "    exp  $name.patch ($(wc -l < "$target") 行)"
done

# --- 3. 有变更时，在干净上游 worktree 上按字母序验证可应用 ---
if [ "$changed" = "1" ]; then
  WT="$REPO_ROOT/.worktrees/verify-auto-export"
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  if git worktree add --quiet "$WT" "$UPSTREAM_REF"; then
    ok=1
    # 与 build_windows_only.sh 的应用顺序一致（同一 glob 字母序）；
    # 遍历目录下所有补丁而非只看清单，能抓到手工补丁与清单补丁的冲突
    for p in "$PATCH_DIR"/*.patch; do
      [ -f "$p" ] || continue
      if ! git -C "$WT" apply --check "$p" 2>"$WT/.apply.err"; then
        echo "ERROR: 补丁无法应用: $(basename "$p")" >&2
        cat "$WT/.apply.err" >&2
        echo "现场保留在 $WT；请检查 own_files.txt 与补丁（注意补丁间依赖顺序）。" >&2
        ok=0
        break
      fi
      git -C "$WT" apply --quiet "$p"
      echo "    ok   $(basename "$p") 可应用于 $UPSTREAM_REF"
    done
    if [ "$ok" = "1" ]; then
      git worktree remove --force "$WT" >/dev/null 2>&1 || true
    else
      exit 1
    fi
  else
    echo "WARN: 无法创建验证 worktree（$UPSTREAM_REF 不可用），跳过验证" >&2
  fi
fi

# --- 4. 输出结果 ---
if [ "$changed" = "1" ]; then
  echo "CHANGED"
else
  echo "CLEAN"
fi