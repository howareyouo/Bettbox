# GLOSSARY.md — Bettbox 领域词汇

> 本仓库的单-context 词汇表：只记录术语与含义，不写实现细节。
> 新术语在敲定的当时随手追加，不要攒批。

## 术语

### ConfigCompiler
模块（`lib/clash/config_compiler.dart`）。把当前 `Config` 编译为内核启动参数、
校验参数与脚本化运行时配置的唯一入口。版本号、构建号、脚本报错出口由调用方
注入——clash/ 层不感知 UI，也不反向依赖 state。

### onCoreLostRestart
缝隙（seam）。内核意外掉线后的重启出口：`ClashService` 只持有这个回调字段，
由组合根（`GlobalState.appController` setter）注入真正的重启实现。clash/ 层
永远不直接调用 UI 控制器；发现新的向上调用时，优先扩这个缝。

### 延迟快照
排序、托盘、展示读取的一致性延迟视图：节点测速进行中时用最后已知值参与比较，
而不是 null / 进行中状态。写侧负责维护快照，读侧（含托盘排序）不做特殊判断。

### ReorderPolicy
策略（`lib/widgets/reorder_policy.dart`）。网格与列表拖拽重排序的统一语义：
目标位计算、越界钳制、锁定项处理。新增可重排视图时复用此策略，不重写几何。

### surfaceRadius
设计 token（`lib/common/constant.dart`）。浮在内容之上的表面（弹出菜单、
卡片浮层）的统一圆角取值。表面级圆角一律取 token，不再各处写死数字。

### SpeedTestSession
概念（`lib/pages/speed_test_session.dart`）。一次测速会话的规则层：何时有效、
何时终止、结果如何归集。UI 只渲染会话给出的状态，不自行判断会话生命周期。

### 同步 Outcome 约定
后台批量操作（如订阅同步）的错误表达约定：单项目标返回 `Future<String?>`——
成功为 `null`，失败为「label: 原因」文案；调用方聚合后以顶部通知统一呈现，
不用弹窗逐项打断。

### updateState
钩子（`lib/common/mixin.dart`）。Riverpod Notifier 状态同构变更
`state = builder(state)` 的收敛入口，由 `AutoDisposeNotifierMixin` 提供。
需要额外副作用（null 守卫、强制字段）时覆写并标注 `@override`。
