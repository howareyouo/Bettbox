import 'dart:async';
import 'dart:math';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/activate_box.dart';
import 'package:bett_box/widgets/card.dart';
import 'package:bett_box/widgets/grid.dart';
import 'package:defer_pointer/defer_pointer.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';

typedef VoidCallback = void Function();

class SuperGrid extends StatefulWidget {
  final List<GridItem> children;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final int crossAxisCount;
  final VoidCallback? onUpdate;
  final bool wrapCard;
  final bool shake;
  final bool absorbItem;
  final double? mouseDragSlop;

  const SuperGrid({
    super.key,
    required this.children,
    this.crossAxisCount = 1,
    this.mainAxisSpacing = 0,
    this.crossAxisSpacing = 0,
    this.onUpdate,
    this.wrapCard = true,
    this.shake = true,
    this.absorbItem = true,
    this.mouseDragSlop,
  });

  @override
  State<SuperGrid> createState() => SuperGridState();
}

class SuperGridState extends State<SuperGrid> with TickerProviderStateMixin {
  final ValueNotifier<List<GridItem>> _childrenNotifier = ValueNotifier([]);
  List<GridItem> children = [];

  int get length => _childrenNotifier.value.length;
  List<int> _tempIndexList = [];
  List<BuildContext?> _itemContexts = [];
  Size _containerSize = Size.zero;
  int _targetIndex = -1;
  Offset _targetOffset = Offset.zero;
  List<Size> _sizes = [];
  List<Offset> _offsets = [];
  Offset _parentOffset = Offset.zero;
  EdgeDraggingAutoScroller? _edgeDraggingAutoScroller;
  Map<int, Tween<Offset>> _transformTweenMap = {};

  final ValueNotifier<bool> _animating = ValueNotifier(false);

  final _dragWidgetSizeNotifier = ValueNotifier(Size.zero);

  final _dragIndexNotifier = ValueNotifier(-1);

  late AnimationController _transformController;

  /// When a reorder interrupts a running animation, the remaining distance is
  /// covered in this shorter time, so the card tracks the finger instead of
  /// visibly trailing behind it.
  final Duration _catchUpDuration = const Duration(milliseconds: 40);

  /// Reorder / settle animations run faster than the global [commonDuration]
  /// so cards feel snappy while following the pointer.
  static const Duration _reorderDuration = Duration(milliseconds: 150);

  /// Fraction of the neighbor card's size the drag probe must penetrate past
  /// the shared edge before a swap fires, so hovering near the boundary
  /// between two cards does not make them flip back and forth.
  static const double _swapHysteresis = 0.05;

  Completer? _transformCompleter;

  Map<int, Animation<Offset>> _transformAnimationMap = {};

  late AnimationController _fakeDragWidgetController;
  Animation<Offset>? _fakeDragWidgetAnimation;

  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;
  Rect _dragRect = Rect.zero;
  Scrollable? _scrollable;

  int get crossCount => widget.crossAxisCount;

  void _onChildrenChange() {
    _tempIndexList = List.generate(length, (index) => index);
    _itemContexts = List.filled(length, null);
  }

  void _preTransformState() {
    _sizes = _itemContexts.map((item) => item!.size!).toList();
    _parentOffset = (context.findRenderObject() as RenderBox).localToGlobal(
      Offset.zero,
    );
    _offsets = _itemContexts
        .map(
          (item) =>
              (item!.findRenderObject() as RenderBox).localToGlobal(
                Offset.zero,
              ) -
              _parentOffset,
        )
        .toList();
    _containerSize = context.size!;
  }

  void _initState() {
    _transformController.value = 0;
    _sizes = List.generate(length, (index) => Size.zero);
    _offsets = [];
    _transformTweenMap.clear();
    _transformAnimationMap.clear();
    _containerSize = Size.zero;
    _dragIndexNotifier.value = -1;
    _dragWidgetSizeNotifier.value = Size.zero;
    _targetOffset = Offset.zero;
    _parentOffset = Offset.zero;
    _dragRect = Rect.zero;
    _targetIndex = -1;
  }

