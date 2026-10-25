# Bettbox fork「Windows-only 流水线」架构文档

> 本文档描述 fork（`howareyouo/Bettbox`）如何生成并发布 **Windows-only 版本**：
> windows-only 分支是 **fork main 的裁剪产物**（main − 非 Windows 文件 + 少量手工补丁），
> CI 每次从 main 干净重建。用途：让人类/AI 协作者快速理解架构、执行流程、排查故障。

---

## 1. 核心思想：生成型同步（Generate-type），而非维护型（Maintain-type)

**问题**：维护一个"持续演化的 windows-only 分支"，每次改动都要在分支上重复，
历史越积越多、和 main 渐行渐远。

**解法**：**不维护删除版历史，每次从 main 重新生成**。

```
main 上的开发/提交（含 rebase 上游）
   │
   ▼
build_windows_only.sh（裁剪脚本，幂等）
   ├─ 以 main 为基线建干净 worktree
   ├─ 按 delete_manifest.txt 删除非 Windows 文件/目录
   ├─ 应用 patches/*.patch（手工裁剪补丁，如引用摘除）
   ├─ 记录源 SHA（.source-sha）
   └─ commit → push 到 windows-only 分支（无历史包袱）
   ▼
GitHub Actions：flutter build windows → 发布 Release
```

**与上游的关系**：上游同步发生在「rebase main」这一步（冲突在 rebase 时用 3-way
合并解决，有完整代码上下文）；CI 从不接触 upstream remote，windows-only 永远等于
「当前 main 的裁剪版」。

**关键性质**：windows-only 分支每次从干净基线重建，**没有跨版本历史**。
main 与 windows-only 严格一致（除裁剪），不存在"某改动忘了带进 windows-only"的问题。

---

## 2. 仓库拓扑

| 项 | 值 |
|---|---|
| fork（origin） | `https://github.com/howareyouo/Bettbox.git` |
| upstream | `https://github.com/appshubcc/Bettbox.git`（可选只读镜像，仅本地 `git fetch` 用） |
| 本地工作区 | `G:/bettbox`（Windows，Flutter 3.47.7 / Dart 3.13.5） |
| 本地 `main` | fork 功能开发主线（基于上游基线 + 自有提交），**唯一事实来源** |
| `windows-only` 分支 | **CI 生成产物分支，可随时 force-push 重写** |

### 分支角色

- **`main`（fork）**：唯一开发工作台。加功能、rebase 上游都在这里正常进行。
- **`windows-only`（fork）**：纯生成物。CI 每次从 `main` 重建并 force-push。
  本地修改此分支没有意义（下次重建即覆盖）。

---

## 3. 关键文件与职责

```
.github/workflows/windows_only.yml      CI 自动化（push/cron/手动触发：重建 → 构建发布）
windows_only/
  build_windows_only.sh                 裁剪脚本：重建 windows-only 分支（幂等）
  delete_manifest.txt                   删除清单：需要物理删除的文件/目录
  patches/
    strip_iperf_scan.patch              手工补丁：摘除 windows-only 上 iperf 的 scan 引用
```

> 历史：曾有 own_files.txt 清单 + auto_export.sh 按「补丁名 路径」把 fork 对上游文件的
> 改动自动导出为功能补丁（fork 与上游分离时 windows-only 从 upstream/main 重建）。
> fork 改为始终 rebase 跟随上游后，该层失去意义（漏列文件反而静默掉队），已整体移除；
> windows-only 基线改为 fork main。

### 3.1 `.github/workflows/windows_only.yml`

单一 workflow，两个 job：

| Job | Runner | 做什么 |
|---|---|---|
| `sync` | ubuntu | 对比 main HEAD 与 windows-only 分支记录的 `.source-sha`；有变化（或 push/手动强制）则跑 `build_windows_only.sh main` 并 force-push 到 `windows-only` |
| `build` | windows | `flutter build windows --release` → 打 zip → 创建 Release（tag `windows-only-<main SHA>`）。zip 只走 Release，不传 artifact（Actions 下载 artifact 会再套一层同名 zip，Windows 解压冲突） |

触发方式：`cron: '17 21 * * *'`（每日一次，兼作失败重试）+ `push`（main）+
`workflow_dispatch`（手动，`force_build` 可强制构建）。
`concurrency` 串行化，避免两个 run 并发 force-push windows-only。
main 无变化时重建与 build（`needs` + `if changed == true`）跳过。

Flutter 版本由 sync job 从 main 的 `.github/workflows/build.yaml` pin 解析（兜底读
pubspec），rebase 上游时自动跟进。

### 3.2 `windows_only/build_windows_only.sh`

用法：`windows_only/build_windows_only.sh [源 ref] [输出分支名]`（默认 `main` / `windows-only-rebuild`）

流程：清理旧 worktree → 从源 ref 建新 worktree → 按清单 `git rm` → 依次 `git apply`
补丁（先 `--check` 全部校验，任一失败即中止并**保留现场**）→ 写 `.source-sha` → commit。

