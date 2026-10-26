import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/common.dart';
import 'package:material_ui/material_ui.dart';

class CommonPopupRoute<T> extends PopupRoute<T> {
  final WidgetBuilder builder;
  ValueNotifier<Offset> offsetNotifier;

  CommonPopupRoute({
    required this.barrierLabel,
    required this.builder,
    required this.offsetNotifier,
  });

  @override
  String? barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return SafeArea(
      child: ValueListenableBuilder(
        valueListenable: offsetNotifier,
        builder: (_, value, child) {
          return Align(
            alignment: Alignment.topRight,
            child: CustomSingleChildLayout(
              delegate: OverflowAwareLayoutDelegate(
                offset: value.translate(48, -8),
              ),
              child: child,
            ),
          );
        },
        child: _PopupTransition(
          animation: animation,
          duration: transitionDuration,
          child: child,
        ),
      ),
    );
  }

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);
}

class _PopupTransition extends StatefulWidget {
  final Animation<double> animation;
  final Duration duration;
  final Widget child;

  const _PopupTransition({
    required this.animation,
    required this.duration,
    required this.child,
  });

  @override
  State<_PopupTransition> createState() => _PopupTransitionState();
}

class _PopupTransitionState extends State<_PopupTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: AnimationMin(widget.animation, _enter),
    curve: Curves.easeIn,
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: 0.1,
    end: 1,
  ).animate(_curve);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _enter.forward();
      }
    });
  }

  @override
  void dispose() {
    _curve.dispose();
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: AnimatedBuilder(
        animation: _curve,
        builder: (_, child) {
          final value = _curve.value;
          return Transform.scale(
            alignment: Alignment.topRight,
            scale: 0.7 + 0.3 * value,
            child: Transform.translate(
              offset: Offset(0, -10 * (1 - value)),
              child: child,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

class PopupController extends ValueNotifier<bool> {
  PopupController() : super(false);

  void open() {
    value = true;
  }

  void close() {
    value = false;
  }
}

typedef PopupOpen = Future<void> Function({Offset offset});

class CommonPopupBox extends StatefulWidget {
  final Widget Function(PopupOpen open) targetBuilder;
  final Widget popup;

  const CommonPopupBox({
    super.key,
    required this.targetBuilder,
    required this.popup,
  });

  @override
  State<CommonPopupBox> createState() => _CommonPopupBoxState();
}

class _CommonPopupBoxState extends State<CommonPopupBox> {
  bool _isOpen = false;
  final _targetOffsetValueNotifier = ValueNotifier<Offset>(Offset.zero);
  Offset _offset = Offset.zero;

  Future<void> _open({Offset offset = Offset.zero}) {
    _offset = offset;
    _updateOffset();
    _isOpen = true;
    return Navigator.of(context)
        .push(
          CommonPopupRoute(
            barrierLabel: utils.id,
            builder: (BuildContext context) {
              return widget.popup;
            },
            offsetNotifier: _targetOffsetValueNotifier,
          ),
        )
        .then((_) {
          _isOpen = false;
        });
  }

  void _updateOffset() {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return;
    }
    // 锚点须相对路由实际落入的 overlay 表达：桌面视图下路由推入
    // home 的嵌套 Navigator，其 overlay 原点 ≠ 窗口原点（侧边栏宽 +
    // header 高），用窗口坐标会在 overlay 里整体平移。
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final Offset anchor;
    if (overlayBox != null && overlayBox.hasSize) {
      anchor = renderBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    } else {
      final viewPadding = MediaQuery.of(context).viewPadding;
      anchor = renderBox.localToGlobal(
        Offset(-viewPadding.left, -viewPadding.top),
      );
    }
    _targetOffsetValueNotifier.value = anchor.translate(_offset.dx, _offset.dy);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_isOpen) {
            _updateOffset();
          }
        });
        return widget.targetBuilder(_open);
      },
    );
  }
}

class OverflowAwareLayoutDelegate extends SingleChildLayoutDelegate {
  final Offset offset;

  OverflowAwareLayoutDelegate({required this.offset});

  @override
  Size getSize(BoxConstraints constraints) {
    return Size(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final safeOffset = Offset(16, 16);
    double x = (offset.dx - childSize.width).clamp(
      0,
      size.width - safeOffset.dx - childSize.width,
    );
    double y = (offset.dy).clamp(
      0,
      size.height - safeOffset.dy - childSize.height,
    );
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(covariant OverflowAwareLayoutDelegate oldDelegate) {
    return oldDelegate.offset != offset;
  }
}

class CommonPopupMenu extends StatelessWidget {
  final List<PopupMenuItemData> items;
  final Widget? footer;
  final double minWidth;
  final double minItemVerticalPadding;
  final double fontSize;

  const CommonPopupMenu({
    super.key,
    required this.items,
    this.footer,
    this.minWidth = 148,
    this.minItemVerticalPadding = 16,
    this.fontSize = 15,
  });

  Widget _popupMenuItem(
    BuildContext context, {
    required PopupMenuItemData item,
    required int index,
  }) {
    final colorScheme = context.colorScheme;
    final isLight = colorScheme.brightness == Brightness.light;
    final onPressed = item.onPressed;
    final disabled = onPressed == null;
    final color = disabled
        ? colorScheme.onSurface.opacity30
        : colorScheme.onSurface;
    return InkWell(
      hoverColor: colorScheme.primary.withValues(alpha: isLight ? 0.08 : 0.12),
      highlightColor: colorScheme.primary.withValues(
        alpha: isLight ? 0.10 : 0.16,
      ),
      splashColor: colorScheme.primary.withValues(alpha: isLight ? 0.08 : 0.12),
      onTap: onPressed != null
          ? () {
              final route = ModalRoute.of(context);
              Navigator.of(context).pop();
              if (route == null) {
                onPressed();
                return;
              }
              route.completed.then((_) => onPressed());
            }
          : null,
      child: Container(
        constraints: BoxConstraints(minWidth: minWidth),
        padding: EdgeInsets.only(
          left: 16,
          right: 24,
          top: minItemVerticalPadding,
          bottom: minItemVerticalPadding,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            if (item.icon != null) ...[
              Icon(item.icon, size: fontSize + 4, color: color),
              SizedBox(width: 16),
            ],
            Flexible(
              child: Text(
                item.label,
                style: context.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontSize: fontSize,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = context.colorScheme.brightness == Brightness.light;
    return IntrinsicHeight(
      child: IntrinsicWidth(
        child: Card(
          elevation: 8,
          color: isLight
              ? context.colorScheme.surfaceContainerLowest
              : context.colorScheme.surfaceContainerHighest,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: context.colorScheme.outlineVariant.withValues(
                alpha: isLight ? 0.45 : 0.25,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in items.asMap().entries) ...[
                _popupMenuItem(context, item: item.value, index: item.key),
                if (item.value != items.last) Divider(height: 0),
              ],
              if (footer case final footer?) ...[
                const Divider(height: 0),
                footer,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