  @override
  void initState() {
    super.initState();
    _childrenNotifier.addListener(() {
      children = _childrenNotifier.value;
      if (widget.onUpdate != null) {
        widget.onUpdate!();
      }
    });

    _childrenNotifier.value = widget.children;

    _fakeDragWidgetController = AnimationController.unbounded(
      vsync: this,
      duration: _reorderDuration,
    );

    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 125),
    );

    _shakeAnimation = Tween<double>(begin: -0.012, end: 0.012).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.easeInOut),
    );

    _transformController = AnimationController(
      vsync: this,
      duration: _reorderDuration,
    );

    _initState();
  }

  void handleAdd(GridItem gridItem) {
    _childrenNotifier.value = List.from(_childrenNotifier.value)..add(gridItem);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final scrollable = context.findAncestorWidgetOfExactType<Scrollable>();
    if (scrollable == null) {
      return;
    }
    if (_scrollable != scrollable) {
      _edgeDraggingAutoScroller = EdgeDraggingAutoScroller(
        Scrollable.of(context),
        onScrollViewScrolled: () {
          _edgeDraggingAutoScroller?.startAutoScrollIfNecessary(_dragRect);
        },
        velocityScalar: 40,
      );
    }
  }

  @override
  void didUpdateWidget(SuperGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextChildren = widget.children;
    final currentChildren = _childrenNotifier.value;
    if (identical(nextChildren, currentChildren)) return;
    if (!_hasComparableKeys(nextChildren) &&
        !_hasComparableKeys(currentChildren)) {
      return;
    }
    if (_animating.value || _dragIndexNotifier.value != -1) return;
    _childrenNotifier.value = nextChildren;
    _initState();
  }

  bool _hasComparableKeys(List<GridItem> items) {
    return items.every((item) => item.key != null);
  }

  Future _transform() async {
    List<Offset> layoutOffsets = [Offset(_containerSize.width, 0)];
    final List<Offset> nextOffsets = [];

    for (final index in _tempIndexList) {
      final size = _sizes[index];
      final offset = _getNextOffset(layoutOffsets, size);
      final layoutOffset = Offset(
        min(
          offset.dx + size.width + widget.crossAxisSpacing,
          _containerSize.width,
        ),
        min(
          offset.dy + size.height + widget.mainAxisSpacing,
          _containerSize.height,
        ),
      );
      final startLayoutOffsetX = offset.dx;
      final endLayoutOffsetX = layoutOffset.dx;
      nextOffsets.add(offset);

      final startIndex = layoutOffsets.indexWhere(
        (i) => i.dx >= startLayoutOffsetX,
      );
      final endIndex = layoutOffsets.indexWhere(
        (i) => i.dx >= endLayoutOffsetX,
      );
      final endOffset = layoutOffsets[endIndex];

      if (startIndex != endIndex) {
        final startOffset = layoutOffsets[startIndex];
        if (startOffset.dx != startLayoutOffsetX) {
          layoutOffsets[startIndex] = Offset(
            startLayoutOffsetX,
            startOffset.dy,
          );
        }
      }
      if (endOffset.dx == endLayoutOffsetX) {
        layoutOffsets[endIndex] = layoutOffset;
      } else {
        layoutOffsets.insert(endIndex, layoutOffset);
      }
      layoutOffsets.removeRange(min(startIndex + 1, endIndex), endIndex);
    }

    final Map<int, Tween<Offset>> transformTweenMap = {};

    for (final index in _tempIndexList) {
      final nextIndex = _tempIndexList.indexWhere((i) => i == index);
      transformTweenMap[index] = Tween(
        begin: _transformTweenMap[index]?.begin ?? Offset.zero,
        end: nextOffsets[nextIndex] - _offsets[index],
      );
    }

    _transformTweenMap = transformTweenMap;

    _transformAnimationMap = transformTweenMap.map((key, value) {
      final preAnimationValue = _transformAnimationMap[key]?.value;
      return MapEntry(
        key,
        Tween(
          begin: preAnimationValue ?? Offset.zero,
          end: value.end,
        ).animate(_transformController),
      );
    });

    if (_targetIndex != -1) {
      _targetOffset = nextOffsets[_targetIndex];
    }

    _transformController.duration = _transformController.isAnimating
        ? _catchUpDuration
        : _reorderDuration;

    return _transformController.forward(from: 0);
  }

  void _handleDragStarted(int index) {
    _initState();
    _preTransformState();
    _dragIndexNotifier.value = index;
    _dragWidgetSizeNotifier.value = _sizes[index];
    _targetIndex = index;
    _targetOffset = _offsets[index];
    _dragRect = Rect.fromLTWH(
      _targetOffset.dx + _parentOffset.dx,
      _targetOffset.dy + _parentOffset.dy,
      _sizes[index].width,
      _sizes[index].height,
    );
  }

  Future<void> _handleDragEnd(DraggableDetails details) async {
    final children = List<GridItem>.from(_childrenNotifier.value);
    children.insert(_targetIndex, children.removeAt(_dragIndexNotifier.value));
    this.children = children;
    debouncer.cancel(FunctionTag.handleWill);
    if (_targetIndex == -1) {
      return;
    }
    final spring = SpringDescription.withDampingRatio(
      mass: 1,
      stiffness: 700,
      ratio: 0.95,
    );
    final simulation = SpringSimulation(spring, 0, 1, 0);
    _fakeDragWidgetAnimation = Tween(
      begin: details.offset - _parentOffset,
      end: _targetOffset,
    ).animate(_fakeDragWidgetController);
    _animating.value = true;

    _transformCompleter = Completer();
    final animateWith = _fakeDragWidgetController.animateWith(simulation);
    _transformCompleter?.complete(animateWith);
    await animateWith;
    _animating.value = false;
    _fakeDragWidgetAnimation = null;
    _transformTweenMap.clear();
    _transformAnimationMap.clear();
    _childrenNotifier.value = children;
    _initState();
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _dragRect = _dragRect.translate(details.delta.dx, details.delta.dy);
    // Re-evaluate the swap target continuously (not only on DragTarget
    // entry), so a swap suppressed by the hysteresis still fires once the
    // probe moves deeper into the neighbor slot.
    final item = _hitTestIndex(_dragRect.center);
    if (item != null) {
      _scheduleWill(item);
    }
    _edgeDraggingAutoScroller?.startAutoScrollIfNecessary(_dragRect);
  }

  /// Returns the item currently occupying the slot under [globalPoint], or
  /// null when the point is outside the grid.
  int? _hitTestIndex(Offset globalPoint) {
    if (_tempIndexList.isEmpty || _offsets.length != length) {
      return null;
    }
    final local = globalPoint - _parentOffset;
    for (var slot = 0; slot < _offsets.length; slot++) {
      final size = _sizes[slot];
      if (size == Size.zero) {
        continue;
      }
      if (Rect.fromLTWH(
        _offsets[slot].dx,
        _offsets[slot].dy,
        size.width,
        size.height,
      ).contains(local)) {
        return _tempIndexList[slot];
      }
    }
    return null;
  }

  /// Whether the drag probe has penetrated [candidate]'s slot deep enough
  /// past the edge shared with the current target slot to justify a swap.
  bool _penetratesHysteresis(int candidate) {
    final target = _targetIndex;
    if (target < 0 || target >= _offsets.length) {
      return true;
    }
    final dx = _offsets[candidate].dx - _offsets[target].dx;
    final dy = _offsets[candidate].dy - _offsets[target].dy;
    if (dx == 0 && dy == 0) {
      return true;
    }
    final pointer = _dragRect.center - _parentOffset;
    final size = _sizes[candidate];
    if (dy.abs() > dx.abs()) {
      final margin = size.height * _swapHysteresis;
      return dy > 0
          ? pointer.dy - _offsets[candidate].dy >= margin
          : _offsets[candidate].dy + size.height - pointer.dy >= margin;
    }
    final margin = size.width * _swapHysteresis;
    return dx > 0
        ? pointer.dx - _offsets[candidate].dx >= margin
        : _offsets[candidate].dx + size.width - pointer.dx >= margin;
  }

  bool _reordering = false;
  int? _pendingWillIndex;

  void _scheduleWill(int index) {
    if (_reordering) {
      _pendingWillIndex = index;
      return;
    }
    _reordering = true;
    unawaited(
      _handleWill(index).whenComplete(() {
        _reordering = false;
        final pending = _pendingWillIndex;
        _pendingWillIndex = null;
        if (pending != null) _scheduleWill(pending);
      }),
    );
  }

  Future<void> _handleWill(int index) async {
    final dragIndex = _dragIndexNotifier.value;
    if (dragIndex < 0 || dragIndex > _offsets.length - 1) {
      return;
    }
    final targetIndex = _tempIndexList.indexWhere((i) => i == index);
    if (_targetIndex == targetIndex) {
      return;
    }
    if (!_penetratesHysteresis(targetIndex)) {
      return;
    }
    _tempIndexList = List.generate(length, (i) {
      if (i == targetIndex) return _dragIndexNotifier.value;
      if (_targetIndex > targetIndex && i > targetIndex && i <= _targetIndex) {
        return _tempIndexList[i - 1];
      } else if (_targetIndex < targetIndex &&
          i >= _targetIndex &&
          i < targetIndex) {
        return _tempIndexList[i + 1];
      }
      return _tempIndexList[i];
    }).toList();

    _targetIndex = targetIndex;

    await _transform();
  }

  Future<void> _handleDelete(int index) async {
    _preTransformState();
    final indexWhere = _tempIndexList.indexWhere((i) => i == index);
    _tempIndexList.removeAt(indexWhere);
    await _transform();
    final children = List<GridItem>.from(_childrenNotifier.value);
    children.removeAt(index);
    _childrenNotifier.value = children;
    _initState();
  }

  Widget _buildTransform(Widget rawChild, int index) {
    return ValueListenableBuilder(
      valueListenable: _animating,
      builder: (_, animating, child) {
        if (animating && _dragIndexNotifier.value == index) {
          return _buildSizeBox(Container(), index);
        }
        return child!;
      },
      child: AnimatedBuilder(
        builder: (_, child) {
          return Transform.translate(
            offset: _transformAnimationMap[index]?.value ?? Offset.zero,
            child: child,
          );
        },
        animation: _transformController.view,
        child: rawChild,
      ),
    );
  }

  Offset _getNextOffset(List<Offset> offsets, Size size) {
    final length = offsets.length;
    Offset nextOffset = Offset(0, double.infinity);
    for (int i = 0; i < length; i++) {
      final offset = offsets[i];
      if (offset.dy.moreOrEqual(nextOffset.dy)) {
        continue;
      }
      double offsetX = 0;
      double span = 0;
      for (
        int j = 0;
        span < size.width &&
            j < length &&
            _containerSize.width.moreOrEqual(offsetX + size.width);
        j++
      ) {
        final tempOffset = offsets[j];
        if (offset.dy.moreOrEqual(tempOffset.dy)) {
          span = tempOffset.dx - offsetX;
          if (span.moreOrEqual(size.width)) {
            nextOffset = Offset(offsetX, offset.dy);
          }
        } else {
          offsetX = tempOffset.dx;
          span = 0;
        }
      }
    }
    return nextOffset;
  }

  Widget _buildSizeBox(Widget child, int index) {
    return ValueListenableBuilder(
      valueListenable: _dragWidgetSizeNotifier,
      builder: (_, size, child) {
        return SizedBox.fromSize(size: size, child: child!);
      },
      child: child,
    );
  }

  Widget _buildInactivate(Widget child) {
    return ValueListenableBuilder(
      valueListenable: _animating,
      builder: (_, animating, child) {
        if (animating) {
          return ActivateBox(child: child!);
        } else {
          return child!;
        }
      },
      child: child,
    );
  }

  Widget _buildShake(Widget child) {
    if (!widget.shake) {
      return child;
    }
    final random = 0.7 + Random().nextDouble() * 0.3;
    if (!_shakeController.isAnimating) {
      _shakeController.repeat(reverse: true);
    }
    return AnimatedBuilder(
      animation: _shakeAnimation,
      builder: (_, child) {
        return Transform.rotate(
          angle: _shakeAnimation.value * random,
          child: child!,
        );
      },
      child: child,
    );
  }

  Widget _buildDraggable({
    required Widget childWhenDragging,
    required Widget feedback,
    required Widget item,
    required int index,
    bool isDeletable = true,
  }) {
    final target = DragTarget<int>(
      builder: (_, _, _) {
        if (widget.absorbItem) {
          return AbsorbPointer(child: item);
        }
        return item;
      },
      onWillAcceptWithDetails: (_) {
        _scheduleWill(index);
        return false;
      },
    );
    final shakeTarget = ValueListenableBuilder(
      valueListenable: _animating,
      builder: (_, animating, child) {
        if (animating) {
          return target;
        } else {
          return child!;
        }
      },
      child: ValueListenableBuilder(
        valueListenable: _dragIndexNotifier,
        builder: (_, dragIndex, child) {
          if (dragIndex == index) {
            return child!;
          }
          final content = isDeletable
              ? _DeletableContainer(
                  onDelete: () {
                    _handleDelete(index);
                  },
                  child: child!,
                )
              : child!;
          return _buildShake(content);
        },
        child: target,
      ),
    );
    final slop = widget.mouseDragSlop;
    final draggableChild = system.isDesktop
        ? (slop == null || slop <= 0
              ? Draggable(
                  childWhenDragging: childWhenDragging,
                  data: index,
                  feedback: feedback,
                  onDragStarted: () {
                    _handleDragStarted(index);
                  },
                  onDragUpdate: (details) {
                    _handleDragUpdate(details);
                  },
                  onDragEnd: (details) {
                    _handleDragEnd(details);
                  },
                  child: shakeTarget,
                )
              : _PointerSlopDraggable(
                  slop: slop,
                  childWhenDragging: childWhenDragging,
                  data: index,
                  feedback: feedback,
                  onDragStarted: () {
                    _handleDragStarted(index);
                  },
                  onDragUpdate: (details) {
                    _handleDragUpdate(details);
                  },
                  onDragEnd: (details) {
                    _handleDragEnd(details);
                  },
                  child: shakeTarget,
                ))
        : LongPressDraggable(
            childWhenDragging: childWhenDragging,
            data: index,
            feedback: feedback,
            onDragStarted: () {
              _handleDragStarted(index);
            },
            onDragUpdate: (details) {
              _handleDragUpdate(details);
            },
            onDragEnd: (details) {
              _handleDragEnd(details);
            },
            child: shakeTarget,
          );
    return draggableChild;
  }

  Widget _builderItem(int index) {
    final gridItem = _childrenNotifier.value[index];
    final child = gridItem.child;
    return GridItem(
      mainAxisCellCount: gridItem.mainAxisCellCount,
      crossAxisCellCount: gridItem.crossAxisCellCount,
      isDeletable: gridItem.isDeletable,
      child: Builder(
        builder: (context) {
          _itemContexts[index] = context;
          final cardChild = widget.wrapCard ? CommonCard(child: child) : child;
          final childWhenDragging = ActivateBox(
            child: Opacity(
              opacity: 0.6,
              child: _buildSizeBox(cardChild, index),
            ),
          );
          final feedbackCard = widget.wrapCard
              ? CommonCard(isDragFeedback: true, child: child)
              : Material(
                  elevation: 6,
                  shape: SmoothRoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      CommonCard.defaultRadius,
                    ),
                  ),
                  child: child,
                );
          final feedback = ActivateBox(
            child: RepaintBoundary(child: _buildSizeBox(feedbackCard, index)),
          );
          return _buildTransform(
            _buildDraggable(
              childWhenDragging: childWhenDragging,
              feedback: feedback,
              item: child,
              index: index,
              isDeletable: gridItem.isDeletable,
            ),
            index,
          );
        },
      ),
    );
  }

  Widget _buildFakeTransformWidget() {
    return ValueListenableBuilder<bool>(
      valueListenable: _animating,
      builder: (_, animating, _) {
        final index = _dragIndexNotifier.value;
        if (!animating || _fakeDragWidgetAnimation == null || index == -1) {
          return Container();
        }
        return _buildSizeBox(
          AnimatedBuilder(
            animation: _fakeDragWidgetAnimation!,
            builder: (_, child) {
              return Transform.translate(
                offset: _fakeDragWidgetAnimation!.value,
                child: child!,
              );
            },
            child: ActivateBox(child: _childrenNotifier.value[index].child),
          ),
          index,
        );
      },
    );
  }

  @override
  void dispose() {
    _scrollable = null;
    _fakeDragWidgetController.dispose();
    _shakeController.dispose();
    _transformController.dispose();
    _dragIndexNotifier.dispose();
    _animating.dispose();
    _childrenNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DeferredPointerHandler(
      child: Stack(
        children: [
          _buildInactivate(
            ValueListenableBuilder(
              valueListenable: _childrenNotifier,
              builder: (_, children, _) {
                _onChildrenChange();
                return Grid(
                  axisDirection: AxisDirection.down,
                  crossAxisCount: crossCount,
                  crossAxisSpacing: widget.crossAxisSpacing,
                  mainAxisSpacing: widget.mainAxisSpacing,
                  children: [
                    for (int i = 0; i < children.length; i++) _builderItem(i),
                  ],
                );
              },
            ),
          ),
          _buildFakeTransformWidget(),
        ],
      ),
    );
  }
}

