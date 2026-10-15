# 配置（Profiles）页面改动说明

> 基线：`upstream/main`（`afcc5cf0`）
> 分支：`dev-win`（`d07ac48f`，领先 26 个提交）
> 范围：仅 `lib/views/profiles/`、`lib/widgets/super_grid.dart`、`lib/common/scroll.dart`、`lib/pages/viewer.dart`、`lib/common/external_editor.dart`、`lib/common/page_navigation_history.dart`、`test/profiles_drag_reorder_pattern_test.dart` 及关联的 `lib/models/config.dart`、`lib/l10n/` 等。

---

## 一、核心变化：配置页从「弹窗排序」改为「内联拖拽」

### 1.1 删除 `ReorderableProfilesSheet` 弹窗

**文件**：`lib/views/profiles/profiles.dart`（删除约 100 行）

- 移除了 `ReorderableProfilesSheet` 整页组件（含 `ReorderableListView.builder`、`proxyDecorator`、`ReorderableDragStartListener`）
- 移除了工具栏上的「排序」按钮（`Icons.sort` + `appLocalizations.sort`）
- 排序方式从「点按钮 → 弹新页 → 拖拽 → 保存」改为「直接在网格里长按拖拽 → 松手自动同步」

### 1.2 引入 `SuperGrid` 内联拖拽

**文件**：`lib/views/profiles/profiles.dart`（新增约 50 行）

```dart
final _gridKey = GlobalKey<SuperGridState>();

void _handleGridUpdate() {
  final children = _gridKey.currentState?.children;
  if (children == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final ids = children
        .map((item) => item.key)
        .whereType<ValueKey<String>>()
        .map((key) => key.value)
        .toList();
    final profiles = globalState.config.profiles;
    if (ids.length != profiles.length) return;
    final profileMap = {for (final profile in profiles) profile.id: profile};
    final sorted = [for (final id in ids) if (profileMap[id] != null) profileMap[id]!];
    if (sorted.length != profiles.length) return;
    // 顺序没变就不写回，避免多余的配置更新
    var isSame = true;
    for (int i = 0; i < ids.length; i++) {
      if (profiles[i].id != ids[i]) { isSame = false; break; }
    }
    if (isSame) return;
    globalState.appController.setProfiles(sorted);
  });
}
```

**关键点**：
- 用 `GlobalKey<SuperGridState>` 持有网格状态，通过 `onUpdate` 回调拿到拖拽后的新顺序
- 顺序未变时**不写回**配置，避免触发多余的 `setProfiles` 和核心重启
- 用 `postFrameCallback` 确保在帧完成后再写回，避免 setState 期间的状态不一致

### 1.3 `SuperGrid` 新增四个配置开关

**文件**：`lib/widgets/super_grid.dart`

| 参数 | 类型 | 配置页取值 | 用途 |
|------|------|-----------|------|
| `wrapCard` | `bool` | `false` | 条目本身已是 `ProfileItem`（内含 `CommonCard`），不再外层包裹，避免卡片套卡片 |
| `shake` | `bool` | `false` | 关闭静止时的抖动动效（首页编辑模式的提示动效，配置页不需要） |
| `absorbItem` | `bool` | `false` | 不拦截条目自身的指针事件，让 `ProfileItem` 的 `onTap` 能正常响应（切换当前配置） |
| `mouseDragSlop` | `double?` | `8` | 鼠标拖拽启动阈值 8 逻辑像素，解决「点不动」问题 |

**`mouseDragSlop` 的必要性**：
- 框架对鼠标这类精确指针的 hit slop 只有 `kPrecisePointerHitSlop`（1 逻辑像素）
- 按下时手抖一两个像素就会被判成拖拽，拖拽识别器赢下手势竞技场后条目的点击被取消
- 配置页的卡片需要点击切换当前配置，所以必须放宽这个阈值
- 实现：新增 `_PointerSlopDraggable` / `_PointerSlopMultiDragGestureRecognizer` / `_PointerSlopPointerState`，重写 `checkForResolutionAfterMove`，取 `max(slop, computeHitSlop(kind, gestureSettings))` 作为阈值

