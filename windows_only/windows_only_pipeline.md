# Bettbox fork「Windows-only 流水线」架构文档

> 本文档描述 fork（`howareyouo/Bettbox`）如何在上游（`appshubcc/Bettbox`）持续更新的前提下，
> 维护一个**物理删除了非 Windows 代码**的 Windows-only 版本，并自动构建发布。
> 用途：让人类/AI 协作者快速理解架构、执行流程、排查故障。

---

## 1. 核心思想：生成型同步（Generate-type），而非维护型（Maintain-type)

**问题**：如果维护一个"持续演化的 windows-only 分支"，上游每次改动都要 merge 进这个分支，
删除代码和上游改动会不断冲突，越积越多。

**解法**：**不维护删除版历史，每次从上游重新生成**。

```
上游更新
   │  git fetch upstream          ← 永远只 fetch，不 merge，零冲突
   ▼
build_windows_only.sh（裁剪脚本，幂等）
   ├─ 以 upstream/main 为基线建干净 worktree
   ├─ 按 delete_manifest.txt 删除非 Windows 文件/目录
   ├─ 应用 windows_only_patches/*.patch（自有功能）
   ├─ 记录上游 SHA（.upstream-sha）
   └─ commit → push 到 windows-only 分支（无历史包袱）
   ▼
GitHub Actions：flutter build windows → 发布 Release
```

**关键性质**：windows-only 分支每次从干净基线重建，**没有跨版本历史**，
因此上游怎么改都不会积累冲突。冲突只可能来自"补丁本身无法应用到最新上游"——这是
这套架构唯一需要人工介入的场景（见 §6.3）。

---

## 2. 仓库拓扑

| 项 | 值 |
|---|---|
| fork（origin） | `https://github.com/howareyouo/Bettbox.git` |
| upstream | `https://github.com/appshubcc/Bettbox.git` |
| 本地工作区 | `G:/bettbox`（Windows，Flutter 3.47.7 / Dart 3.13.5） |
| 本地 `main` | fork 功能开发主线（基于某个上游基线 + 自有提交） |
| `upstream/main` 引用 | 只读镜像，仅 `git fetch` 更新，永不 merge 到 main |
| `windows-only` 分支 | **CI 生成产物分支，可随时 force-push 重写** |

### 分支角色

- **`main`（fork）**：你自己的开发工作台。加功能、改代码在这里正常进行；
  日常保持基于某个上游基线 + 功能提交。不必追着上游每次提交同步。
- **`windows-only`（fork）**：纯生成物。CI 每次从 `upstream/main` 重建并 force-push。
  本地修改此分支没有意义（下次重建即覆盖）。
- **`upstream/dev`、`upstream/test`、`upstream/main`**：只读，仅 fetch。

---

## 3. 关键文件与职责

```
.github/workflows/windows-only.yml      CI 自动化（cron 轮询 + 手动触发 + 构建发布）
windows_only/
  build_windows_only.sh                 裁剪脚本：重建 windows-only 分支（幂等）
  delete_manifest.txt                   删除清单：需要物理删除的文件/目录
  export_patch.sh                       导出主脚本：把 main 上的功能变成补丁
  windows_only_patches/
    external_editor.patch               自有功能①：Set Editor 外部编辑器（12 文件）
    strip_scan_page.patch               裁剪配套：摘除对已删 scan.dart 的引用
```

### 3.1 `.github/workflows/windows-only.yml`

两个 job：

| Job | Runner | 做什么 |
|---|---|---|
| `sync` | ubuntu | 对比 `upstream/main` SHA 与 windows-only 分支记录的 `.upstream-sha`；有变化则跑 `build_windows_only.sh` 并 force-push 到 `windows-only` |
| `build` | windows | `flutter build windows --release` → 打 zip → 上传 artifact → 创建 Release（tag `windows-only-<上游SHA>`） |

触发方式：`cron: '17 */2 * * *'`（每 2 小时）+ `workflow_dispatch`（手动）。
无上游变化时 `sync` 快速退出，`build` 通过 `needs` + `if changed == true` 跳过，不烧时间。

### 3.2 `windows_only/build_windows_only.sh`

