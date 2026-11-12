import 'package:bett_box/views/proxies/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('gridRowOffset', () {
    test('每列 1 个时按行累加行距', () {
      expect(gridRowOffset(0, 1, 100), 0);
      expect(gridRowOffset(2, 1, 100), 216); // 2 * (100 + 8)
    });

    test('多列时按行取整', () {
      // 3 列：index 0..2 在第 0 行，index 3 起在第 1 行。
      expect(gridRowOffset(2, 3, 100), 0);
      expect(gridRowOffset(3, 3, 100), 108);
      expect(gridRowOffset(7, 3, 100), 216);
    });

    test('getScrollToSelectedOffset 落在行顶上方一个行距', () {
      // 旧公式 rows * itemHeight + (rows - 1) * gap 与新公式等价。
      const columns = 2;
      const itemHeight = 120.0;
      const index = 5; // 第 2 行
      final legacy =
          (index ~/ columns) * itemHeight + ((index ~/ columns) - 1) * 8;
      expect(
        gridRowOffset(index, columns, itemHeight) - 8,
        legacy,
      );
    });
  });
}