### 1.4 `SuperGrid` 让位动画节流策略重写

**文件**：`lib/widgets/super_grid.dart`

| 旧行为 | 新行为 |
|--------|--------|
| 600ms 防抖（`debouncer.call(FunctionTag.handleWill, ...)`） | 首帧立即响应，按「上一次动画是否跑完」节流 |
| 指针连续划过卡片时每张都重置计时，动画要等指针停下 600ms 才出现 | 节流期间的最新目标在动画结束后补执行一次 |
| 手感「拖不动」 | 指针划过时卡片立即让位，流畅跟随 |

```dart
bool _reordering = false;
int? _pendingWillIndex;

void _scheduleWill(int index) {
  if (_reordering) {
    _pendingWillIndex = index;
    return;
  }
  _reordering = true;
  unawaited(_handleWill(index).whenComplete(() {
    _reordering = false;
    final pending = _pendingWillIndex;
    _pendingWillIndex = null;
    if (pending != null) _scheduleWill(pending);
  }));
}
```

### 1.5 `SuperGrid` 弹簧阻尼修正

**文件**：`lib/widgets/super_grid.dart`

- 旧：`SpringDescription(mass: 1, stiffness: 100, damping: 10)`，阻尼比约 0.5，明显过冲回弹
- 新：`SpringDescription.withDampingRatio(mass: 1, stiffness: 300, ratio: 0.8)`，轻微过冲后快速收敛

### 1.6 `SuperGrid` 让位动画曲线修正

- 旧：线性 `Tween` 到终点，观感「急停」
- 新：`Curves.easeOutCubic` 的 `CurveTween`，自然减速

### 1.7 `SuperGrid` 拖拽反馈层加 `RepaintBoundary`

- 拖拽反馈卡片（`feedback`）外层包 `RepaintBoundary`，每帧只更新 `Transform` 图层，卡片内容走缓存图层，避免动画期间整页卡片子树重绘

### 1.8 `SuperGrid` 外部同步（`didUpdateWidget`）

```dart
@override
void didUpdateWidget(SuperGrid oldWidget) {
  super.didUpdateWidget(oldWidget);
  final nextChildren = widget.children;
  final currentChildren = _childrenNotifier.value;
  if (identical(nextChildren, currentChildren)) return;
  if (!_hasComparableKeys(nextChildren) && !_hasComparableKeys(currentChildren)) return;
  if (_animating.value || _dragIndexNotifier.value != -1) return;
  _childrenNotifier.value = nextChildren;
  _initState();
}
```

**用途**：配置页点击切换当前配置时，`ProfileItem` 的 `groupValue` 变化，`GridItem` 内容变了但 key 序列不变，必须把新内容同步下来刷新高亮。

---

## 二、配置预览：从内置编辑器改为只读查看器

### 2.1 新增 `ViewerPage`

**文件**：`lib/pages/viewer.dart`（新建，42 行）

- 只读 `SelectableText`，等宽字体（`monospace`）
- 工具栏「复制全文」按钮（`Icons.copy_all_rounded` + `Clipboard.setData`）
- 无保存、无编辑、无撤销/重做

### 2.2 `EditProfileView` 从「编辑」改为「查看」

**文件**：`lib/views/profiles/edit_profile.dart`

- 删除 `_handleSaveEdit`（含 `clashCore.validateConfig` + `utils.patchValidateConfig` 校验逻辑）
- 删除 `_editProfileFile`（含 `EditorPage` 的 `onSave` / `onPop` 确认未保存变更）
- 新增 `_viewProfileFile`：直接 `BaseNavigator.push(ViewerPage(...), maintainState: false)`
- 「编辑」按钮（`CommonChip`）文案改为「查看」
- 导入 `viewer.dart` 替代 `editor.dart`

