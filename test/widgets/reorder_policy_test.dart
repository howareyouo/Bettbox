import 'package:bett_box/widgets/reorder_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Rect _rect(double left, [double top = 0, double size = 100]) =>
    Rect.fromLTWH(left, top, size, size);

// 策略内部 _lastMove 初始为 epoch(1970)，真实时钟与之相差数年、节流天然放行；
// 测试基准时间必须远离 epoch 才能真实模拟节流窗口。
final _t0 = DateTime(2026, 1, 1);

void main() {
  group('ReorderPolicy.shouldSwap', () {
    test('220ms 内的第二次移动被限流', () {
      final policy = ReorderPolicy();
      final source = _rect(0);
      final target = _rect(100, 0);
      const dragCenter = Offset(150, 50);
      expect(
        policy.shouldSwap(
          source: source,
          target: target,
          dragCenter: dragCenter,
          now: _t0,
        ),
        isTrue,
      );
      expect(
        policy.shouldSwap(
          source: source,
          target: target,
          dragCenter: dragCenter,
          now: _t0.add(const Duration(milliseconds: 100)),
        ),
        isFalse,
      );
      expect(
        policy.shouldSwap(
          source: source,
          target: target,
          dragCenter: dragCenter,
          now: _t0.add(const Duration(milliseconds: 220)),
        ),
        isTrue,
      );
    });

    test('渗透不足不换位，也不消耗限流时间片', () {
      final policy = ReorderPolicy();
      // 只探入 10% < 15%。
      expect(
        policy.shouldSwap(
          source: _rect(0),
          target: _rect(100, 0),
          dragCenter: const Offset(110, 50),
          now: _t0,
        ),
        isFalse,
      );
      // 10ms 后真正探入：如果 skim 消耗了时间片，这里会被限流挡住。
      expect(
        policy.shouldSwap(
          source: _rect(0),
          target: _rect(100, 0),
          dragCenter: const Offset(115, 50),
          now: _t0.add(const Duration(milliseconds: 10)),
        ),
        isTrue,
      );
    });

    test('水平主轴：探入目标 15% 才换位', () {
      final policy = ReorderPolicy(minInterval: Duration.zero);
      expect(
        policy.shouldSwap(
          source: _rect(0),
          target: _rect(100, 0),
          dragCenter: const Offset(114.9, 50),
        ),
        isFalse,
      );
      expect(
        policy.shouldSwap(
          source: _rect(0),
          target: _rect(100, 0),
          dragCenter: const Offset(115, 50),
        ),
        isTrue,
      );
      // 从右侧逼近同理。
      expect(
        policy.shouldSwap(
          source: _rect(100, 0),
          target: _rect(0),
          dragCenter: const Offset(85, 50),
        ),
        isTrue,
      );
      expect(
        policy.shouldSwap(
          source: _rect(100, 0),
          target: _rect(0),
          dragCenter: const Offset(85.1, 50),
        ),
        isFalse,
      );
    });

    test('垂直主轴按高度取 margin，不横向误判', () {
      final policy = ReorderPolicy(minInterval: Duration.zero);
      // 目标在下方 dy=100 为主轴；水平方向探入再深也只看垂直 margin。
      expect(
        policy.shouldSwap(
          source: _rect(0),
          target: _rect(0, 100),
          dragCenter: const Offset(50, 110),
        ),
        isFalse,
      );
      expect(
        policy.shouldSwap(
          source: _rect(0),
          target: _rect(0, 100),
          dragCenter: const Offset(50, 115),
        ),
        isTrue,
      );
    });

    test('取不到 tile 几何时放行（与原行为一致）', () {
      final policy = ReorderPolicy(minInterval: Duration.zero);
      expect(
        policy.shouldSwap(
          source: null,
          target: _rect(100, 0),
          dragCenter: Offset.zero,
        ),
        isTrue,
      );
      expect(
        policy.shouldSwap(
          source: _rect(0),
          target: null,
          dragCenter: Offset.zero,
        ),
        isTrue,
      );
    });

    test('源与目标同位时直接放行', () {
      final policy = ReorderPolicy(minInterval: Duration.zero);
      expect(
        policy.shouldSwap(
          source: _rect(0),
          target: _rect(0),
          dragCenter: const Offset(50, 50),
        ),
        isTrue,
      );
    });
  });

  group('ReorderPolicy.allow', () {
    test('纯节流，供入场判定的网格使用', () {
      final policy = ReorderPolicy();
      expect(policy.allow(_t0), isTrue);
      expect(policy.allow(_t0.add(const Duration(milliseconds: 219))), isFalse);
      expect(policy.allow(_t0.add(const Duration(milliseconds: 220))), isTrue);
    });
  });

  group('moveItemTo', () {
    String ids(String id) => id;

    test('往后拖：插到目标下标，其余元素相对顺序不变', () {
      expect(moveItemTo(['a', 'b', 'c', 'd'], ids, 'a', 'c'), [
        'b',
        'c',
        'a',
        'd',
      ]);
    });

    test('往前拖：插到目标下标', () {
      expect(moveItemTo(['a', 'b', 'c', 'd'], ids, 'd', 'b'), [
        'a',
        'd',
        'b',
        'c',
      ]);
    });

    test('只挪被拖的那一项，成员条目的位置不动', () {
      // b 是 bundle，b1/b2 是它的成员条目：折叠行按 bundle.members 渲染，
      // 与这些条目在列表里的位置无关，所以拖动只影响 b 自己。
      expect(moveItemTo(['a', 'b', 'b1', 'b2', 'c'], ids, 'b', 'c'), [
        'a',
        'b1',
        'b2',
        'c',
        'b',
      ]);
    });

    test('同一元素或缺失的 id 返回 null，调用方不写配置', () {
      expect(moveItemTo(['a', 'b'], ids, 'a', 'a'), isNull);
      expect(moveItemTo(['a', 'b'], ids, 'a', 'zzz'), isNull);
      expect(moveItemTo(['a', 'b'], ids, 'zzz', 'b'), isNull);
    });
  });
}
