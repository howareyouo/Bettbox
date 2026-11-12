#!/usr/bin/env bash
# ============================================================================
# build_windows_only.sh — 从 fork main 重新生成 windows-only 分支
#
# 设计（"生成型"同步，无长期分叉历史）：
#   1. 以 main（或指定 ref）为起点新建 worktree（干净基线，零历史包袱）
#   2. 按 windows_only/delete_manifest.txt 删除非 Windows 平台目录/文件
#   3. 应用 windows_only/patches/*.patch（手工裁剪补丁，如引用摘除）
#   3.5 pubspec 追加 dependency_overrides 摘除 Android 专属 jni 依赖链
#   3.6 同步 pubspec.lock（摘除 jni 条目，3.5 必须配套 3.6）
#   3.7 摘除生成文件（generated_plugin*）里的 jni 插件行
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
# 已知会把 jni（jnigen 直连方案）拉进依赖图的 Android 实现包 → 最后一个无 jni
# 依赖的版本，连同该版本在 pub 上的 sha256（lock 条目改写要用）。它们的 Windows
# 垫片在构建期链接 jvm.lib（仅 JDK 提供），Windows 端却从不调用；压回旧版本即可
# 整条摘除，CI 从此不需要 JDK。
#
# 新增条目的判据：pub 上某包某个版本起 `dependencies` 出现 jni。列在这里的包必须
# 仍在父包约束内（否则 pub 解析直接失败，脚本会因 set -e 中止）。
JNI_FREE_PINS='
path_provider_android=2.2.23=149441ca6e4f38193b2e004c0ca6376a3d11f51fa5a77552d8bd4d2b0c0912ba
shared_preferences_android=2.4.28=1e12aafe408aa50da80edfd679a2a6bf63ba7ab37c7fa98286da459a757b3399
'
resolve_override_pins() {
  echo "$JNI_FREE_PINS" | sed '/^$/d'
}

# 往 pubspec.yaml 注入 dependency_overrides（脚本侧追加而非补丁：上游 pubspec
# 变动不会弄断）。已存在的 override 键跳过并警告，避免产生重复 YAML 键。
inject_overrides() {
  local pins yaml_block=""
  pins=$(resolve_override_pins)
  while IFS='=' read -r pkg ver _hash; do
    [ -n "$pkg" ] || continue
    if grep -q "^  $pkg:" pubspec.yaml; then
      echo "    warn pubspec 已含 $pkg 覆盖，跳过注入" >&2
      continue
    fi
    yaml_block="${yaml_block}  ${pkg}: ${ver}
"
    echo "    overr $pkg -> $ver"
  done <<< "$pins"

  [ -n "$yaml_block" ] || return 0
  export OVR_BLOCK="$yaml_block"
  if grep -q '^dependency_overrides:' pubspec.yaml; then
    # 已有 overrides 段（如上游的 flutter_rust_bridge）：插到段头之后，
    # 不能再追加一个 dependency_overrides 键（重复键是非法 YAML）
    awk '
      !done && /^dependency_overrides:/ { print; printf "%s", ENVIRON["OVR_BLOCK"]; done=1; next }
      { print }
    ' pubspec.yaml > pubspec.yaml.tmp && mv pubspec.yaml.tmp pubspec.yaml
  else
    {
      printf '\n# windows-only：以下包 >=某版本 起引入 jni 依赖链（仅 Android 运行时\n'
      printf '# 需要），Windows 构建用不到其 jvm.lib 垫片，摘除后 CI 不再依赖 JDK。\n'
      printf 'dependency_overrides:\n%s' "$yaml_block"
    } >> pubspec.yaml
  fi
}

echo "==> 摘除 jni 依赖链（dependency_overrides）"
inject_overrides