用法：`windows_only/build_windows_only.sh [upstream-ref] [输出分支名]`（默认 `upstream/main` / `windows-only-rebuild`）

流程：清理旧 worktree → 从 upstream-ref 建新 worktree → 按清单 `git rm` → 依次 `git apply` 补丁
（先 `--check` 全部校验，任一失败即中止并**保留现场**）→ 写 `.upstream-sha` → commit。

退出码：`0` 成功；`1` 前置校验失败；`2` 补丁无法应用（现场保留在 `.worktrees/` 下）。

### 3.3 `windows_only/delete_manifest.txt`

每行一个 `git rm` 目标，`#` 注释。两种删除层级：

| 层级 | 例子 | 说明 |
|---|---|---|
| 目录级 | `android/` `ios/` `linux/` `macos/` `web/` | 平台构建目录，Windows 用不到 |
| 文件级 | `lib/pages/scan.dart` | 移动端专属源码（依赖 mobile_scanner） |

**设计决策（为什么不删 Platform.is* / isAndroidTV）**：`Platform.is*`（30 处）与
`isAndroidTV`（48 处）是运行时判断，Windows 上恒为 false，行为天然正确；
删了反而扩大与上游的冲突面。**只删"文件/目录"，不删"运行时分支"**——这是分层
裁剪的关键：硬删除只发生在文件粒度，行级诉求用补丁。

### 3.4 `windows_only/export_patch.sh`（你的功能 → 补丁的入口）

用法二选一：

```bash
# A. 按提交范围导出（推荐，功能是独立提交时）
windows_only/export_patch.sh feature_my_thing 8ae54f3..HEAD
# B. 按文件路径导出（改动散落/未提交时）
windows_only/export_patch.sh feature_my_thing upstream/main -- lib/xxx.dart lib/yyy.dart
```

自动：生成 `windows_only/windows_only_patches/<名>.patch` → 在干净基线 worktree 上
`git apply --check` 自验证 → 已有同名文件时先备份 `.bak`。

### 3.5 已有补丁内容

- **`external_editor.patch`**：Set Editor 功能（外部编辑器选择/启动/文件监听自动同步）。
  涉及 l10n（en/zh_CN）、config 模型、scripts 页面等 12 个文件。
  补丁基于**旧上游基线 `8ae54f3`** 导出。
- **`strip_scan_page.patch`**：删除 `lib/pages/scan.dart` 后，摘除 `pages.dart` 的 export
  与 `add_profile.dart` 的 import + 移动端 QR 分支。

---

## 4. 工作流程

### 4.1 上游发布新版本（自动，通常无需人工）

1. cron 每 2 小时（或手动 Run workflow）检查上游。
2. 上游 SHA 变化 → `sync` 重建分支 → `build` 构建发布。
3. 产物：Actions artifact + Release `windows-only-<上游SHA>`。
4. 若补丁 apply 失败：构建中止，**工作区保留**，日志提示是哪个补丁失败（见 §6.3）。

### 4.2 你加一个新功能（手动，核心流程）

```bash
# 1) 在 main 上正常开发、测试、提交
git commit -m "feat(xxx): my feature"

# 2) 导出为流水线补丁
windows_only/export_patch.sh feature_my_thing <提交范围>     # 或路径模式

# 3) 提交补丁文件本身
git add windows_only/windows_only_patches/feature_my_thing.patch
git commit -m "feat(windows_only): add xxx patch"
git push origin main
```

补丁进入 `windows_only_patches/` 后，下次流水线重建自动带上。

**要点**：
- 新功能尽量做成**独立文件**（如 `lib/common/external_editor.dart`），少改上游已有文件 → 冲突面小。
- 补丁按字母序应用，同名覆盖前自动备份 `.bak`。

### 4.3 修改/删除已有功能

- **修改**：改完 main → 重新导出覆盖同名补丁。
- **删除功能**：删掉对应 `.patch` 文件。
- **删除文件/目录**：往 `delete_manifest.txt` 加一行。

### 4.4 fork main 是否要跟上新上游？

**不必**。补丁按"提交范围"导出（模式 A），不依赖 main 的位置。
但建议偶尔（`git fetch upstream && git rebase upstream/main`）把 main 挪到新基线上，
让未来重导补丁时的基准更近。可选，非必需。

