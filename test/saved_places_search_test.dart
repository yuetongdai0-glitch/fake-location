import 'package:fake_location/core/models.dart';
import 'package:fake_location/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

SavedPlace _place(String id, String name, String address, LatLng point) =>
    SavedPlace(id: id, name: name, address: address, gcj: point, savedAt: 0);

final _favorites = [
  _place('a', '北门公园', '北京市东城区', const LatLng(39.9, 116.4)),
  _place('b', '住处', '南京市玄武区', const LatLng(32.06, 118.79)),
  _place('c', 'Riverside Park', '滨江路', const LatLng(30.5, 114.3)),
];
final _recents = [
  _place('r1', '故宫入口', '北京市东城区', const LatLng(39.91, 116.39)),
  _place('r2', '车站', '南京市', const LatLng(32.08, 118.8)),
];

/// 打开真实底部面板，以覆盖键盘避让、弹窗操作和关闭行为。
Future<void> _openSheet(
  WidgetTester tester, {
  Future<void> Function(SavedPlace, String)? onRename,
  Future<void> Function(SavedPlace)? onDelete,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => SavedPlacesSheet(
                favorites: _favorites,
                recents: _recents,
                onPick: (_) {},
                onDelete: onDelete ?? (_) async {},
                onRename: onRename ?? (_, _) async {},
                onSaveCurrent: () {},
                onClearRecents: () async {},
              ),
            ),
            child: const Text('打开地点'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开地点'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('本地搜索名称地址坐标，切换标签保留查询且可清空', (tester) async {
    await _openSheet(tester);
    await tester.enterText(find.byType(TextField), '北京');
    await tester.pump();
    expect(find.text('北门公园'), findsOneWidget);
    expect(find.text('住处'), findsNothing);
    await tester.tap(find.text('最近'));
    await tester.pump();
    expect(find.text('故宫入口'), findsOneWidget);
    expect(find.text('车站'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '北京',
    );

    await tester.tap(find.byTooltip('清空地点搜索'));
    await tester.pump();
    expect(find.text('车站'), findsOneWidget);
    await tester.tap(find.text('常用'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '39.9，116.4');
    await tester.pump();
    expect(find.text('北门公园'), findsOneWidget);
    expect(find.text('住处'), findsNothing);
    await tester.enterText(find.byType(TextField), 'riverside');
    await tester.pump();
    expect(find.text('Riverside Park'), findsOneWidget);
    expect(find.text('北门公园'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('筛选后重命名按新名字立即重算，不影响其它地点', (tester) async {
    String? renamed;
    await _openSheet(
      tester,
      onRename: (place, name) async {
        expect(place.id, 'a');
        renamed = name;
      },
    );
    await tester.enterText(find.byType(TextField), '北门');
    await tester.pump();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '东门入口');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(renamed, '东门入口');
    expect(find.text('没有找到匹配的地点，试试名称、地址或坐标。'), findsOneWidget);
    await tester.tap(find.byTooltip('清空地点搜索'));
    await tester.pump();
    expect(find.text('东门入口'), findsOneWidget);
    expect(find.text('住处'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('筛选后删除当前项，清空查询仍保留其它项', (tester) async {
    final deleted = <String>[];
    await _openSheet(tester, onDelete: (place) async => deleted.add(place.id));
    await tester.enterText(find.byType(TextField), '南京');
    await tester.pump();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(deleted, ['b']);
    expect(find.text('没有找到匹配的地点，试试名称、地址或坐标。'), findsOneWidget);
    await tester.tap(find.byTooltip('清空地点搜索'));
    await tester.pump();
    expect(find.text('住处'), findsNothing);
    expect(find.text('北门公园'), findsOneWidget);

    await tester.tap(find.text('最近'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '车站');
    await tester.pump();
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(deleted, ['b', 'r2']);
    expect(find.text('没有找到匹配的地点，试试名称、地址或坐标。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小屏与键盘占位下可滚动且不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
    await _openSheet(tester);
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pump();
    expect(find.text('没有找到匹配的地点，试试名称、地址或坐标。'), findsOneWidget);
    expect(find.text('把当前选点存为常用地点'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除保存失败保留筛选结果，并使用中文反馈', (tester) async {
    await _openSheet(
      tester,
      onDelete: (_) async {
        throw StateError('Disk write failed');
      },
    );
    await tester.enterText(find.byType(TextField), '北门');
    await tester.pump();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('北门公园'), findsOneWidget);
    expect(find.text('删除失败，请重试'), findsOneWidget);
    expect(find.textContaining('Disk write'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
