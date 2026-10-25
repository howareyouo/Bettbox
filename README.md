<h1 align="center">⚡ Bettbox · Windows</h1>

这是 [Bettbox](https://github.com/appshubcc/Bettbox) 的 Windows 定向 fork，基于上游持续更新。此仓库主要增加 Windows 专属交互与构建发布流程；Windows-only 发布版由 CI 从本 fork 的 `main` 自动裁剪生成，裁去非 Windows 平台文件。上游项目本身仍是多平台项目。

## Fork 改动

- **Windows-only 发布**：CI 从 fork `main` 干净重建（删除非 Windows 平台文件、应用少量手工裁剪补丁），并自动构建发布。
- **外部编辑器**：可使用外部编辑器修改配置或脚本。
- **配置查看**：提供配置/订阅内容的只读查看页面。
- **资料卡交互**：增加拖拽排序与悬停预览。
- **桌面操作与样式**：支持鼠标侧键进行页面前进/后退，并调整部分 Windows 界面样式。

## 平台精简

Windows-only 构建会删除 Android、iOS、Linux、macOS、Web 平台目录及移动端扫码页面，因此该生成版本面向 Windows；本 fork 的 `main` 开发分支仍以完整上游代码为基础。

## 下载与构建

- Windows-only 自动构建产物：查看本仓库的 [Releases](https://github.com/howareyouo/Bettbox/releases) 和 [`windows-only` 分支](https://github.com/howareyouo/Bettbox/tree/windows-only)。
- 构建流程说明与 AI 协作指南：[`AGENTS.md`](AGENTS.md)。流水线从 fork `main` 干净重建：按裁剪清单删除非 Windows 文件、应用手工补丁，再构建发布。

## 上游与许可

本 fork 基于 [appshubcc/Bettbox](https://github.com/appshubcc/Bettbox)，使用 [Mihomo](https://github.com/MetaCubeX/mihomo) 核心。感谢上游及相关开源项目的贡献。本项目遵循 [GPL-3.0](LICENSE)。
