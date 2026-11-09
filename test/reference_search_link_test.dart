import 'dart:convert';

import 'package:fake_location/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const target = LatLng(39.908722, 116.397499);

  test('高德链接按经度在前解析，支持分享文本和声明 WGS84', () {
    final gcj = CoordinateInput.parse(
      '我分享了地点：https://uri.amap.com/marker?position=116.397499%2C39.908722&name=天安门',
    );
    expect(gcj?.source, CoordSystem.gcj);
    expect(Coord.distanceMeters(gcj!.gcj, target), lessThan(0.1));
    final wgs = CoordinateInput.parse(
      'https://uri.amap.com/marker?position=116.397499,39.908722&coordinate=wgs84',
    );
    expect(wgs?.source, CoordSystem.wgs);
    expect(
      Coord.distanceMeters(wgs!.gcj, Coord.wgsToGcj(target)),
      lessThan(0.1),
    );
  });

  test('百度链接按纬度在前解析，默认 BD09 且尊重显式坐标系', () {
    final bd = CoordinateInput.parse(
      'https://api.map.baidu.com/marker?location=39.915119,116.403963&output=html',
    );
    expect(bd?.source, CoordSystem.bd09);
    expect(Coord.distanceMeters(bd!.gcj, target), lessThan(50));
    final gcj = CoordinateInput.parse(
      'https://api.map.baidu.com/geocoder?location=39.908722,116.397499&coord_type=gcj02',
    );
    expect(Coord.distanceMeters(gcj!.gcj, target), lessThan(0.1));
  });

  test('腾讯单点链接解码 marker，区分腾讯坐标与 GPS', () {
    final marker = Uri.encodeQueryComponent(
      'coord:39.908722,116.397499;title:天安门;addr:北京',
    );
    final url = 'https://apis.map.qq.com/uri/v1/marker?marker=$marker';
    final gcj = CoordinateInput.parse(url);
    expect(gcj?.source, CoordSystem.gcj);
    expect(Coord.distanceMeters(gcj!.gcj, target), lessThan(0.1));
    expect(CoordinateInput.parse('$url&coord_type=1')?.source, CoordSystem.wgs);
  });

  test('Google 明确坐标链接与 geo URI 使用 WGS84', () {
    final google = CoordinateInput.parse(
      'https://www.google.com/maps/search/?api=1&query=-33.86882%2C151.20929',
    );
    expect(google?.latitude, -33.86882);
    expect(google?.longitude, 151.20929);
    expect(google?.source, CoordSystem.wgs);
    final geo = parseCoordinateQuery('geo:39.908722,116.397499?z=17');
    expect(Coord.distanceMeters(geo!, Coord.wgsToGcj(target)), lessThan(0.1));
  });

  test('地理链接使用查询中的坐标，不误用主体占位点', () {
    for (final query in [
      '39.908722,116.397499',
      '39.908722,116.397499(北京)',
      Uri.encodeQueryComponent('39.908722,116.397499(北京)'),
    ]) {
      final input = 'geo:0,0?q=$query';
      final reading = CoordinateInput.parse(input);
      expect(reading?.latitude, target.latitude);
      expect(reading?.longitude, target.longitude);
      expect(
        Coord.distanceMeters(
          parseCoordinateQuery(input)!,
          Coord.wgsToGcj(target),
        ),
        lessThan(0.1),
      );
    }
  });

  test('地理地址查询、重复或非法查询不回退到主体坐标', () {
    for (final input in [
      'geo:0,0?q=北京',
      'geo:39.9,116.4?q=1600+Amphitheatre+Parkway%2C+CA',
      'geo:0,0?q=39.9,116.4&q=30,120',
      'geo:0,0?q=39.9,116.4&q=39.9,116.4',
      'geo:0,0?q=',
      'geo:0,0?q=95,116.4',
      'geo:0,0?q=NaN,116.4',
      'geo:0,0?q=39.9,Infinity',
      'geo:0,0?q=39.9,116.4(北京)(上海)',
      'geo:0,0?q=%GG',
      'geo:0,0?q=39.9,116.4extra',
    ]) {
      expect(CoordinateInput.parse(input), isNull, reason: input);
      expect(parseCoordinateQuery(input), isNull, reason: input);
    }
  });

  test('普通地理链接保留真实零点、缩放参数与原坐标语法', () {
    final zero = CoordinateInput.parse('geo:0,0');
    expect(zero?.latitude, 0);
    expect(zero?.longitude, 0);
    final normal = CoordinateInput.parse('geo:39.908722,116.397499?z=17');
    expect(normal?.latitude, target.latitude);
    expect(normal?.longitude, target.longitude);
    expect(CoordinateInput.parse('gcj:39.908722,116.397499')?.gcj, target);
  });

  test('短链、陌生域名和无坐标链接不猜测数字', () {
    for (final url in [
      'https://surl.amap.com/12abc34',
      'https://example.com/39.9,116.4',
      'https://uri.amap.com.evil.test/marker?position=116.4,39.9',
      'https://uri.amap.com/marker?poiid=B001234567',
      'https://www.google.com/maps/search/?api=1&query=天安门',
    ]) {
      expect(CoordinateInput.parse(url), isNull, reason: url);
      expect(parseCoordinateQuery(url), isNull, reason: url);
    }
  });

  test('拒绝非法坐标、未知坐标系与存在歧义的多点链接', () {
    for (final url in [
      'https://uri.amap.com/marker?position=116.4,99',
      'https://uri.amap.com/marker?position=NaN,39.9',
      'https://uri.amap.com/marker?position=116.4,Infinity',
      'https://uri.amap.com/marker?position=116.4,39.9&position=120,30',
      'https://uri.amap.com/marker?position=116.4,39.9&coordinate=unknown',
      'https://api.map.baidu.com/marker?location=39.9,116.4&coord_type=bd09mc',
      'https://apis.map.qq.com/uri/v1/marker?marker=coord:39.9,116.4|coord:30,120',
      'https://www.google.com/maps/search/?api=1&query=39.9,116.4&query_place_id=other-place',
      'https://uri.amap.com/marker?position=%GG',
    ]) {
      expect(CoordinateInput.parse(url), isNull, reason: url);
    }
  });

  test('搜索共用坐标解析，但门牌号和年份仍作为地点名称', () {
    expect(parseCoordinateQuery('北京西路11号2单元'), isNull);
    expect(parseCoordinateQuery('2026 年 11 月'), isNull);
    expect(parseCoordinateQuery('N building E 39.9 116.4'), isNull);
    final point = parseCoordinateQuery('高德：39.908722，116.397499');
    expect(Coord.distanceMeters(point!, target), lessThan(0.1));
  });

  test('搜索服务失败始终返回中文原因，不泄露底层英文异常', () async {
    final clients = [
      MockClient(
        (_) async => throw http.ClientException(
          'Connection closed before full header was received',
        ),
      ),
      MockClient((_) async => http.Response('{}', 503)),
      MockClient((_) async => http.Response('not json', 200)),
    ];
    for (final client in clients) {
      final result = await SearchApi(client: client)
          .search('测试地点', center: target);
      expect(result.places, isEmpty);
      expect(result.notes, isNotEmpty);
      expect(RegExp(r'[A-Za-z]').hasMatch(result.notes.join()), isFalse);
      client.close();
    }
  });

  for (final (valid, geo) in [
    (true, false),
    (false, false),
    (true, true),
    (false, true),
  ]) {
    testWidgets(
      '搜索粘贴${geo ? '地理' : '网页'}${valid ? '坐标链接一次落点' : '无明确坐标链接中文提示'}，不发起地点搜索',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'app_config_v1': jsonEncode({'lastLat': 30.0, 'lastLng': 120.0}),
        });
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const mock = MethodChannel('fake_location/mock');
        const update = MethodChannel('fake_location/update');
        messenger.setMockMethodCallHandler(
          mock,
          (call) async => call.method == 'isRunning' ? false : null,
        );
        messenger.setMockMethodCallHandler(update, (_) async => null);
        addTearDown(() {
          messenger.setMockMethodCallHandler(mock, null);
          messenger.setMockMethodCallHandler(update, null);
        });
        var placeSearches = 0;
        final client = MockClient((request) async {
          if (request.url.host == 'map.baidu.com' ||
              (request.url.host == 'photon.komoot.io' &&
                  request.url.path == '/api/')) {
            placeSearches++;
          }
          return http.Response('{}', 200);
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(const FakeLocationApp());
          await tester.pump();
          final input = geo
              ? (valid ? 'geo:0,0?q=39.908722,116.397499(北京)' : 'geo:0,0?q=北京')
              : (valid
                    ? 'https://uri.amap.com/marker?position=116.397499,39.908722'
                    : 'https://surl.amap.com/12abc34');
          await tester.enterText(find.byType(TextField), input);
          await tester.pump(const Duration(milliseconds: 450));
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(placeSearches, 0);
          if (valid) {
            expect(find.text(geo ? '坐标选点' : '链接选点'), findsWidgets);
            final expected = geo ? Coord.wgsToGcj(target) : target;
            expect(
              find.text(formatLatLng(expected, digits: 6)),
              findsOneWidget,
            );
          } else {
            expect(
              find.textContaining(
                geo ? '地理链接未包含明确且有效的单点坐标' : '链接未包含可直接读取的单点坐标',
              ),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }, () => client);
      },
    );
  }
}
