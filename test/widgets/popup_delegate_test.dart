import 'package:bett_box/widgets/popup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 41f4e5e 语义的回归网：锚点表达「菜单右缘对齐 offset.dx、顶边落在 offset.dy」，
// 再由 delegate 对 overlay 边缘（留 16 安全边距）做钳制。
void main() {
  group('OverflowAwareLayoutDelegate.getPositionForChild', () {
    test('右缘对齐锚点 x，顶边取锚点 y', () {
      final delegate = OverflowAwareLayoutDelegate(offset: Offset(200, 300));
      expect(
        delegate.getPositionForChild(const Size(400, 600), const Size(100, 50)),
        const Offset(100, 300),
      );
    });

    test('左溢出：锚点在菜单宽度之内时钳到 0', () {
      final delegate = OverflowAwareLayoutDelegate(offset: Offset(50, 300));
      expect(
        delegate.getPositionForChild(const Size(400, 600), const Size(100, 50)),
        const Offset(0, 300),
      );
    });

    test('右溢出：钳到 overlay 右缘 - 16 - 菜单宽', () {
      final delegate = OverflowAwareLayoutDelegate(offset: Offset(500, 300));
      expect(
        delegate.getPositionForChild(const Size(400, 600), const Size(100, 50)),
        const Offset(400 - 16 - 100, 300),
      );
    });

    test('底溢出：钳到 overlay 底缘 - 16 - 菜单高', () {
      final delegate = OverflowAwareLayoutDelegate(offset: Offset(200, 580));
      expect(
        delegate.getPositionForChild(const Size(400, 600), const Size(100, 50)),
        const Offset(100, 600 - 16 - 50),
      );
    });

    test('菜单比可用空间还大时落 0 而不抛 ArgumentError', () {
      final delegate = OverflowAwareLayoutDelegate(offset: Offset(50, 50));
      expect(
        delegate.getPositionForChild(const Size(100, 100), const Size(200, 200)),
        Offset.zero,
      );
    });

    test('shouldRelayout 仅在锚点变化时成立', () {
      final delegate = OverflowAwareLayoutDelegate(offset: const Offset(1, 2));
      expect(
        delegate.shouldRelayout(
          OverflowAwareLayoutDelegate(offset: const Offset(1, 2)),
        ),
        isFalse,
      );
      expect(
        delegate.shouldRelayout(
          OverflowAwareLayoutDelegate(offset: const Offset(3, 2)),
        ),
        isTrue,
      );
    });
  });
}
