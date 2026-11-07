import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:fake_location/main.dart';

void main() {
  // 天安门，GCJ-02
  const LatLng tiananmen = LatLng(39.908722, 116.397499);

  group('坐标解析 · 十进制', () {
    test('逗号分隔按 GCJ 前缀解释', () {
      final r = CoordinateInput.parse('gcj: 39.908722, 116.397499');
      expect(r, isNotNull);
      expect(r!.source, CoordSystem.gcj);
      expect(r.latitude, closeTo(39.908722, 1e-6));
      expect(r.longitude, closeTo(116.397499, 1e-6));
      expect(Coord.distanceMeters(r.gcj, tiananmen), lessThan(1));
    });

    test('没有前缀默认 WGS-84，并换算到 GCJ', () {
      final r = CoordinateInput.parse('39.908722, 116.397499');
      expect(r, isNotNull);
      expect(r!.source, CoordSystem.wgs);
      // 国内 WGS 与 GCJ 有数百米偏移
      expect(Coord.distanceMeters(r.gcj, tiananmen), greaterThan(100));
    });

    test('支持全角逗号、负数和空格', () {
      final r = CoordinateInput.parse('-33.868820， 151.209290');
      expect(r, isNotNull);
      expect(r!.latitude, closeTo(-33.86882, 1e-6));
      expect(r.longitude, closeTo(151.20929, 1e-6));
    });

    test('高德/百度这样的中文前缀也认', () {
      final gcj = CoordinateInput.parse('高德：39.908722, 116.397499');
      expect(gcj?.source, CoordSystem.gcj);
      final bd = CoordinateInput.parse('百度：39.915119, 116.403963');
      expect(bd?.source, CoordSystem.bd09);
    });

    test('百度坐标换算后落在天安门附近', () {
      final bd = CoordinateInput.parse('bd: 39.915119, 116.403963');
      expect(bd, isNotNull);
      expect(Coord.distanceMeters(bd!.gcj, tiananmen), lessThan(50));
    });
  });

  group('坐标解析 · 度分秒与方向字母', () {
    test('度分秒带 N/E', () {
      final r = CoordinateInput.parse(
        '39°54′31.4″N 116°23′51.0″E',
      );
      expect(r, isNotNull);
      expect(r!.latitude, closeTo(39.908722, 1e-4));
      expect(r.longitude, closeTo(116.3975, 1e-4));
    });

    test('度分秒用直引号也能解析', () {
      final r = CoordinateInput.parse("39°54'31.4\"N 116°23'51.0\"E");
      expect(r, isNotNull);
      expect(r!.latitude, closeTo(39.908722, 1e-4));
      expect(r.longitude, closeTo(116.3975, 1e-4));
    });

    test('N/E 方向字母不影响正数', () {
      final r = CoordinateInput.parse('39.908722N, 116.397499E');
      expect(r, isNotNull);
      expect(r!.latitude, closeTo(39.908722, 1e-6));
      expect(r.longitude, closeTo(116.397499, 1e-6));
    });

    test('S/W 方向字母把值翻成负数', () {
      final r = CoordinateInput.parse('33.8688S, 151.2093W');
      expect(r, isNotNull);
      expect(r!.latitude, closeTo(-33.8688, 1e-6));
      expect(r.longitude, closeTo(-151.2093, 1e-6));
    });
  });

  group('坐标解析 · 链接与容错', () {
    test('geo: 链接按 WGS-84 处理', () {
      final r = CoordinateInput.parse('geo:39.908722,116.397499?z=17');
      expect(r, isNotNull);
      expect(r!.source, CoordSystem.wgs);
      expect(r.latitude, closeTo(39.908722, 1e-6));
      expect(r.longitude, closeTo(116.397499, 1e-6));
    });

    test('纬度经度写反时自动交换', () {
      final r = CoordinateInput.parse('gcj: 116.397499, 39.908722');
      expect(r, isNotNull);
      expect(r!.latitude, closeTo(39.908722, 1e-6));
      expect(r.longitude, closeTo(116.397499, 1e-6));
    });

    test('纯文字、只有一个数字都返回 null', () {
      expect(CoordinateInput.parse(''), isNull);
      expect(CoordinateInput.parse('天安门'), isNull);
      expect(CoordinateInput.parse('39.908722'), isNull);
    });

    test('超出经纬度范围返回 null', () {
      expect(CoordinateInput.parse('95, 200'), isNull);
      expect(CoordinateInput.parse('120, 95'), isNull);
    });
  });
}
