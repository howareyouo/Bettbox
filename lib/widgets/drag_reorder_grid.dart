import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'grid.dart';
import 'reorder_policy.dart';

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
  final _policy = ReorderPolicy();

  GlobalKey _tileKeyOf(T item) =>
      _tileKeys.putIfAbsent(widget.keyOf(item), GlobalKey.new);

  bool get _draggable => !globalState.isAndroidTV;

  void _move(T from, T to, Offset feedbackTopLeft) {
    final source = _tileRect(from);
    final target = _tileRect(to);
    if (!_policy.shouldSwap(
      source: source,
      target: target,
      dragCenter:
          feedbackTopLeft + (source?.size.center(Offset.zero) ?? Offset.zero),
    )) {
      return;
    }
    final items = [...widget.items];
    final sourceIndex = items.indexOf(from);
    final targetIndex = items.indexOf(to);
    if (sourceIndex < 0 || targetIndex < 0 || sourceIndex == targetIndex) return;
    items.insert(targetIndex, items.removeAt(sourceIndex));
    widget.onReorder(items);
  }

  Rect? _tileRect(T item) {
    final box = _tileKeyOf(item).currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Widget _buildTile(BuildContext context, T item) {
    final child = widget.itemBuilder(context, item);
    if (!_draggable) return child;
    final tileKey = _tileKeyOf(item);
    final target = DragTarget<T>(
      // onWillAccept fires only on target entry; the penetration threshold
      // needs re-checking on every pointer update, which only onMove gives.
      onMove: (details) {
        if (widget.keyOf(details.data) != widget.keyOf(item)) {
          _move(details.data, item, details.offset);
        }
      },
      onWillAcceptWithDetails: (_) => false,
      builder: (_, _, _) => child,
    );
    final feedback = Builder(
      builder: (_) {
        final box = tileKey.currentContext?.findRenderObject();
        return buildDragFeedback(
          box is RenderBox && box.hasSize ? box : null,
          child,
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
              child: FlipTile(
                gridKey: _gridKey,
                child: _buildTile(context, item),
              ),
            ),
      ],
    );
  }
}
