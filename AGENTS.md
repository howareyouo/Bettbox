# AGENTS.md — Bettbox fork AI 协作指南

> 本文件是 AI 协作者的操作基线，人类读者同样适用。改动本文件与改代码一样，
> 正常提交、push 到 main 即生效。

## 1. 仓库角色

| 项 | 值 |
|---|---|
| fork（origin） | `https://github.com/howareyouo/Bettbox.git` |
| upstream | `https://github.com/appshubcc/Bettbox.git`（只读，仅 `git fetch`，永不 merge） |
| 本地工作区 | `G:/bettbox`（Windows，Flutter 3.47.7 / Dart 3.13.5） |
| `main` | fork 功能开发主线（上游基线 + 自有提交），**唯一事实来源**，保持全平台代码 |
| `windows-only` 分支 | **CI 生成产物分支**（仅 Windows），随时可 force-push 重写；本地修改它没有意义 |

产物定位：**只支持 Windows（x64）**，其余平台在生成层裁掉；
main 本体仍保留全平台代码以最小化 rebase 冲突面。

## 2. 裁剪架构（核心思想）

**生成型同步，而非维护型**：不维护"持续演化的 windows-only 分支"，每次从 main 干净重建。

```
main 上的开发/提交（含 rebase 上游，全平台代码不动）
   │
   ▼
build_windows_only.sh（裁剪脚本，幂等）
   ├─ 以 main 为基线建干净 worktree
   ├─ 按 delete_manifest.txt 删除非 Windows 平台文件/目录
   ├─ 应用 patches/*.patch（手工裁剪补丁）
   ├─ pubspec 追加 dependency_overrides（摘除 Android 专属 jni 依赖链）
   ├─ 记录源 SHA（.source-sha）
   └─ commit → push 到 windows-only 分支（无历史包袱）
   ▼
GitHub Actions：flutter build windows
   → 发布 Release windows-only-<main SHA>（win zip）
```

关键性质：windows-only 每次从干净基线重建，与 main 严格一致（除裁剪项），
不存在"某改动忘了带进 windows-only"；上游同步只发生在「rebase main」，
CI 全程不感知 upstream。

**无功能清单**：main 的全部代码自动进入 windows-only。历史上曾有
`own_files.txt` 清单 + `auto_export.sh` 补丁导出机制，已整体移除，**勿复活**。

### 关键文件

| 文件 | 职责 |
|---|---|
| `.github/workflows/windows_only.yml` | CI：push main / 手动 → 重建 windows-only → 构建发布（`sync` + `build` 两个 job） |
| `windows_only/build_windows_only.sh` | 裁剪脚本：`build_windows_only.sh [源 ref，默认 main] [输出分支，默认 windows-only-rebuild]`；退出码 `2` = 补丁无法应用（现场保留在 `.worktrees/`） |
| `windows_only/delete_manifest.txt` | 删除清单：每行一个 `git rm` 目标，`#` 注释 |
| `windows_only/patches/*.patch` | 手工裁剪补丁（目前仅 `strip_iperf_scan.patch`） |

Flutter 版本由 CI 从 main 的 `.github/workflows/build.yaml` pin 解析（兜底读 pubspec），
rebase 上游时自动跟进，无需手动指定。

### jni 依赖摘除（步骤 3.5 + 3.6 + 3.7）

以下 Android 实现包从某版本起依赖 `jni`/`jni_flutter`（jnigen 直连方案），其
Windows 垫片在构建期链接 `jvm.lib`（仅 JDK 提供），而 Windows 端从不调用：

| 包 | 首个带 jni 的版本 | 钉住的版本 |
|---|---|---|
| `path_provider_android` | 2.3.0 | 2.2.23（`path_provider` `^2.1.6` 内） |
| `shared_preferences_android` | 2.5.0 | 2.4.28（`shared_preferences` `^2.3.4` 内） |

两个包都必须钉：**只钉一个不够**，任何一个漏掉都会把整条 jni 链拉回来，链接期
照样 `LNK1181: cannot open input file '...jvm.lib'`。

维护入口是脚本顶部的数据表 `JNI_FREE_PINS`，每行 `包=版本=sha256`：

```
path_provider_android=2.2.23=149441ca…
shared_preferences_android=2.4.28=1e12aafe…
```

- 发现新的「带 jni 的 Android 实现包」→ 往表里加一行（值从 pub 上该版本的
  `archive_sha256` 取），3.5 注入 override、3.6 改写 lock 都自动跟进。
- 表里的包必须仍在父包约束内，否则 `pub get` 解析失败。
- **脚本侧追加而非补丁文件**：上游 pubspec 变动不会弄断；若上游已含同名 override
  键，脚本跳过并警告，不产生重复 YAML 键。

