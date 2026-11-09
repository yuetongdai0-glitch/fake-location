import 'dart:async';
import 'dart:convert';

import 'package:fake_location/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 构造高德联想/搜索回包，避免用真实网络验证请求先后顺序。
http.Response _places(String name, {bool tips = true}) => http.Response(
  jsonEncode({
    'status': '1',
    tips ? 'tips' : 'pois': [
      {'name': name, 'location': '116.4,39.9', 'address': '测试地址'},
    ],
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'app_config_v1': jsonEncode({
        'amapKey': 'test-key',
        'lastLat': 39.9,
        'lastLng': 116.4,
      }),
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('fake_location/mock'),
      (call) async {
        if (call.method == 'isRunning') return false;
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('fake_location/update'),
      (_) async => null,
    );
  });

  testWidgets('联想候选点击一次落点，不发起第二轮搜索', (tester) async {
    var searches = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('inputtips')) return _places('商场南门');
      if (request.url.path.endsWith('/text')) searches++;
      return http.Response('{}', 404);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(const FakeLocationApp());
      await tester.pump();
      await tester.enterText(find.byType(TextField), '商场');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump();
      expect(find.widgetWithText(ListTile, '商场南门'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, '商场南门'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.widgetWithText(ListTile, '商场南门'), findsNothing);
      expect(find.text('商场南门'), findsWidgets);
      expect(searches, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });

  testWidgets('旧搜索在选中新候选后回包不会复活列表或覆盖选点', (tester) async {
    final oldSearch = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/text')) return oldSearch.future;
      if (request.url.path.endsWith('inputtips')) return _places('新选中的南门');
      return http.Response('{}', 404);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(const FakeLocationApp());
      await tester.pump();
      await tester.enterText(find.byType(TextField), '旧搜索');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.enterText(find.byType(TextField), '新搜索');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump();
      await tester.tap(find.widgetWithText(ListTile, '新选中的南门'));
      await tester.pump();
      oldSearch.complete(_places('过期搜索结果', tips: false));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.widgetWithText(ListTile, '过期搜索结果'), findsNothing);
      expect(find.text('新选中的南门'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });

  testWidgets('地图选点后，旧联想回包不覆盖目标或重开列表', (tester) async {
    final suggestion = Completer<http.Response>();
    final client = MockClient(
      (request) async => request.url.path.endsWith('inputtips')
          ? suggestion.future
          : http.Response('{}', 404),
    );
    await http.runWithClient(() async {
      await tester.pumpWidget(const FakeLocationApp());
      await tester.pump();
      await tester.enterText(find.byType(TextField), '旧搜索');
      await tester.pump(const Duration(milliseconds: 450));
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      map.options.onTap!(
        const TapPosition(Offset.zero, Offset.zero),
        const LatLng(30, 120),
      );
      await tester.pump();
      suggestion.complete(_places('过期地图联想'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.widgetWithText(ListTile, '过期地图联想'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });

  for (final clear in [false, true]) {
    testWidgets('${clear ? '点击清空' : '删成短关键词'}后，旧联想回包不重新打开列表', (tester) async {
      final suggestion = Completer<http.Response>();
      final client = MockClient(
        (request) async => request.url.path.endsWith('inputtips')
            ? suggestion.future
            : http.Response('{}', 404),
      );
      await http.runWithClient(() async {
        await tester.pumpWidget(const FakeLocationApp());
        await tester.pump();
        await tester.enterText(find.byType(TextField), '旧搜索');
        await tester.pump(const Duration(milliseconds: 450));
        if (clear) {
          await tester.tap(find.byTooltip('清空搜索'));
        } else {
          await tester.enterText(find.byType(TextField), '短');
        }
        await tester.pump();
        suggestion.complete(_places('过期联想'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.widgetWithText(ListTile, '过期联想'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    });
  }
}
