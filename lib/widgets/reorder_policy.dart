import 'package:material_ui/material_ui.dart';

/// Decision policy for grid drag-reorder: move throttling plus swap
/// hysteresis. Pure logic with an injectable clock so geometry regressions
/// (swap thresholds, rate limiting) are unit-testable without widgets.
class ReorderPolicy {
  /// The dragged tile's center must penetrate this fraction of the target
  /// tile from its near edge (along the dominant axis) before a swap fires,
  /// so skimming tile borders does not reorder.
  final double hysteresis;

  /// Minimum interval between two fired swaps, so a fast pointer sweep does
  /// not teleport a tile across the grid.
  final Duration minInterval;

  DateTime _lastMove = DateTime.fromMillisecondsSinceEpoch(0);

  ReorderPolicy({
    this.hysteresis = 0.15,
    this.minInterval = const Duration(milliseconds: 220),
  });

  /// Throttle-only gate for grids whose drag target fires on entry and thus
  /// carries no geometry.
  bool allow(DateTime now) {
    if (now.difference(_lastMove) < minInterval) return false;
    _lastMove = now;
    return true;
  }

  /// Whether the move from [source] to [target] should fire a swap.
  ///
  /// Missing rects pass (tile not laid out yet); a failed penetration check
  /// returns false without consuming the throttle slot, matching the
  /// original per-grid behavior.
  bool shouldSwap({
    required Rect? source,
    required Rect? target,
    required Offset dragCenter,
    DateTime? now,
  }) {
    final time = now ?? DateTime.now();
    if (time.difference(_lastMove) < minInterval) return false;
    if (source != null &&
        target != null &&
        !_penetratesHysteresis(source, target, dragCenter)) {
      return false;
    }
    _lastMove = time;
    return true;
  }

  bool _penetratesHysteresis(Rect source, Rect target, Offset dragCenter) {
    final dx = target.left - source.left;
    final dy = target.top - source.top;
    if (dx == 0 && dy == 0) return true;
    if (dy.abs() > dx.abs()) {
      final margin = target.height * hysteresis;
      return dy > 0
          ? dragCenter.dy - target.top >= margin
          : target.bottom - dragCenter.dy >= margin;
    }
    final margin = target.width * hysteresis;
    return dx > 0
        ? dragCenter.dx - target.left >= margin
        : target.right - dragCenter.dx >= margin;
  }
}

/// [fromId] 定位到的元素挪到 [toId] 所在的下标，其余元素顺序不变。
///
/// 任一方不在列表里、或指向同一元素时返回 null，调用方据此不写回配置。
List<T>? moveItemTo<T>(
  List<T> items,
  String Function(T item) idOf,
  String fromId,
  String toId,
) {
  final from = items.indexWhere((item) => idOf(item) == fromId);
  final to = items.indexWhere((item) => idOf(item) == toId);
  if (from < 0 || to < 0 || from == to) return null;
  final moved = [...items];
  moved.insert(to, moved.removeAt(from));
  return moved;
}

/// Drag feedback shared by the reorder grids: the tile at its own size,
/// slightly scaled up and inert to pointers.
Widget buildDragFeedback(RenderBox? box, Widget child) {
  return Material(
    type: MaterialType.transparency,
    child: Transform.scale(
      scale: 1.04,
      child: SizedBox(
        width: box?.size.width,
        height: box?.size.height,
        child: AbsorbPointer(child: child),
      ),
    ),
  );
}

/// FLIP transition for grid tiles: when a reorder jumps a tile to a new
/// position, animate it from where it was rendered before the jump.
class FlipTile extends StatefulWidget {
  final GlobalKey gridKey;
  final Widget child;
  final Duration duration;

  const FlipTile({
    super.key,
    required this.gridKey,
    required this.child,
    this.duration = const Duration(milliseconds: 500),
  });

  @override
  State<FlipTile> createState() => _FlipTileState();
}

class _FlipTileState extends State<FlipTile>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  );
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  Offset? _last;
  Offset _from = Offset.zero;

  Offset get _offset =>
      Offset.lerp(_from, Offset.zero, _curve.value) ?? Offset.zero;

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _check(Duration _) {
    if (!mounted) return;
    final box = context.findRenderObject();
    final grid = widget.gridKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || grid == null) return;
    final position = box.localToGlobal(Offset.zero, ancestor: grid);
    final last = _last;
    _last = position;
    if (last == null || (last - position).distance < 0.5) return;
    _from = _offset + last - position;
    _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback(_check);
    return AnimatedBuilder(
      animation: _curve,
      builder: (_, child) => Transform.translate(offset: _offset, child: child),
      child: widget.child,
    );
  }
}