**步骤 3.6 必须一起存在**：只改 pubspec 不够，`pubspec.lock` 仍是 main 的解析
结果（带 jni 与被压版本的上游），提交上去与 override 自相矛盾。CI 的
`flutter pub get` 会在临时工作区纠正它，但纠正结果不会回到分支，于是每次重建都
带着旧 lock 重新开始——缓存状态一变就退回链接 `jvm.lib`（LNK1181）。故 3.6 在
注入 override 后按 `JNI_FREE_PINS` 改写 lock：`dependency` 改
`"direct overridden"`、`version` 与 `sha256` 换成目标值，整条删掉
`jni`/`jni_flutter`/`jni_util`，再断言 lock 中无 `jni` 且每个 pin 的版本与
sha256 都对，不成立则 `exit 2` 保留现场，不让矛盾走到链接阶段才炸。

**为什么用文本替换而不是 `flutter pub get`**：sync job 跑在 `ubuntu-latest` 上，
不装 Flutter（版本解析只为传给 build job）。三个 jni 包在 lock 里全是
`transitive`，唯一上游就是被压的包。验证方式：脚本产出 vs 真跑
`flutter pub get` 后 `diff`，必须逐字节一致。

**步骤 3.7** 顺手把 `windows/flutter/generated_plugin*` 里残留的 `  jni` 行删掉：
这些文件是按 main 的 lock 生成的，被原样带进本分支就与 override 自相矛盾。CI 的
`flutter pub get` 会重写它们，但不该依赖下游兜底——留着的文件会让「分支上的依赖图」
说谎，排查时误导人。

**排障**：CI `Prepare Flutter deps` 日志里出现任何 `jni` 字样（`+ jni`、
`* xxx_android 2.5.x (was 2.4.28)`）就说明 table 漏了一个来源。

### delete_manifest 分层原则

1. **目录级删除**：`android/` `ios/` `linux/` `macos/` `web/` 等平台目录。
2. **文件级删除**：`lib/pages/scan.dart` 等依赖移动端实现插件的源码。
3. **行级摘除**：main 保留、windows-only 摘除 → 手工补丁。
4. **运行时判断（`Platform.is*` / `isAndroidTV`）永远保留不删**——Windows 上恒为
   false，行为天然正确；删了反而扩大与上游的冲突面。

### 手工补丁（strip_iperf_scan.patch）

上游 iperf 页（`lib/pages/toolbox/iperf.dart`）引用移动端专属 `ScanPage`
（`scan.dart` 已被删除）；补丁摘除其 scan 引用（接线改 `onScan: null`，
按钮在 Windows 本就不显示）。**main 自身不修改 iperf.dart**——这是补丁能
稳定应用的前提。新增手工补丁的判据：main 代码引用了被删文件，且无法用
运行时判断/条件导入在 main 内解决。

## 3. 流程一：日常开发与发布

1. 在 main 上正常开发、提交，`git push origin main`。
2. CI 自动：重建 windows-only → 构建 → 发布 Release `windows-only-<main SHA>`
   （旧 Release 不受影响）。
3. **无清单、无补丁导出**，不需要任何登记或同步动作。
4. 手工补丁 apply 失败 → CI 构建中止、现场保留 → 按 §6 处理。

## 4. 流程二：合并上游更新（AI 自动执行）

用户要求合并/同步上游时按此执行，无需逐步确认：

```bash
git fetch upstream
git log --oneline main..upstream/main        # 先向用户报告上游有什么
git rebase upstream/main
git push origin main                          # 触发 §3 的自动发布
```

- **无上游更新**（log 为空）：报告并结束，不做空 rebase。
- 普通冲突：3-way 手工解决，以本 fork 的功能语义为准。
- 生成文件冲突（`*.freezed.dart`、`*.g.dart` 等）：直接 `git checkout --ours/--theirs`
  后重跑 `dart run build_runner build`，**不要手改生成文件**。
- rebase 后、push 前，检查 §5 例外场景：上游是否新引用了被删文件、
  是否重构了补丁目标文件（iperf.dart）。
- 上游重写历史（force-push）无影响：rebase 只关心 `upstream/main` 当前指向。

## 5. 例外场景：何时才动 windows_only/

以下情况才需要改 `windows_only/`，其余改动一概不用：