# --- 3.6 同步 pubspec.lock，与 3.5 注入的 override 保持一致 ---
# 只改 pubspec.yaml 不够：lock 仍是 main 的解析结果（含 jni 与被压版本的上游），
# 提交上去与本分支的 override 自相矛盾。CI 的 flutter pub get 会在临时工作区里
# 纠正它，但纠正结果不会回到分支上，于是每次重建都带着旧 lock 重新开始，一旦
# 缓存状态不同就退回链接 jvm.lib → LNK1181。
#
# 这里用文本替换而非 `flutter pub get`：sync job 跑在 ubuntu-latest 上，没有装
# Flutter。改写是安全的——每个 pin 的版本与 sha256 都写在 JNI_FREE_PINS 里，只需
# 替换 version / sha256 与 dependency 标记；jni 三兄弟在 lock 里全是 transitive，
# 上游就是被压的包，整条删掉即可。
echo "==> 同步 pubspec.lock（摘除 jni 条目，套用 override 版本）"
# pins 通过 ENVIRON 传（带换行，awk -v 会转义）；每条 "包=版本=sha256"
export PIN_LINES="$(resolve_override_pins)"
awk '
  BEGIN {
    n = split(ENVIRON["PIN_LINES"], arr, "\n")
    for (i = 1; i <= n; i++) {
      if (arr[i] == "") continue
      split(arr[i], f, "=")
      pin_ver[f[1]] = f[2]
      pin_sha[f[1]] = f[3]
    }
  }
  # 条目起始行：先判 jni（整条丢弃），否则记录当前包名供下面改写
  /^  [a-z0-9_]+:$/ {
    pkg = $0
    sub(/^  /, "", pkg); sub(/:$/, "", pkg)
    cur = pkg
    if (pkg ~ /^jni(_flutter|_util)?$/) { in_jni = 1; next }
    in_jni = 0
    print
    next
  }
  # 条目内的行：jni 块整体丢弃
  in_jni { next }
  # pins 内的条目：改 dependency 标记、sha256 与 version
  cur in pin_ver && /^    dependency:/ { print "    dependency: \"direct overridden\""; next }
  cur in pin_ver && /^      sha256:/   { print "      sha256: \"" pin_sha[cur] "\""; next }
  cur in pin_ver && /^    version:/    { print "    version: \"" pin_ver[cur] "\""; next }
  { print }
' pubspec.lock > pubspec.lock.tmp && mv pubspec.lock.tmp pubspec.lock

# 断言：lock 里不能有任何 jni 条目，且每个 pin 的版本与 sha256 都已落到目标值
if grep -q '^  jni' pubspec.lock; then
  echo "ERROR: pubspec.lock 仍含 jni 条目，jvm.lib 链接问题会复现" >&2
  grep -A4 '^  jni' pubspec.lock >&2
  echo "现场保留在 $WT_DIR" >&2
  exit 2
fi
while IFS='=' read -r pkg want want_sha; do
  [ -n "$pkg" ] || continue
  entry=$(sed -n "/^  ${pkg}:/,/^  [^ ]/p" pubspec.lock)
  got=$(echo "$entry" | sed -n 's/.*version: "\(.*\)"/\1/p')
  got_sha=$(echo "$entry" | sed -n 's/.*sha256: "\(.*\)"/\1/p')
  if [ "$got" != "$want" ] || [ "$got_sha" != "$want_sha" ]; then
    echo "ERROR: pubspec.lock 的 $pkg 为 $got/$got_sha，期望 $want/$want_sha" >&2
    echo "现场保留在 $WT_DIR" >&2
    exit 2
  fi
  echo "    lock $pkg=$got"
done <<< "$PIN_LINES"
echo "    lock 已无 jni 条目"

# --- 3.7 摘除生成文件里的 jni FFI 插件 ---
# main 的 windows/flutter/generated_plugins.cmake 是按 main 的 lock（含 jni）
# 生成的，被原样带进本分支就与 override 自相矛盾。CI 的 pub get 会重写它，但
# 不该依赖下游兜底：留着的文件会让 "分支上的依赖图" 说谎，排查时误导人。
# cpp/c/h 是同一批生成物，一并扫。
GEN_FILES=$(git ls-files 'windows/flutter/generated_plugin*')
if [ -n "$GEN_FILES" ]; then
  # shellcheck disable=SC2086
  sed -i '/^  jni$/d' $GEN_FILES
  changed=$(git diff --name-only -- windows/flutter)
  if [ -n "$changed" ]; then
    echo "==> 生成文件摘除 jni 插件: $(echo "$changed" | tr '\n' ' ')"
  fi
fi

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
