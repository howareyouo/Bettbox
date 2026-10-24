import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'grid.dart';

/// Scroll behavior that removes mouse from drag devices, so mouse dragging
/// moves [DragReorderGrid] items instead of scrolling the page.
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

/// Grid whose items can be reordered in place by dragging.
///
/// Desktop: press and move with the mouse. Touch: long-press then drag.
/// Items are swapped live while hovering over another item; position changes
/// are animated with a FLIP transition.
class DragReorderGrid<T extends Object> extends StatefulWidget {
  final List<T> items;
  final int crossAxisCount;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final Object Function(T item) keyOf;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final void Function(List<T> items) onReorder;

  const DragReorderGrid({
    super.key,
    required this.items,
    required this.crossAxisCount,
    required this.keyOf,
    required this.itemBuilder,
    required this.onReorder,
    this.mainAxisSpacing = 0,
    this.crossAxisSpacing = 0,
  });

  @override
  State<DragReorderGrid<T>> createState() => _DragReorderGridState<T>();
}

class _DragReorderGridState<T extends Object>
    extends State<DragReorderGrid<T>> {
  final _gridKey = GlobalKey();
  final _tileKeys = <Object, GlobalKey>{};
  DateTime _lastMove = DateTime.fromMillisecondsSinceEpoch(0);

  GlobalKey _tileKeyOf(T item) =>
      _tileKeys.putIfAbsent(widget.keyOf(item), GlobalKey.new);

  bool get _draggable => !globalState.isAndroidTV;

  void _move(T from, T to) {
    final now = DateTime.now();
    if (now.difference(_lastMove) < const Duration(milliseconds: 220)) return;
    _lastMove = now;
    final items = [...widget.items];
    final source = items.indexOf(from);
    final target = items.indexOf(to);
    if (source < 0 || target < 0 || source == target) return;
    items.insert(target, items.removeAt(source));
    widget.onReorder(items);
  }

  Widget _buildTile(BuildContext context, T item) {
    final child = widget.itemBuilder(context, item);
    if (!_draggable) return child;
    final tileKey = _tileKeyOf(item);
    final target = DragTarget<T>(
      onWillAcceptWithDetails: (details) {
        if (widget.keyOf(details.data) != widget.keyOf(item)) {
          _move(details.data, item);
        }
        return false;
      },
      builder: (_, _, _) => child,
    );
    final feedback = Builder(
      builder: (_) {
        final box = tileKey.currentContext?.findRenderObject();
        final size = box is RenderBox && box.hasSize ? box.size : null;
        return Material(
          type: MaterialType.transparency,
          child: Transform.scale(
            scale: 1.04,
            child: SizedBox(
              width: size?.width,
              height: size?.height,
              child: AbsorbPointer(child: child),
            ),
          ),
        );
      },
    );
    final placeholder = Opacity(opacity: 0.3, child: child);
    final draggable = system.isDesktop
        ? Draggable<T>(
            data: item,
            feedback: feedback,
            childWhenDragging: placeholder,
            onDragStarted: () => HapticFeedback.selectionClick(),
            child: target,
          )
        : LongPressDraggable<T>(
            data: item,
            delay: const Duration(milliseconds: 300),
            feedback: feedback,
            childWhenDragging: placeholder,
            onDragStarted: () => HapticFeedback.mediumImpact(),
            child: target,
          );
    return KeyedSubtree(key: tileKey, child: draggable);
  }

  @override
  Widget build(BuildContext context) {
    return Grid(
      key: _gridKey,
      crossAxisCount: widget.crossAxisCount,
      crossAxisSpacing: widget.crossAxisSpacing,
      mainAxisSpacing: widget.mainAxisSpacing,
      children: [
        for (final item in widget.items)
          GridItem(
            key: ValueKey(widget.keyOf(item)),
            child: _FlipTile(
              gridKey: _gridKey,
              child: _buildTile(context, item),
            ),
          ),
      ],
    );
  }
}

class _FlipTile extends StatefulWidget {
  final GlobalKey gridKey;
  final Widget child;

  const _FlipTile({required this.gridKey, required this.child});

  @override
  State<_FlipTile> createState() => _FlipTileState();
}

class _FlipTileState extends State<_FlipTile>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
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
