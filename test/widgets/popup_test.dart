import 'package:bett_box/models/models.dart';
import 'package:bett_box/widgets/popup.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpMenu(WidgetTester tester, VoidCallback onPressed) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: CommonPopupBox(
            targetBuilder: (open) =>
                IconButton(onPressed: open, icon: const Icon(Icons.more_vert)),
            popup: CommonPopupMenu(
              items: [PopupMenuItemData(label: 'action', onPressed: onPressed)],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<ValueNotifier<bool>> _pumpRemovableMenu(WidgetTester tester) async {
  final visible = ValueNotifier(true);
  addTearDown(visible.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, value, _) => value
              ? Align(
                  alignment: Alignment.topRight,
                  child: CommonPopupBox(
                    targetBuilder: (open) => IconButton(
                      onPressed: open,
                      icon: const Icon(Icons.more_vert),
                    ),
                    popup: CommonPopupMenu(
                      items: [
                        PopupMenuItemData(label: 'action', onPressed: () {}),
                      ],
                    ),
                  ),
                )
              : const SizedBox(),
        ),
      ),
    ),
  );
  return visible;
}

double _menuOpacity(WidgetTester tester) {
  return tester
      .widget<FadeTransition>(
        find
            .ancestor(
              of: find.byType(CommonPopupMenu),
              matching: find.byType(FadeTransition),
            )
            .first,
      )
      .opacity
      .value;
}

void main() {
  testWidgets('弹出动画等首帧构建完成后才开始，并完整播放', (tester) async {
    await _pumpMenu(tester, () {});

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    expect(_menuOpacity(tester), closeTo(0.1, 0.001));

    await tester.pump(const Duration(milliseconds: 200));
    expect(_menuOpacity(tester), closeTo(0.1, 0.001));

    await tester.pump(const Duration(milliseconds: 75));
    expect(_menuOpacity(tester), inExclusiveRange(0.1, 1.0));

    await tester.pump(const Duration(milliseconds: 75));
    expect(_menuOpacity(tester), closeTo(1.0, 0.001));
  });

  testWidgets('菜单项动作在关闭转场结束后才执行', (tester) async {
    var pressed = 0;
    await _pumpMenu(tester, () => pressed++);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('action'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    expect(pressed, 0);
    expect(find.byType(CommonPopupMenu), findsOneWidget);

    await tester.pumpAndSettle();
    expect(pressed, 1);
    expect(find.byType(CommonPopupMenu), findsNothing);
  });

  testWidgets('菜单贴着触发按钮下方弹出，右缘对齐按钮右缘', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CommonPopupBox(
              targetBuilder: (open) => IconButton(
                onPressed: open,
                icon: const Icon(Icons.more_vert),
              ),
              popup: CommonPopupMenu(
                items: [PopupMenuItemData(label: 'action', onPressed: () {})],
              ),
            ),
          ),
        ),
      ),
    );
    final trigger = tester.getRect(find.byType(IconButton));
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    final menu = tester.getRect(find.byType(CommonPopupMenu));
    // 锚点 = 触发盒右下角 + 4 间距；delegate 让菜单右缘对齐锚点 x、顶边取锚点 y。
    // 任何额外的 translate/补偿都会打破这两个等式。
    expect(menu.top, moreOrLessEquals(trigger.bottom + 4));
    expect(menu.right, moreOrLessEquals(trigger.right));
  });

  testWidgets('从未打开过的菜单被移除时正常释放', (tester) async {
    final visible = await _pumpRemovableMenu(tester);
    visible.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(CommonPopupBox), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('菜单打开期间锚点被移除，菜单仍可正常关闭', (tester) async {
    final visible = await _pumpRemovableMenu(tester);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    visible.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(CommonPopupBox), findsNothing);
    expect(find.byType(CommonPopupMenu), findsOneWidget);

    await tester.tapAt(const Offset(10, 590));
    await tester.pumpAndSettle();
    expect(find.byType(CommonPopupMenu), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('菜单与触发盒等宽，菜单项无可视左右留白', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: CommonPopupBox(
              targetBuilder: (open) => SizedBox(
                width: 320,
                height: 120,
                child: Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    onPressed: open,
                    icon: const Icon(Icons.more_vert),
                  ),
                ),
              ),
              popup: CommonPopupMenu(
                items: [
                  PopupMenuItemData(label: 'action', onPressed: () {}),
                  PopupMenuItemData(label: 'another action', onPressed: () {}),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final target = tester.getRect(find.byType(CommonPopupBox));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    final surface = tester.getRect(
      find
          .descendant(
            of: find.byType(CommonPopupMenu),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(surface.width, moreOrLessEquals(target.width));
    expect(surface.left, moreOrLessEquals(target.left));
    expect(surface.right, moreOrLessEquals(target.right));

    final rows = find.descendant(
      of: find.byType(CommonPopupMenu),
      matching: find.byType(InkWell),
    );
    expect(rows, findsNWidgets(2));
    for (var i = 0; i < 2; i++) {
      final rect = tester.getRect(rows.at(i));
      expect(rect.left, moreOrLessEquals(surface.left));
      expect(rect.right, moreOrLessEquals(surface.right));
    }
  });

  testWidgets('右键菜单与锚点等宽', (tester) async {
    final key = GlobalKey();
    late BuildContext menuContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              key: key,
              width: 300,
              height: 40,
              child: Builder(
                builder: (context) {
                  menuContext = context;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      ),
    );
    final anchor = tester.getRect(find.byKey(key));
    showContextMenu(
      menuContext,
      anchor: anchor,
      items: [PopupMenuItemData(label: 'action', onPressed: () {})],
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final surface = tester.getRect(
      find
          .ancestor(
            of: find.byType(CommonPopupMenu),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(surface.width, moreOrLessEquals(anchor.width));
  });

  testWidgets('推入菜单的同一帧锚点被移除，菜单首帧构建不报错', (tester) async {
    final visible = await _pumpRemovableMenu(tester);
    await tester.tap(find.byIcon(Icons.more_vert));
    visible.value = false;
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(CommonPopupMenu), findsOneWidget);

    await tester.tapAt(const Offset(10, 590));
    await tester.pumpAndSettle();
    expect(find.byType(CommonPopupMenu), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