### 2.3 `AddProfileView` 移除二维码扫码入口

**文件**：`lib/views/profiles/add_profile.dart`

- 删除 `_toScan()` 方法（含桌面 `addProfileFormQrCode`、Android TV `TvQrImportDialog`、移动端 `ScanPage` 三路分支）
- 删除「扫码」`ListItem` 入口
- 仅保留「剪贴板」和「URL/文件」两种添加方式

---

## 三、脚本页：外部编辑器集成

### 3.1 新增 `external_editor.dart` 工具库

**文件**：`lib/common/external_editor.dart`（新建，57 行）

| 函数/常量 | 说明 |
|-----------|------|
| `externalEditorCandidates` | 候选编辑器列表：`['code', 'subl', 'codium', 'notepad++']` |
| `externalEditorDescriptions` | 显示名映射：`code → VS Code`、`subl → Sublime Text` 等 |
| `externalEditorLabel(command)` | 返回 `code (VS Code)` 格式的显示标签 |
| `detectExternalEditors()` | 用 `Process.run('where', [command])` 检测 PATH 上哪些编辑器可用 |
| `launchExternalEditor(path, configured)` | 用 `cmd /c` 启动编辑器（`.cmd` shim 必须经 `cmd` 才能执行），失败返回 `false` |

### 3.2 脚本页工具栏新增「外部编辑器」按钮

**文件**：`lib/views/profiles/scripts.dart`

- 工具栏新增 `IconButton(Icons.edit_note, tooltip: externalEditor)`
- 点击弹出 `_ExternalEditorDialog`：自动检测可用编辑器、自定义命令输入
- 选择后写入 `appSettingProvider.externalEditor` 持久化

### 3.3 脚本编辑流程：从内置编辑器改为外部编辑器

**文件**：`lib/views/profiles/scripts.dart`

| 旧流程 | 新流程 |
|--------|--------|
| `_handleToEditor()` → `EditorPage`（内置代码编辑器） | `_handleExternalEdit()` → 写文件到 `~/scripts/<id>.js` → 用 `cmd /c` 启动外部编辑器 |
| 在 App 内编辑、保存、校验 | 外部编辑器修改后，`FileSystemWatcher` 监听文件变化，600ms 防抖后自动同步回 App |
| 保存时调用 `clashCore.validateConfig` 校验 | 不再在 App 内校验，依赖外部编辑器的语法检查 |
| 保存时 `JavaScriptRuntimeManager.invalidateCachedOptions` | 文件变化时同样调用 `invalidateCachedOptions` |

### 3.4 非阻塞文件监听

**文件**：`lib/views/profiles/scripts.dart`

```dart
final Map<String, StreamSubscription<FileSystemEvent>> _editSubscriptions = {};
final Map<String, Timer> _editDebounces = {};

@override
void dispose() {
  for (final subscription in _editSubscriptions.values) subscription.cancel();
  for (final timer in _editDebounces.values) timer.cancel();
  super.dispose();
}
```

- 每个脚本文件一个 `FileSystemWatcher`，监听 `modify | create | move` 事件
- 600ms 防抖（避免编辑器自动保存时多次触发）
- `dispose` 时全部取消，防止内存泄漏
- 同步时检查 `mounted`，防止 App 已销毁后 setState

### 3.5 脚本设置弹窗新增「全局脚本覆写」

**文件**：`lib/views/profiles/scripts.dart`

- `_ScriptSettingsSheet`：列出所有配置，每个配置一个 `Switch` 控制 `useScriptOverride`
- 顶部固定 `_ExternalEditorCard`（显示当前外部编辑器设置，点击可修改）
- 切换 `useScriptOverride` 时若当前配置被切换，立即 `applyProfile(silence: true)`

### 3.6 配置模型新增 `externalEditor` 字段

**文件**：`lib/models/config.dart`

