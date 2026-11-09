import 'package:fake_location/core/models.dart';
import 'package:fake_location/core/storage.dart';
import 'package:fake_location/ui/route_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('fake_location/mock');
const _points = [LatLng(29.75, 106.58), LatLng(29.751, 106.581)];
const _settingsKey = ValueKey('route-settings-button');

/// 经真实路由打开本地草稿，记录系统调用以验证设置真正影响下发参数。
Future<List<Map<dynamic, dynamic>>> _open(
  WidgetTester tester, {
  bool running = false,
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  final storage = await AppStorage.load();
  final starts = <Map<dynamic, dynamic>>[];
  var active = running;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'mockStatus') {
          return {'serviceActive': active, 'routeActive': active};
        }
        if (call.method == 'startRoute') {
          active = true;
          starts.add(Map<dynamic, dynamic>.from(call.arguments as Map));
        }
        if (call.method == 'stop') active = false;
        return null;
      });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: RoutePage(
        initial: _points.first,
        config: AppConfig()
          ..writeGcj = true
          ..lastRoute = RoutePlan(points: _points),
        storage: storage,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return starts;
}

Future<void> _settings(WidgetTester tester) async {
  await tester.tap(find.byKey(_settingsKey));
  await tester.pumpAndSettle();
  expect(find.text('路线设置'), findsOneWidget);
}

Future<void> _choose(WidgetTester tester, String label) async {
  final chip = find.widgetWithText(ChoiceChip, label);
  await tester.ensureVisible(chip);
  await tester.tap(chip);
  await tester.pump();
}

Future<void> _finish(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

List<LatLng> _draft(WidgetTester tester) => tester
    .widget<MarkerLayer>(find.byType(MarkerLayer))
    .markers
    .map((marker) => marker.point)
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('主视图只保留概览与操作，参数控件收进调整面板', (tester) async {
    await _open(tester);
    expect(find.text('路线模拟'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('route-summary-panel'))).height,
      lessThan(260),
    );
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.text('步频'), findsNothing);
    expect(find.text('步幅'), findsNothing);
    expect(find.textContaining('公里/小时'), findsOneWidget);
    expect(find.textContaining('长按拖动标记，点击可修改或删除'), findsNothing);
    await _settings(tester);
    expect(find.widgetWithText(ChoiceChip, '步行'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '单程'), findsOneWidget);
    expect(find.text('步频'), findsOneWidget);
    expect(find.text('步幅'), findsOneWidget);
    await _finish(tester, '取消');
    expect(find.byType(ChoiceChip), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('取消调整不改变草稿或下发参数，也不自动开始模拟', (tester) async {
    final starts = await _open(tester);
    await _settings(tester);
    await _choose(tester, '飞行');
    await _choose(tester, '往返');
    await _finish(tester, '取消');
    expect(starts, isEmpty);
    expect(_draft(tester), _points);
    await tester.tap(find.text('开始模拟'));
    await tester.pumpAndSettle();
    expect(starts.single['mode'], 'loop');
    expect(starts.single['speed'], closeTo(110 / 60 * 0.65, 1e-9));
    expect(starts.single['points'], [29.75, 106.58, 29.751, 106.581]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('完成调整后运动方式与播放规则随真实路线指令生效', (tester) async {
    final starts = await _open(tester);
    await _settings(tester);
    await _choose(tester, '飞行');
    await _choose(tester, '单程');
    await _finish(tester, '完成');
    expect(starts, isEmpty);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.textContaining('198.0'), findsOneWidget);
    await tester.tap(find.text('开始模拟'));
    await tester.pumpAndSettle();
    expect(starts.single['mode'], 'once');
    expect(starts.single['speed'], 55);
    expect(_draft(tester).take(2), _points);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('自定义速度和步频调整仍按正确单位下发', (tester) async {
    final starts = await _open(tester);
    await _settings(tester);
    await _choose(tester, '自定义');
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(20);
    await tester.pump();
    await _finish(tester, '完成');
    await tester.tap(find.text('开始模拟'));
    await tester.pumpAndSettle();
    expect(starts.single['speed'], 20);
    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    await _settings(tester);
    await _choose(tester, '步行');
    tester.widget<Slider>(find.byType(Slider).first).onChanged!(115);
    await tester.pump();
    await _finish(tester, '完成');
    await tester.tap(find.text('开始模拟'));
    await tester.pumpAndSettle();
    expect(starts.last['speed'], closeTo(115 / 60 * 0.65, 1e-9));
    expect(starts.last['stepLength'], 0.65);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('运行中参数入口锁定，暂停和停止仍然可用', (tester) async {
    await _open(tester, running: true);
    expect(
      tester.widget<TextButton>(find.byKey(_settingsKey)).onPressed,
      isNull,
    );
    await tester.tap(find.byKey(_settingsKey));
    await tester.pump();
    expect(find.text('路线设置'), findsNothing);
    expect(find.text('暂停'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('360像素大字号下停止提示浮在概览上方，不阻挡立即重新开始和停止', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final starts = await _open(tester, textScale: 1.6);
    await tester.tap(find.text('开始模拟'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    final feedback = find.text('已停止，恢复真实定位');
    expect(feedback, findsOneWidget);
    expect(
      tester.getRect(feedback).bottom,
      lessThan(
        tester.getRect(find.byKey(const ValueKey('route-summary-panel'))).top,
      ),
    );
    expect(tester.takeException(), isNull);
    // 反馈仍在显示，直接重新开始；不能靠等待提示消失让按钮碰巧可点。
    await tester.tap(find.text('开始模拟'));
    await tester.pumpAndSettle();
    expect(starts.length, 2);
    expect(find.text('停止'), findsOneWidget);
    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    expect(find.text('开始模拟'), findsOneWidget);
    expect(find.text('停止'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('360像素大字号下概览简洁，调整面板可滚动完成或取消', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _open(tester, textScale: 1.6);
    expect(
      tester.getSize(find.byKey(const ValueKey('route-summary-panel'))).height,
      lessThan(320),
    );
    expect(tester.takeException(), isNull);
    await _settings(tester);
    expect(tester.takeException(), isNull);
    await _choose(tester, '飞行');
    await _choose(tester, '单程');
    await _finish(tester, '完成');
    expect(tester.takeException(), isNull);
    await _settings(tester);
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '飞行')).selected,
      isTrue,
    );
    await _finish(tester, '取消');
    expect(_draft(tester), _points);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
