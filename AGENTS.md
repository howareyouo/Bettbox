# AGENTS.md — Bettbox fork AI 协作指南

> 本文件是 AI 协作者的操作基线（由 `windows_only/windows_only_pipeline.md` 迁入），
> 人类读者同样适用。改动本文件与改代码一样，正常提交、push 到 main 即生效。

## 1. 仓库角色

| 项 | 值 |
|---|---|
| fork（origin） | `https://github.com/howareyouo/Bettbox.git` |
| upstream | `https://github.com/appshubcc/Bettbox.git`（只读，仅 `git fetch`，永不 merge） |
| 本地工作区 | `G:/bettbox`（Windows，Flutter 3.47.7 / Dart 3.13.5） |
| `main` | fork 功能开发主线（上游基线 + 自有提交），**唯一事实来源** |
| `windows-only` 分支 | **CI 生成产物分支**，随时可 force-push 重写；本地修改它没有意义 |

## 2. 裁剪架构（核心思想）

**生成型同步，而非维护型**：不维护"持续演化的 windows-only 分支"，每次从 main 干净重建。

```
main 上的开发/提交（含 rebase 上游）
   │
   ▼
build_windows_only.sh（裁剪脚本，幂等）
   ├─ 以 main 为基线建干净 worktree
   ├─ 按 delete_manifest.txt 删除非 Windows 文件/目录
   ├─ 应用 patches/*.patch（手工裁剪补丁）
   ├─ 记录源 SHA（.source-sha）
   └─ commit → push 到 windows-only 分支（无历史包袱）
   ▼
GitHub Actions：flutter build windows → 发布 Release windows-only-<main SHA>
```

关键性质：windows-only 每次从干净基线重建，与 main 严格一致（除裁剪项），
不存在"某改动忘了带进 windows-only"；上游同步只发生在「rebase main」，
CI 全程不感知 upstream。

**无功能清单**：main 的全部代码自动进入 windows-only。历史上曾有
`own_files.txt` 清单 + `auto_export.sh` 补丁导出机制，已整体移除，**勿复活**。

### 关键文件

| 文件 | 职责 |
|---|---|
| `.github/workflows/windows_only.yml` | CI：push main / cron（每日，兼失败重试）/ 手动 → 重建 windows-only → 构建发布（`sync` + `build` 两个 job） |
| `windows_only/build_windows_only.sh` | 裁剪脚本：`build_windows_only.sh [源 ref，默认 main] [输出分支，默认 windows-only-rebuild]`；退出码 `2` = 补丁无法应用（现场保留在 `.worktrees/`） |
| `windows_only/delete_manifest.txt` | 删除清单：每行一个 `git rm` 目标，`#` 注释 |
| `windows_only/patches/*.patch` | 手工裁剪补丁（目前仅 `strip_iperf_scan.patch`） |

Flutter 版本由 CI 从 main 的 `.github/workflows/build.yaml` pin 解析（兜底读 pubspec），
rebase 上游时自动跟进，无需手动指定。

### delete_manifest 分层原则

1. **目录级删除**：`android/` `ios/` `linux/` `macos/` `web/` 等平台目录。
2. **文件级删除**：`lib/pages/scan.dart` 等依赖无 Windows 实现插件的源码。
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
| 调整裁剪/构建/CI 脚本 | 直接改，改完按 §6 验证 |

## 6. 验证（改动涉及裁剪时必做）

```bash
bash windows_only/build_windows_only.sh main windows-only-rebuild
# 通过后：
cd .worktrees/windows-only-rebuild && flutter analyze    # 零问题即安全
```

补丁无法应用 → 现场保留在 `.worktrees/windows-only-rebuild`：
`git apply --3way ../windows_only/patches/xxx.patch` 辅助重做 → 更新补丁 →
重跑验证 → push。

## 7. 故障处理

| 症状 | 处理 |
|---|---|
| CI `sync` 正常但 `build` 失败 | 与裁剪无关，按普通 Flutter 报错排查 `build` job 日志 |
| 补丁 apply 失败（`sync` 中止，日志指出哪个补丁） | 按 §6 的 `--3way` 流程重做 |
| `.worktrees/` 残留 | `git worktree remove --force .worktrees/<名> && git worktree prune`（脚本下次运行也会自动清理） |

## 8. 硬性规则

- 功能代码只在 main 上改；windows-only 分支是生成物，本地改动无意义。
- `windows_only/patches/*.patch` 手工维护：目标文件在 main 必须保持未改；
  若不得不改 → 同步重做补丁。
- 删文件/目录 → `delete_manifest.txt` 加行；行级摘除 → 手工补丁；运行时判断不删。
- l10n key 用「追加」，不改写上游已有文案（减小 rebase 冲突面）。
- 新功能尽量独立成文件，少改上游已有文件。
