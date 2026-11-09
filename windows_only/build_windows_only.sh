#!/usr/bin/env bash
# ============================================================================
# build_windows_only.sh — 从 fork main 重新生成 windows-only 分支
#
# 设计（"生成型"同步，无长期分叉历史）：
#   1. 以 main（或指定 ref）为起点新建 worktree（干净基线，零历史包袱）
#   2. 按 windows_only/delete_manifest.txt 删除非 Windows 平台目录/文件
#   3. 应用 windows_only/patches/*.patch（手工裁剪补丁，如引用摘除）
#   3.5 pubspec 追加 dependency_overrides 摘除 Android 专属 jni 依赖链
#   3.6 flutter pub get 重写 pubspec.lock 并断言无 jni（3.5 必须配套 3.6）
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

# --- 3.5 摘除 Android 专属 jni 依赖链（Windows 构建不需要，链接期不再要 JDK） ---
# path_provider_android 2.3.0 起依赖 jni/jni_flutter（jnigen 直连方案），其
# Windows 垫片在构建期链接 jvm.lib，而 Windows 端从不调用。锁定到最后一个无 jni
# 依赖的版本 2.2.23（path_provider 的 ^2.2.5 约束内）。脚本侧追加而非补丁：
# 上游 pubspec 变动不会弄断这里。若上游已自带 dependency_overrides，只警告
# 不覆盖，避免产生重复 YAML 键。
if grep -q 'path_provider_android:' pubspec.yaml; then
  echo "    warn pubspec 已含 path_provider_android 覆盖，跳过注入" >&2
elif grep -q '^dependency_overrides:' pubspec.yaml; then
  # 已有 overrides 段（如上游的 flutter_rust_bridge）：把映射插到段头之后，
  # 不能再追加一个 dependency_overrides 键（重复键是非法 YAML）
  awk '
    !done && /^dependency_overrides:/ { print; print "  path_provider_android: 2.2.23"; done=1; next }
    { print }
  ' pubspec.yaml > pubspec.yaml.tmp && mv pubspec.yaml.tmp pubspec.yaml
  echo "    overr path_provider_android -> 2.2.23 (并入已有 dependency_overrides)"
else
  cat >> pubspec.yaml <<'EOF'

# windows-only：path_provider_android>=2.3 引入 jni 依赖链（仅 Android 运行时
# 需要），Windows 构建用不到其 jvm.lib 垫片，摘除后 CI 不再依赖 JDK。
dependency_overrides:
  path_provider_android: 2.2.23
EOF
  echo "    overr path_provider_android -> 2.2.23 (jni 链摘除)"
fi

# --- 3.6 重解析依赖，把 override 真正落到 pubspec.lock ---
# 只改 pubspec.yaml 不够：lock 仍是 main 的解析结果（path_provider_android 2.3.1
# + jni），提交上去与本分支的 override 自相矛盾。CI 的 flutter pub get 会在临时
# 工作区里纠正它，但纠正结果不会回到分支上，于是每次重建都带着旧 lock 重新开始，
# 一旦缓存状态不同就退回链接 jvm.lib → LNK1181。这里直接重解析并断言。
echo "==> 重解析依赖（写入 override 后的 pubspec.lock）"
flutter pub get > /dev/null
if grep -q '^  jni:' pubspec.lock; then
  echo "ERROR: 重解析后 pubspec.lock 仍含 jni，jvm.lib 链接问题会复现" >&2
  grep -A3 '^  jni:' pubspec.lock >&2
  echo "现场保留在 $WT_DIR" >&2
  exit 2
fi
LOCK_PPA=$(grep -A8 '^  path_provider_android:' pubspec.lock | sed -n 's/.*version: "\(.*\)"/\1/p')
echo "    lock path_provider_android=$LOCK_PPA, jni 已摘除"

# --- 4. 记录源 SHA 并提交 ---
echo "$SOURCE_SHA" > .source-sha
git add -A
# main 的 .gitignore 有 `.*` 规则，点文件需强制 add 才能进提交
git add -f .source-sha

SOURCE_LOG=$(git log --oneline "$SOURCE_REF" -5 2>/dev/null | sed 's/^/    /')
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-windows-only bot}" \
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-windows-only-bot@users.noreply.github.com}" \
GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-windows-only bot}" \
GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-windows-only-bot@users.noreply.github.com}" \
git commit --quiet -m "windows-only: rebuild from main $SOURCE_SHA" -m "Based on $SOURCE_REF:

$SOURCE_LOG"

echo "==> 完成: 分支 $OUT_BRANCH @ $(git rev-parse HEAD)"
echo "SOURCE_SHA=$SOURCE_SHA"