| 场景 | 动作 |
|---|---|
| main/上游代码引用了被 delete_manifest 删除的文件（如 `scan.dart`） | 优先在 main 内优雅解决（运行时判断、条件导入）；确需摘除 → 新增手工补丁 |
| 改动了补丁目标文件（`iperf.dart`） | main 保持不改它；上游重构逼改 → 按新代码重做 `strip_iperf_scan.patch` |
| 删除/重命名了 delete_manifest 里的路径 | fork 永久移除 → 删清单行；只是移动 → 改行内路径 |
| 上游 pubspec 引入新的「Android 专属且带 jni/Windows 垫片」依赖 | 往脚本顶部 `JNI_FREE_PINS` 加一行 `包=版本=sha256`；3.5 注入 override、3.6 改写 lock 与断言都自动跟进 |
| 调整裁剪/构建/CI 脚本 | 直接改，改完按 §6 验证 |

## 6. 验证（改动涉及裁剪时必做）

```bash
bash windows_only/build_windows_only.sh main windows-only-rebuild
# 通过后：
cd .worktrees/windows-only-rebuild && flutter analyze    # 零问题即安全
grep -c '^  jni' pubspec.lock                            # 必须为 0
```

脚本步骤 3.6 已内置 lock 文本改写 + 「无 `jni` 且每个 pin 版本/sha256 对上」断言，
所以第一条命令通过就意味着 override 已落进 lock、依赖图不含 jni。`grep` 是可选的
二次确认。Windows 的实际编译只能靠 CI 验证（本机可跑 `flutter build windows` 但
耗时，通常 CI 兜底即可）。

改动 `JNI_FREE_PINS` 或 3.6 的改写逻辑后，务必用下面的方式校验改写结果与真实解析
逐字节一致（CI 上没 Flutter，只能靠本机守这道门）：

```bash
cd .worktrees/windows-only-rebuild && cp pubspec.lock /tmp/textlock.txt \
  && flutter pub get >/dev/null && diff /tmp/textlock.txt pubspec.lock && echo 一致
```

补丁无法应用 → 现场保留在 `.worktrees/windows-only-rebuild`：
`git apply --3way ../windows_only/patches/xxx.patch` 辅助重做 → 更新补丁 →
重跑验证 → push。

## 7. 故障处理

| 症状 | 处理 |
|---|---|
| CI `sync` 正常但 `build` 失败 | 与裁剪无关，按普通 Flutter 报错排查 `build` job 日志 |
| 补丁 apply 失败（`sync` 中止，日志指出哪个补丁） | 按 §6 的 `--3way` 流程重做 |
| 构建缓存把旧依赖解析/过期工具链路径带回来（如 jni 的 `jvm.lib` LNK1181） | 删 `flutter-*` 构建缓存重跑；根治靠两条：缓存路径**只放 `build/windows`**（绝不缓存 `.dart_tool`），build 步骤先强制 `flutter pub get` 再 build |
| `LNK1181` / `jvm.lib` 反复出现，且 `sync` 日志说 lock 里仍有 `jni` | 分支上的 `pubspec.lock` 没跟上 override —— 确认脚本步骤 3.6 存在且未被绕过（它负责重写 lock 并断言无 `jni`）；若是手工改分支导致，重跑 `build_windows_only.sh` 即可恢复正常 |
| CI `Prepare Flutter deps` 日志里出现 `+ jni` 或某个 `* xxx_android 2.x (was 旧版)` | `JNI_FREE_PINS` 漏了来源。用 `curl https://pub.flutter-io.cn/api/packages/<包>` 二分版本找出「首个带 jni 的版本」与「最后一个干净的版本」，往表里加一行（连 sha256），重推 |
| `flutter build windows` 报 `unable to find directory entry in pubspec.yaml: assets/data` | `assets/data/` 下 5 个资源在 `.gitignore` 里，干净 checkout 无该目录，只由 `setup.dart` 的 `ensureAssets()` 下载（挂在 core 构建上）；Core 缓存命中跳过 Build Core 时目录就从未创建。workflow 的 `Ensure downloaded assets`（`dart setup.dart assets`）已无条件兜底，与缓存无关 |
| `.worktrees/` 残留 | `git worktree remove --force .worktrees/<名> && git worktree prune`（脚本下次运行也会自动清理） |

## 8. 硬性规则

- 功能代码只在 main 上改；windows-only 分支是生成物，本地改动无意义。
- `windows_only/patches/*.patch` 手工维护：目标文件在 main 必须保持未改；
  若不得不改 → 同步重做补丁。
- 删文件/目录 → `delete_manifest.txt` 加行；行级摘除 → 手工补丁；运行时判断不删。
- l10n key 用「追加」，不改写上游已有文案（减小 rebase 冲突面）。
- 新功能尽量独立成文件，少改上游已有文件。