---

## 5. 命令速查

```bash
# 查看上游是否有更新
git fetch upstream && git log --oneline main..upstream/main

# 本地重建 windows-only 分支（验证用，不 push）
bash windows_only/build_windows_only.sh upstream/main windows-only-rebuild

# 导入新功能为补丁（模式 A：按提交范围）
windows_only/export_patch.sh feature_name <A>..HEAD

# 导入新功能为补丁（模式 B：按路径）
windows_only/export_patch.sh feature_name upstream/main -- <路径...>

# 手动触发 CI（等同 cron）
#   GitHub → fork 仓库 → Actions → windows-only sync & build → Run workflow

# 查看当前上游基线
git rev-parse upstream/main && cat <windows-only 分支的 .upstream-sha>
```

---

## 6. 故障处理

### 6.1 CI `sync` 正常但 `build` 失败

构建错误（pub get / compile / 打包）与架构无关，按普通 Flutter 报错排查。
`build` job 的日志会指明失败步骤。

### 6.2 上游 force-push / rebase 了历史

上游偶尔会重写历史（如 v1.19.6：`8ae54f3 → 9582976`）。CI 用 SHA 对比，
只看 `upstream/main` 当前指向，天然免疫于历史重写。本地 `git fetch upstream`
后直接跑脚本即可。

### 6.3 补丁 apply 失败（唯一必须人工的场景）

症状：CI `sync` 中止，日志："补丁无法应用: xxx.patch"。

原因：上游改动了补丁涉及的文件（l10n / config / scripts.dart 等），上下文对不上。

处理：
```bash
# 1) 在报错保留的 worktree 里看冲突
cd .worktrees/<输出分支> && git apply --3way ../windows_only/windows_only_patches/xxx.patch
# 2) 或：基于新上游重做该功能后重新导出
git fetch upstream
git rebase upstream/main        # 解决冲突（生成文件冲突直接 checkout --ours + 重跑 build_runner）
windows_only/export_patch.sh xxx <新基线>..HEAD
# 3) 手动 Run workflow 重试
```

**预防**：功能尽量独立成文件；l10n key 用"追加"而非"改写"上游已有文案。

### 6.4 `.worktrees/` 残留

`build_windows_only.sh` 每次清理重建；异常退出可能残留。
清理：`git worktree remove --force .worktrees/<名> && git worktree prune`。

---

## 7. 当前状态快照（2026-10-16）

| 项 | 值 |
|---|---|
| fork main HEAD | `2be0c14`（merge upstream/main） |
| 上游基线（upstream/main） | `8ce0b28`（v1.19.6 重发：禁用 signpath + 修 appimage） |
| 补丁基线 | 已验证补丁可应用于 `8ce0b28`（本地 e2e 重建通过） |
| windows-only 分支 | 尚未创建（首次 CI 运行时生成） |
| 自有功能 | 外部编辑器（external_editor.patch）、悬停预览（profile_hover.patch） |
| 自动导出 | `export_patches.yml`（push 触发）按 `own_files.txt` 清单导出补丁并提交回 main |

本地 main 提交链（自上而下）：
```
2be0c14  Merge remote-tracking branch 'upstream/main'
b829227  chore(windows_only): auto-export patches [skip ci]
bf0584b  feat(windows_only): take over external_editor auto-export via manifest
411cf79  move: tools/ -> windows_only/
…（更早提交略）
```

---

## 8. 给 AI 协作者的操作基线

- `windows_only/` 下所有改动都要提交到 fork main 才会生效（CI 从 fork main 的分支读取工作流与补丁）。
- 修补丁 vs 修功能：功能代码在 `main` 上改，补丁文件**只通过 `export_patch.sh` 重新生成**，
  不要手改 `.patch` 内容。
- `delete_manifest.txt` 加行 = 删除文件；删 `.patch` = 删功能；两者都立即生效于下次重建。
- 验证一件事是否会影响 windows-only：本地跑
  `bash windows_only/build_windows_only.sh upstream/main windows-only-rebuild && cd .worktrees/windows-only-rebuild && flutter analyze`
  零问题即安全。