```dart
@Default('') String externalEditor,
```

- 类型 `String`，默认空字符串（空 = 自动检测）
- 写入 `appSettingProvider` 持久化

### 3.7 新增本地化字符串

**文件**：`arb/intl_en.arb`、`arb/intl_zh_CN.arb`

| key | 英文 | 中文 |
|-----|------|------|
| `externalEditorTip` | Opened in an external editor. Changes are synced back to the app automatically when you save the file. | 已在外部编辑器中打开，保存文件后将自动同步到应用 |
| `externalEditor` | External Editor | 外部编辑器 |
| `autoDetect` | Auto Detect | 自动检测 |
| `done` | Done | 完成 |

---

## 四、滚动行为：禁用鼠标拖拽滚动

### 4.1 新增 `NoMouseDragScrollBehavior`

**文件**：`lib/common/scroll.dart`

```dart
class NoMouseDragScrollBehavior extends BaseScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.unknown,
  };
}
```

**用途**：配置页的 `SingleChildScrollView` 外层包 `ScrollConfiguration(behavior: NoMouseDragScrollBehavior(...))`，禁用鼠标拖拽滚动，让鼠标拖拽事件能被 `SuperGrid` 的拖拽识别器捕获。

---

## 五、回归测试

### 5.1 新增 `profiles_drag_reorder_pattern_test.dart`

**文件**：`test/profiles_drag_reorder_pattern_test.dart`（209 行）

| 测试 | 验证点 |
|------|--------|
| `item still receives taps` | 鼠标拖拽阈值放宽后，普通点击仍能触发 `onTap` |
| `selection highlight follows the tap` | key 顺序不变但内容（选中高亮）变化时，`didUpdateWidget` 同步新内容，高亮刷新 |
| `drag reorders and reports the new order` | 鼠标拖拽 → 让位动画 → 松手落位 → `onUpdate` 回调新顺序，且卡片高度顺序与布局一致（无回跳） |

**测试技巧**：
- 用 `runAsync` + `Future.delayed` 让真实定时器走完，`pump` 把动画推到终点
- 用 `GlobalKey<SuperGridState>` 在测试中读取 `children` 列表

---

## 六、其他关联改动

### 6.1 页签导航历史

**文件**：`lib/common/page_navigation_history.dart`（新建，60 行）

- `PageNavigationHistory` 类，模拟浏览器前进/后退
- `visit()` 记录访问，截断前进项
- `back()` / `forward()` 在历史范围内移动
- 最大长度 30，超出淘汰最旧项
- 用于鼠标侧键导航（`kBackMouseButton` / `kForwardMouseButton`）

### 6.2 配置页预览从 `EditorPage` 改为 `ViewerPage`

**文件**：`lib/views/profiles/profiles.dart`

```dart
// 旧：EditorPage(readOnly: true) —— 内置编辑器，带保存/撤销逻辑
// 新：ViewerPage —— 只读查看，复制全文
final previewPage = ViewerPage(
  title: '${appLocalizations.runtimeConfig} - ${profile.label ?? profile.id}',
  content: content,
);
```

### 6.3 导出文件清理

**文件**：`lib/pages/pages.dart`、`lib/views/views.dart`

- 移除 `export 'scan.dart'`、`export 'editor.dart'`、`export 'media_unlock.dart'`、`export 'access.dart'`
- 新增 `export 'viewer.dart'`

---

## 七、AI 后续实现要点（Checklist）

当在后续版本中需要重新实现或迁移配置页时，按以下顺序检查：

### 7.1 拖拽排序

- [ ] 用 `SuperGrid` 替代 `ReorderableListView` / `Grid` 实现网格
- [ ] 设置 `wrapCard: false`、`shake: false`、`absorbItem: false`、`mouseDragSlop: 8`
- [ ] 用 `GlobalKey<SuperGridState>` 持有状态，`onUpdate` 回调同步顺序到配置
- [ ] 顺序未变时**不写回**配置，避免多余的核心重启
- [ ] 用 `postFrameCallback` 写回，避免 setState 期间状态不一致

