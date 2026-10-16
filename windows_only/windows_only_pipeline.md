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
.github/workflows/export_patches.yml    自动导出：push 到 main 后按清单导出补丁并提交回 main
windows_only/
  build_windows_only.sh                 裁剪脚本：重建 windows-only 分支（幂等）
  delete_manifest.txt                   删除清单：需要物理删除的文件/目录
  own_files.txt                         补丁清单：「补丁名 路径」，自动导出的唯一入口
  auto_export.sh                        自动导出脚本：按 own_files.txt 导出/删除补丁并验证
  windows_only_patches/
    external_editor.patch               自有功能①：Set Editor 外部编辑器（12 文件）
    profile_drag.patch                  自有功能②：profile 卡片拖拽排序（清单 profile_drag）
    profile_hover.patch                 自有功能③：profile 悬停预览（清单 profile_hover）
    profile_viewer.patch                自有功能④：profile 只读查看器（清单 profile_viewer）
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

### 3.4 `windows_only/own_files.txt` + `windows_only/auto_export.sh`（你的功能 → 补丁的唯一入口）

`own_files.txt` 是**补丁清单**：每行「补丁名 <空格> 相对路径」，同一补丁名的多行合并为一个 `.patch`（一功能一补丁）。

- **新增功能**：往 `own_files.txt` 加一行（新功能用新补丁名；属于已有功能就并入该补丁名）→ push 到 main，之后全自动。
- `auto_export.sh` 在 CI（push 触发，`export_patches.yml`）里自动执行：
  1. 对每个补丁名跑 `git diff upstream/main..HEAD -- <路径>` 重新生成 `.patch`
  2. 某补丁名下所有路径都与上游一致（空 diff）→ **删除**该 `.patch`（视为功能已回退）
  3. 有变更时在干净上游 worktree 上**按字母序批量验证**可应用（与 `build_windows_only.sh` 的应用顺序一致，能抓到补丁间依赖冲突）
  4. 通过后提交回 main（`chore(windows_only): auto-export patches [skip ci]`）
- 输出 `CHANGED`（有增删改）/ `CLEAN`（无变化），由 workflow 决定是否提交。
- **不要手改 `.patch`**：补丁只从 main 上的代码生成，手改会在下次导出时被覆盖。
- 本地也可手动跑：`bash windows_only/auto_export.sh`（需先 `git fetch upstream main`）。

### 3.5 已有补丁内容

- **`external_editor.patch`**：Set Editor 功能（外部编辑器选择/启动/文件监听自动同步）。
  涉及 l10n（en/zh_CN）、config 模型、scripts 页面等 12 个文件（清单 `external_editor`）。
- **`profile_hover.patch`**：profile 项悬停效果（清单 `profile_hover`）。
- **scan 引用摘除（已并入 main 代码）**：scan.dart 的引用（`pages.dart` export、
  `add_profile.dart` 的 import + QR 分支）已由 profile viewer 迁移时在 main 自身删净，
  无需再保留裁剪补丁（曾用 strip_scan_page.patch 手工摘除，现已删除）。

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

# 2) 把功能文件加进补丁清单（新功能加新行；属于已有功能就并入该补丁名）
#    vim windows_only/own_files.txt
feature_my_thing lib/common/my_thing.dart

# 3) 提交清单本身并 push → CI 自动导出 + 验证 + 提交补丁回 main
git add windows_only/own_files.txt
git commit -m "feat(windows_only): track xxx patch in manifest"
git push origin main
```

补丁进入 `windows_only_patches/` 后，下次流水线重建自动带上。

**要点**：
- 新功能尽量做成**独立文件**（如 `lib/common/external_editor.dart`），少改上游已有文件 → 冲突面小。
- 补丁按字母序应用（auto_export 的批量验证顺序与之一致）。

### 4.3 修改/删除已有功能

- **修改**：改完 main 的对应文件 → push → auto_export 自动重新导出（输出 CHANGED）。
- **删除功能**：删掉 `own_files.txt` 里该补丁名的行 → push → auto_export 检测空 diff 自动删除对应 `.patch`。
- **删除文件/目录**：往 `delete_manifest.txt` 加一行。

### 4.4 fork main 是否要跟上新上游？

**不必**。补丁按「清单路径 + upstream/main..HEAD」导出，不依赖 main 与上游的相对位置。
但建议偶尔（`git fetch upstream && git rebase upstream/main`）把 main 挪到新基线上，
避免功能代码与上游偏差过大、冲突面扩大。可选，非必需。

---

## 5. 命令速查

```bash
# 查看上游是否有更新
git fetch upstream && git log --oneline main..upstream/main

# 本地重建 windows-only 分支（验证用，不 push）
bash windows_only/build_windows_only.sh upstream/main windows-only-rebuild

# 导入新功能为补丁：own_files.txt 加一行后 push，CI 自动导出
#   手动立即导出（调试用）：bash windows_only/auto_export.sh

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
# 功能修好后 push 到 main → auto_export 自动重新导出
#   （本地立即导出：bash windows_only/auto_export.sh）
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
| fork main HEAD | `21afc66`（CI 缓存优化提交） |
| 上游基线（upstream/main） | `8ce0b28`（v1.19.6 重发：禁用 signpath + 修 appimage） |
| 补丁基线 | auto_export 按 `upstream/main..HEAD` 导出，已验证可应用于 `8ce0b28` |
| windows-only 分支 | 已存在（CI 生成，force-push 维护，`git push --force origin windows-only-rebuild:windows-only`） |
| 自有功能 | 外部编辑器（external_editor.patch）、悬停预览（profile_hover.patch）——均为清单自动导出 |
| 手工补丁 | 无（scan 引用已由 main 自身代码移除；strip_scan_page.patch 已删） |
| 自动导出 | `export_patches.yml`（push 触发）按 `own_files.txt` 清单导出补丁并提交回 main |

本地 main 提交链（自上而下）：
```
21afc66  fix(ci): move GOCACHE env to step level (runner context invalid in job env)
1212c7e  ci(windows_only): make patch export deterministic and fix sync step
5528acb  ci(windows_only): fix auto-export step (multi-line GITHUB_OUTPUT write broke step)
d312d9c  chore(windows_only): auto-export patches [skip ci]
…（更早提交略）
```

---

## 8. 给 AI 协作者的操作基线

- `windows_only/` 下所有改动都要提交到 fork main 才会生效（CI 从 fork main 的分支读取工作流与补丁）。
- 修补丁 vs 修功能：功能代码在 `main` 上改，补丁文件**只由 `auto_export.sh`（按 `own_files.txt` 清单）生成**，
  不要手改 `.patch` 内容。
- `own_files.txt` 加行 = 导出/保留功能；减行 = 删除功能（auto_export 检测空 diff 自动删补丁）；
  `delete_manifest.txt` 加行 = 删除文件；三者都立即生效于下次重建。
- 验证一件事是否会影响 windows-only：本地跑
  `bash windows_only/build_windows_only.sh upstream/main windows-only-rebuild && cd .worktrees/windows-only-rebuild && flutter analyze`
  零问题即安全。