退出码：`0` 成功；`1` 前置校验失败；`2` 补丁无法应用（现场保留在 `.worktrees/` 下）。

### 3.3 `windows_only/delete_manifest.txt`

每行一个 `git rm` 目标，`#` 注释。两种删除层级：

| 层级 | 例子 | 说明 |
|---|---|---|
| 目录级 | `android/` `ios/` `linux/` `macos/` `web/` | 平台构建目录，Windows 用不到 |
| 文件级 | `lib/pages/scan.dart` | 移动端专属源码（依赖 mobile_scanner） |

**设计决策（为什么不删 Platform.is* / isAndroidTV）**：`Platform.is*`（30 处）与
`isAndroidTV`（48 处）是运行时判断，Windows 上恒为 false，行为天然正确；
删了反而扩大改动面。**只删"文件/目录"，不删"运行时分支"**——硬删除只发生在文件
粒度，行级诉求用手工补丁。

### 3.4 `windows_only/patches/`（手工裁剪补丁）

补丁在**每次重建时应用到 main 的裁剪树**上，用于「main 保留、windows-only 摘除」的
行级差异。目前仅一个：

- **`strip_iperf_scan.patch`**：上游 iperf 工具页（`lib/pages/toolbox/iperf.dart`）
  引用了移动端专属的 `ScanPage`，而 windows-only 分支删除了 `lib/pages/scan.dart`。
  该补丁摘除 iperf 的 scan 引用（import、`_scan()`、`_canScan`、`onScan` 接线，
  改后 `onScan: null`，按钮在 Windows 上本就不显示）。
  **main 自身不修改 iperf.dart**（保留 ScanPage 引用，移动端功能完整）——
  这是补丁能稳定应用的前提。

新增手工补丁的判据：main 上的代码（通常继承自上游）引用了被 delete_manifest 删除的
文件，且可以用运行时判断/留空解决。若能在 main 里优雅解决（条件导入等），优先改
main，避免补丁。

---

## 4. 工作流程

### 4.1 日常：push main 即发布

1. push 到 main → CI 重建 windows-only → 构建 → Release `windows-only-<main SHA>`。
2. 若补丁 apply 失败：构建中止，**工作区保留**，日志提示是哪个补丁失败（见 §6.2）。

### 4.2 跟随上游：rebase main

```bash
git fetch upstream
git rebase upstream/main      # 解决冲突（生成文件冲突直接 checkout --ours + 重跑 build_runner）
git push origin main          # CI 自动重建 + 发布
```

main 与上游的冲突在 rebase 时解决；CI 全程不感知 upstream。

### 4.3 新增/修改手工补丁

1. 改 main 代码或直接编辑 `windows_only/patches/*.patch`（这类补丁是手工维护的，
   与功能代码无绑定关系）。
2. 本地验证：`bash windows_only/build_windows_only.sh main windows-only-rebuild`。
3. push main。

---

## 5. 命令速查

```bash
# 本地重建 windows-only 分支（验证用，不 push）
bash windows_only/build_windows_only.sh main windows-only-rebuild

# 手动触发 CI（等同 cron）
#   GitHub → fork 仓库 → Actions → windows-only sync & build → Run workflow

# 查看当前源基线
git rev-parse main && git show origin/windows-only:.source-sha
```

---

## 6. 故障处理

### 6.1 CI `sync` 正常但 `build` 失败

构建错误（pub get / compile / 打包）与裁剪无关，按普通 Flutter 报错排查。
`build` job 的日志会指明失败步骤。

### 6.2 补丁 apply 失败

症状：`sync` 中止，日志："补丁无法应用: xxx.patch"。

原因：main 改动了补丁涉及的文件（如上游重构了 iperf 页导致上下文对不上）。

处理：
```bash
cd .worktrees/windows-only-rebuild && git apply --3way ../windows_only/patches/xxx.patch
# 按新代码重做摘除 → 更新补丁 → 本地重跑 build_windows_only.sh 验证 → push
```

### 6.3 `.worktrees/` 残留

`build_windows_only.sh` 每次清理重建；异常退出可能残留。
清理：`git worktree remove --force .worktrees/<名> && git worktree prune`。

---

## 7. 给 AI 协作者的操作基线

- 功能开发只在 main 上进行；**没有"功能清单"需要维护**，main 的全部代码都会进入
  windows-only（除 delete_manifest 删除项）。
- 唯一需要同步 windows_only/ 的场景：改动引用了被删文件的上游代码（新增手工补丁）、
  删除/重命名了 delete_manifest 里的路径、或调整裁剪/构建脚本本身。
- `windows_only/patches/*.patch` 是手工维护的裁剪补丁：改动目标文件时确认补丁仍能
  应用（本地跑 build_windows_only.sh 即验证）。
- 验证一件事是否会影响 windows-only：本地跑
  `bash windows_only/build_windows_only.sh main windows-only-rebuild && cd .worktrees/windows-only-rebuild && flutter analyze`
  零问题即安全。
