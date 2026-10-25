---
name: windows_only
description: >
  Bettbox fork 的 windows_only 流水线维护。windows-only 分支 = fork main 的裁剪版
  （delete_manifest 删除 + 手工补丁摘除），无功能清单。当改动涉及 windows_only/ 下的
  裁剪脚本、delete_manifest.txt、patches/*.patch，或 main 的改动引用了被裁剪删除的
  文件（如 scan.dart）、删除/重命名了裁剪清单里的路径、上游重构了补丁目标文件时使用：
  负责维护裁剪清单与手工补丁，本地验证重建。
---

# windows_only 裁剪流水线维护

本仓库是 fork（origin `howareyouo/Bettbox`，upstream `appshubcc/Bettbox`）。
windows-only 分支**完全由 fork main 生成**：CI（`windows_only.yml`）在 main 变化时跑
`build_windows_only.sh`，按 `delete_manifest.txt` 删除非 Windows 文件、应用
`patches/*.patch` 手工裁剪补丁，然后构建发布 Release。

**没有功能清单**：main 上的全部代码都会进入 windows-only，不需要登记、导出或同步
任何「自有功能」文件列表（旧的 own_files.txt 机制已移除）。

## 触发时机（仅以下场景需要动 windows_only/）

1. **main 代码引用了被 delete_manifest 删除的文件**（如上游新页面引用 `scan.dart`）：
   优先在 main 里优雅解决（运行时判断、条件导入）；确需 windows-only 摘除的，
   新增一个手工补丁 `windows_only/patches/<名>.patch`（参照 `strip_iperf_scan.patch`）。
2. **删除/重命名了 delete_manifest 里的路径**：若 main 已永久移除（fork 不再要），
   从清单删掉该行；若只是移动，改行内路径。
3. **改动了补丁的目标文件**（如上游重构 iperf 页）：确认对应补丁仍能应用，
   不能则按新代码重做补丁（见下「验证」）。
4. **调整裁剪/构建/CI 脚本**：直接改，改完本地验证。

## 硬性规则

- **功能代码只在 main 上改**。windows-only 分支是 CI 生成物，本地改动无意义。
- `windows_only/patches/*.patch` 是**手工维护**的裁剪补丁（与自动生成无关）：
  补丁目标文件在 main 上必须保持未改（如 iperf.dart），否则补丁失效；
  若 main 不得不改目标文件，必须同步重做补丁。
- 删除文件/目录 → `delete_manifest.txt` 加行；行级摘除 → 手工补丁。运行时判断
  （`Platform.is*`/`isAndroidTV`）永远保留不删——Windows 上恒为 false，天然正确。
- l10n key 用「追加」，不「改写」上游已有文案（减小 rebase 冲突面）。

## 验证（改动涉及裁剪时做）

```bash
bash windows_only/build_windows_only.sh main windows-only-rebuild
# 通过后可选：cd .worktrees/windows-only-rebuild && flutter analyze
```

补丁无法应用 → 现场保留在 `.worktrees/windows-only-rebuild`，
`git apply --3way ../windows_only/patches/xxx.patch` 辅助重做。
详见根目录 `AGENTS.md`「验证」与「故障处理」。

## 提交

windows_only/ 下的改动与功能代码一起提交、push 到 main 即可，CI 全自动，
无需其他手动步骤。