### 7.2 点击切换高亮

- [ ] `ProfileItem` 的 `onTap` 必须能正常触发（`absorbItem: false`）
- [ ] `SuperGrid.didUpdateWidget` 必须同步 `groupValue` 变化（key 序列不变但内容变了）

### 7.3 拖拽手感

- [ ] 让位动画用 `Curves.easeOutCubic` 而非线性
- [ ] 弹簧用 `SpringDescription.withDampingRatio(mass: 1, stiffness: 300, ratio: 0.8)`
- [ ] 让位动画节流用「首帧立即 + 尾部补一次」而非 600ms 防抖
- [ ] 拖拽反馈层加 `RepaintBoundary`

### 7.4 鼠标拖拽阈值

- [ ] 实现 `_PointerSlopDraggable` 系列，阈值取 `max(slop, computeHitSlop(kind, gestureSettings))`
- [ ] 配置页用 `mouseDragSlop: 8`，首页编辑模式用默认（0）

### 7.5 滚动行为

- [ ] 配置页的 `SingleChildScrollView` 外层包 `ScrollConfiguration(behavior: NoMouseDragScrollBehavior(...))`

### 7.6 配置预览

- [ ] 用 `ViewerPage`（只读 + 复制全文）替代 `EditorPage`
- [ ] 移除 `EditProfileView` 中的保存/校验逻辑
- [ ] 「编辑」按钮文案改为「查看」

### 7.7 脚本页外部编辑器

- [ ] 新增 `external_editor.dart` 工具库（检测、启动、显示标签）
- [ ] 脚本页工具栏加「外部编辑器」按钮
- [ ] 写文件到 `~/scripts/<id>.js`，用 `cmd /c` 启动
- [ ] `FileSystemWatcher` 监听文件变化，600ms 防抖同步回 App
- [ ] `dispose` 时取消所有订阅和定时器
- [ ] 配置模型加 `externalEditor` 字段
- [ ] 新增 `externalEditorTip`、`externalEditor`、`autoDetect`、`done` 本地化字符串

### 7.8 测试

- [ ] 新增 `profiles_drag_reorder_pattern_test.dart`，覆盖：点击、高亮刷新、拖拽排序
- [ ] 用 `runAsync` + `pump` 推进让位动画

---

## 八、文件清单

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `lib/views/profiles/profiles.dart` | 修改 | 核心：SuperGrid 拖拽 + 删除 ReorderableProfilesSheet |
| `lib/views/profiles/edit_profile.dart` | 修改 | 编辑 → 查看，删除内置编辑器保存逻辑 |
| `lib/views/profiles/add_profile.dart` | 修改 | 移除二维码扫码入口 |
| `lib/views/profiles/scripts.dart` | 修改 | 外部编辑器集成 + 文件监听 |
| `lib/widgets/super_grid.dart` | 修改 | 4 个新参数 + 让位动画重写 + 弹簧修正 + 鼠标阈值 |
| `lib/common/scroll.dart` | 修改 | 新增 NoMouseDragScrollBehavior |
| `lib/pages/viewer.dart` | 新增 | 只读查看器 |
| `lib/common/external_editor.dart` | 新增 | 外部编辑器工具库 |
| `lib/common/page_navigation_history.dart` | 新增 | 页签导航历史 |
| `lib/models/config.dart` | 修改 | 新增 externalEditor 字段 |
| `lib/pages/pages.dart` | 修改 | 导出替换 |
| `lib/views/views.dart` | 修改 | 导出清理 |
| `test/profiles_drag_reorder_pattern_test.dart` | 新增 | 回归测试 |
| `arb/intl_en.arb` | 修改 | 4 个新 key |
| `arb/intl_zh_CN.arb` | 修改 | 4 个新 key |
