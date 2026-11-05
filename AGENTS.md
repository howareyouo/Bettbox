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
| `desktop-only` 分支 | **CI 生成产物分支**（Windows + macOS），随时可 force-push 重写；本地修改它没有意义 |

产物定位：**只支持 Windows（x64）与 macOS（arm64）**，其余平台在生成层裁掉；
main 本体仍保留全平台代码以最小化 rebase 冲突面。

## 2. 裁剪架构（核心思想）

**生成型同步，而非维护型**：不维护"持续演化的 desktop-only 分支"，每次从 main 干净重建。

```
main 上的开发/提交（含 rebase 上游，全平台代码不动）
   │
   ▼
build_desktop_only.sh（裁剪脚本，幂等）
   ├─ 以 main 为基线建干净 worktree
   ├─ 按 delete_manifest.txt 删除非桌面平台文件/目录（macos/ 保留）
   ├─ 应用 patches/*.patch（手工裁剪补丁）
   ├─ pubspec 追加 dependency_overrides（摘除 Android 专属 jni 依赖链）
   ├─ 记录源 SHA（.source-sha）
   └─ commit → push 到 desktop-only 分支（无历史包袱）
   ▼
GitHub Actions：flutter build windows + flutter build macos
   → 发布 Release desktop-<main SHA>（win zip + mac dmg）
```

关键性质：desktop-only 每次从干净基线重建，与 main 严格一致（除裁剪项），
不存在"某改动忘了带进 desktop-only"；上游同步只发生在「rebase main」，
CI 全程不感知 upstream。

**无功能清单**：main 的全部代码自动进入 desktop-only。历史上曾有
`own_files.txt` 清单 + `auto_export.sh` 补丁导出机制，已整体移除，**勿复活**。

### 关键文件

| 文件 | 职责 |
|---|---|
| `.github/workflows/desktop_only.yml` | CI：push main / 手动 → 重建 desktop-only → 构建发布（`sync` + `build`（Windows） + `build-macos` 三个 job） |
| `desktop/build_desktop_only.sh` | 裁剪脚本：`build_desktop_only.sh [源 ref，默认 main] [输出分支，默认 desktop-only-rebuild]`；退出码 `2` = 补丁无法应用（现场保留在 `.worktrees/`） |
| `desktop/delete_manifest.txt` | 删除清单：每行一个 `git rm` 目标，`#` 注释 |
| `desktop/patches/*.patch` | 手工裁剪补丁（目前仅 `strip_iperf_scan.patch`） |

Flutter 版本由 CI 从 main 的 `.github/workflows/build.yaml` pin 解析（兜底读 pubspec），
rebase 上游时自动跟进，无需手动指定。

### jni 依赖摘除（步骤 3.5）

`path_provider_android` ≥2.3 依赖 `jni`/`jni_flutter`（jnigen 直连方案），其
Windows 垫片在构建期链接 `jvm.lib`（仅 JDK 提供），而桌面端从不调用。脚本往
生成分支的 pubspec 追加 `dependency_overrides: path_provider_android: 2.2.23`
（最后一个无 jni 依赖的版本，path_provider `^2.2.5` 约束内），桌面 CI 从此
不需要 JDK。**脚本侧追加而非补丁文件**：上游 pubspec 变动不会弄断；若上游
自带 `dependency_overrides`，脚本只警告不覆盖。

### delete_manifest 分层原则

1. **目录级删除**：`android/` `ios/` `linux/` `web/` 等平台目录（`macos/` 保留）。
2. **文件级删除**：`lib/pages/scan.dart` 等依赖移动端实现插件的源码。
3. **行级摘除**：main 保留、desktop-only 摘除 → 手工补丁。
4. **运行时判断（`Platform.is*` / `isAndroidTV`）永远保留不删**——桌面上恒为
   false，行为天然正确；删了反而扩大与上游的冲突面。

### 手工补丁（strip_iperf_scan.patch）

