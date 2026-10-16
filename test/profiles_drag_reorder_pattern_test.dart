import 'package:bett_box/widgets/grid.dart';
import 'package:bett_box/widgets/super_grid.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

const _ids = ['a', 'b'];

List<GridItem> _buildItems({
  required ValueChanged<String> onTap,
  required int selectedIndex,
}) {
  return [
    for (var i = 0; i < _ids.length; i++)
      GridItem(
        key: ValueKey<String>(_ids[i]),
        child: GestureDetector(
          onTap: () => onTap(_ids[i]),
          child: ColoredBox(
            key: ValueKey<String>('color-${_ids[i]}'),
            color: i == selectedIndex ? Colors.blue : Colors.grey,
            child: SizedBox(
              height: 60,
              child: Center(child: Text(_ids[i])),
            ),
          ),
        ),
      ),
  ];
}

List<String> _gridIds(GlobalKey<SuperGridState> key) {
  return key.currentState!.children
      .map((item) => item.key)
      .whereType<ValueKey<String>>()
      .map((key) => key.value)
      .toList();
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
}

void main() {
  group('profiles grid inline reorder pattern', () {
    testWidgets('item still receives taps after mouse drag slop is relaxed', (
      tester,
    ) async {
      final tapped = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SuperGrid(
              mouseDragSlop: 8,
              wrapCard: false,
              shake: false,
              absorbItem: false,
              children: _buildItems(
                onTap: tapped.add,
                selectedIndex: -1,
              ),
            ),
          ),
        ),
      );
      await _settle(tester);

      await tester.tap(find.text('a'));
      await tester.pump();

      expect(tapped, ['a']);
    });

    testWidgets('selection highlight follows the tap', (tester) async {
      final gridKey = GlobalKey<SuperGridState>();
      var selected = 'a';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return SuperGrid(
                  key: gridKey,
                  mouseDragSlop: 8,
                  wrapCard: false,
                  shake: false,
                  absorbItem: false,
                  children: _buildItems(
                    onTap: (id) => setState(() => selected = id),
                    selectedIndex: _ids.indexOf(selected),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await _settle(tester);

      Color colorOf(String id) =>
          tester
              .widget<ColoredBox>(find.byKey(ValueKey<String>('color-$id')))
              .color;

      expect(colorOf('a'), Colors.blue);
      expect(colorOf('b'), Colors.grey);

      await tester.tap(find.text('b'));
      await tester.pump();

      expect(selected, 'b');
      expect(colorOf('a'), Colors.grey);
      expect(colorOf('b'), Colors.blue);
      expect(_gridIds(gridKey), _ids);
    });

    testWidgets('drag reorders and reports the new order', (tester) async {
      final gridKey = GlobalKey<SuperGridState>();
      final updates = <List<String>>[];

      void handleUpdate() {
        if (gridKey.currentState == null) return;
        updates.add(_gridIds(gridKey));
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SuperGrid(
              key: gridKey,
              mouseDragSlop: 8,
              wrapCard: false,
              shake: false,
              absorbItem: false,
              onUpdate: handleUpdate,
              children: _buildItems(onTap: (_) {}, selectedIndex: -1),
            ),
          ),
        ),
      );
      await _settle(tester);

      final aRect = tester.getRect(find.text('a'));
      final bRect = tester.getRect(find.text('b'));

      final gesture = await tester.startGesture(
        aRect.center,
        pointer: 7,
      );
      await tester.pump();
      await gesture.moveTo(aRect.center + const Offset(0, 20));
      await tester.pump();
      await gesture.moveTo(bRect.center);
      await tester.pump();
      await _settle(tester);
      await gesture.up();
      await tester.pump();
      await _settle(tester);

      expect(_gridIds(gridKey), ['b', 'a']);
      expect(updates, isNotEmpty);
      expect(updates.last, ['b', 'a']);

      expect(
        tester.getRect(find.text('a')).center.dy,
        closeTo(bRect.center.dy, 1),
      );
      expect(
        tester.getRect(find.text('b')).center.dy,
        closeTo(aRect.center.dy, 1),
      );
    });
  });
}
