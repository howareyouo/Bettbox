---
name: windows_only
description: >
  Bettbox fork 的 windows_only 流水线维护。每当添加、修改或删除「自有功能」文件
  （即 windows_only/own_files.txt 清单内或应纳入清单的文件），或新增/删除自有功能、
  改动 l10n/config 等可能与补丁相关的文件时使用：负责同步维护
  windows_only/own_files.txt（补丁清单），不手改 .patch，必要时本地验证导出。
---

# windows_only 补丁清单维护

本仓库是 fork（origin `howareyouo/Bettbox`，upstream `appshubcc/Bettbox`）。
自有功能通过补丁导入 windows-only 分支：`windows_only/own_files.txt` 是**唯一入口**，
CI（`windows_only.yml`，push/cron/手动触发）按它自动导出/删除 `windows_only/windows_only_patches/*.patch`。

## 触发时机

只要本次改动涉及「自有功能」，完成代码修改后**必须**检查并同步 `own_files.txt`：

1. **新增功能**（新文件或成组改动构成一个新功能）：给该功能起一个补丁名（如 `feature_my_thing`），
   在 `own_files.txt` 为其涉及的每个文件加一行 `<补丁名> <相对路径>`。
   功能文件在本次会话中新建或修改过 → 都要列入清单，否则不会被导出为补丁。
2. **修改已有功能**：确认改动文件已在清单内（在 → 不用动清单；不在 → 补上对应行）。
   判断功能归属：改动属于哪个已有补丁名（见清单注释与 `windows_only/windows_only_pipeline.md` §3.5），
   就并入那个补丁名；新功能才用新名字。
3. **删除功能**：从 `own_files.txt` 删掉该补丁名的所有行 → CI 检测空 diff 自动删 `.patch`。
   （删除整个文件/目录则是往 `windows_only/delete_manifest.txt` 加一行，别搞混。）
4. **改的是上游文件但属自有改动**（如 l10n 追加、config 模型扩展）：同样列入清单——
   判据是「这是不是我们 fork 的改动」，不是「文件是不是新建的」。

## 硬性规则

- **绝不手改 `windows_only/windows_only_patches/*.patch`**——它们只由 CI 按 main 代码生成，手改会被覆盖。
- 只列「自有功能」文件，纯上游代码的行级适配不进清单（那是 `strip_scan_page.patch` 一类手工补丁的事，见 pipeline 文档 §3.5）。
- 新功能尽量做成独立文件，少改上游已有文件，减小冲突面。
- l10n key 用「追加」，不「改写」上游已有文案。
- 清单格式：每行 `补丁名 空格 相对路径`，`#` 注释；同一补丁名多行合并为一个 `.patch`。

## 验证（可选，改动较大时做）

```bash
git fetch upstream main
bash windows_only/auto_export.sh        # 本地预演导出，输出 CHANGED / CLEAN
```

导出的补丁需能按字母序批量应用到 upstream/main；失败说明与上游上下文冲突，
参考 `windows_only/windows_only_pipeline.md` §6.3 处理。

## 提交

清单变更与功能代码一起提交即可，例如：

```
feat(windows_only): track xxx patch in manifest
```

push 到 main 后 CI 自动导出补丁并提交回 main，无需其他手动步骤。