上游 iperf 页（`lib/pages/toolbox/iperf.dart`）引用移动端专属 `ScanPage`
（`scan.dart` 已被删除）；补丁摘除其 scan 引用（接线改 `onScan: null`，
按钮在桌面本就不显示）。**main 自身不修改 iperf.dart**——这是补丁能
稳定应用的前提。新增手工补丁的判据：main 代码引用了被删文件，且无法用
运行时判断/条件导入在 main 内解决。

## 3. 流程一：日常开发与发布

1. 在 main 上正常开发、提交，`git push origin main`。
2. CI 自动：重建 desktop-only → 双平台构建 → 发布 Release `desktop-<main SHA>`
   （win zip + mac dmg；旧 Release 不受影响）。
3. **无清单、无补丁导出**，不需要任何登记或同步动作。
4. 手工补丁 apply 失败 → CI 构建中止、现场保留 → 按 §6 处理。
5. macOS job 首跑或上游调整 mac 链路后失败：与裁剪无关，按普通构建报错排查
   `build-macos` job 日志（core 的 darwin 交叉编译、Pod、dmg 打包）。

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

## 5. 例外场景：何时才动 desktop/

以下情况才需要改 `desktop/`，其余改动一概不用：

| 场景 | 动作 |
|---|---|
| main/上游代码引用了被 delete_manifest 删除的文件（如 `scan.dart`） | 优先在 main 内优雅解决（运行时判断、条件导入）；确需摘除 → 新增手工补丁 |
| 改动了补丁目标文件（`iperf.dart`） | main 保持不改它；上游重构逼改 → 按新代码重做 `strip_iperf_scan.patch` |
| 删除/重命名了 delete_manifest 里的路径 | fork 永久移除 → 删清单行；只是移动 → 改行内路径 |
| 上游 pubspec 引入新的「Android 专属且带桌面垫片」依赖 | 比照 jni 先例在脚本步骤 3.5 扩 override |
| 调整裁剪/构建/CI 脚本 | 直接改，改完按 §6 验证 |

## 6. 验证（改动涉及裁剪时必做）

```bash
bash desktop/build_desktop_only.sh main desktop-only-rebuild
# 通过后：
cd .worktrees/desktop-only-rebuild && flutter analyze    # 零问题即安全
```

worktree 内 `flutter pub get` 会按 override 重新解析依赖，顺带验证摘除后
依赖图完整。Windows/macOS 的实际编译只能靠 CI 验证（本机无 macOS 工具链）。

补丁无法应用 → 现场保留在 `.worktrees/desktop-only-rebuild`：
`git apply --3way ../desktop/patches/xxx.patch` 辅助重做 → 更新补丁 →
重跑验证 → push。

## 7. 故障处理

| 症状 | 处理 |
|---|---|
| CI `sync` 正常但 `build`（Windows）失败 | 与裁剪无关，按普通 Flutter 报错排查 `build` job 日志 |
| CI `sync` 正常但 `build-macos` 失败 | 桌面裁剪通常无关；先查 darwin core 编译/Pod/dmg 步骤日志 |
| 补丁 apply 失败（`sync` 中止，日志指出哪个补丁） | 按 §6 的 `--3way` 流程重做 |
| 构建缓存把过期的工具链绝对路径（如 JDK）带回来 | 删 `flutter-*` 构建缓存重跑（jni 已摘除后此坑概率大降） |
| `.worktrees/` 残留 | `git worktree remove --force .worktrees/<名> && git worktree prune`（脚本下次运行也会自动清理） |

## 8. 硬性规则

- 功能代码只在 main 上改；desktop-only 分支是生成物，本地改动无意义。
- `desktop/patches/*.patch` 手工维护：目标文件在 main 必须保持未改；
  若不得不改 → 同步重做补丁。
- 删文件/目录 → `delete_manifest.txt` 加行；行级摘除 → 手工补丁；运行时判断不删。
- l10n key 用「追加」，不改写上游已有文案（减小 rebase 冲突面）。
- 新功能尽量独立成文件，少改上游已有文件。