class _DeletableContainer extends StatefulWidget {
  final Widget child;
  final VoidCallback onDelete;

  const _DeletableContainer({required this.child, required this.onDelete});

  @override
  State<_DeletableContainer> createState() => _DeletableContainerState();
}

class _DeletableContainerState extends State<_DeletableContainer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  bool _deleteButtonVisible = true;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: commonDuration);
    _scaleAnimation = Tween(
      begin: 1.0,
      end: 0.4,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));
    _fadeAnimation = Tween(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));
  }

  @override
  void didUpdateWidget(_DeletableContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) {
      setState(() {
        _controller.value = 0;
        _deleteButtonVisible = true;
      });
    }
  }

  Future<void> _handleDel() async {
    setState(() {
      _deleteButtonVisible = false;
    });
    await _controller.forward(from: 0);
    widget.onDelete();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget content = widget.child;
    if (globalState.isAndroidTV) {
      content = InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: _handleDel,
        onFocusChange: (focused) {
          setState(() {
            _isFocused = focused;
          });
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: _isFocused
                ? Border.all(
                    color: context.colorScheme.error,
                    width: 2.5,
                  )
                : Border.all(
                    color: Colors.transparent,
                    width: 2.5,
                  ),
          ),
          child: ExcludeFocus(
            child: AbsorbPointer(child: widget.child),
          ),
        ),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedBuilder(
          animation: _controller.view,
          builder: (_, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: Opacity(opacity: _fadeAnimation.value, child: child!),
            );
          },
          child: content,
        ),
        if (_deleteButtonVisible)
          Positioned(
            top: -8,
            right: -8,
            child: DeferPointer(
              child: SizedBox(
                width: globalState.isAndroidTV ? 28 : 24,
                height: globalState.isAndroidTV ? 28 : 24,
                child: IconButton.filled(
                  iconSize: globalState.isAndroidTV ? 18 : 20,
                  padding: const EdgeInsets.all(2),
                  style: globalState.isAndroidTV
                      ? IconButton.styleFrom(
                          backgroundColor: context.colorScheme.error,
                          foregroundColor: context.colorScheme.onError,
                        )
                      : null,
                  onPressed: _handleDel,
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PointerSlopDraggable<T extends Object> extends Draggable<T> {
  const _PointerSlopDraggable({
    required this.slop,
    required super.child,
    required super.feedback,
    super.data,
    super.childWhenDragging,
    super.feedbackOffset,
    super.maxSimultaneousDrags,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDraggableCanceled,
    super.onDragEnd,
    super.onDragCompleted,
    super.hitTestBehavior,
    super.rootOverlay,
  });

  final double slop;

  @override
  MultiDragGestureRecognizer createRecognizer(GestureMultiDragStartCallback onStart) {
    return _PointerSlopMultiDragGestureRecognizer(slop: slop)..onStart = onStart;
  }
}

class _PointerSlopMultiDragGestureRecognizer extends MultiDragGestureRecognizer {
  _PointerSlopMultiDragGestureRecognizer({
    required this.slop,
    super.debugOwner,
  });

  final double slop;

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return _PointerSlopPointerState(
      event.position,
      event.kind,
      gestureSettings,
      slop,
    );
  }

  @override
  String get debugDescription => 'pointer slop multidrag';
}

class _PointerSlopPointerState extends MultiDragPointerState {
  _PointerSlopPointerState(
    super.initialPosition,
    super.kind,
    super.gestureSettings,
    this.slop,
  );

  final double slop;

  @override
  void checkForResolutionAfterMove() {
    assert(pendingDelta != null);
    final threshold = max(slop, computeHitSlop(kind, gestureSettings));
    if (pendingDelta!.distance > threshold) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPosition);
  }
}
