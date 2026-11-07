import 'package:fake_location/core/coord.dart';
import 'package:fake_location/core/models.dart';
import 'package:fake_location/core/search_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('坐标系转换', () {
    test('WGS-84 与 GCJ-02 往返误差小于 0.2 米', () {
      const wgs = LatLng(29.750134, 106.583211);
      final gcj = Coord.wgsToGcj(wgs);
      final back = Coord.gcjToWgs(gcj);
      expect(
        Coord.distanceMeters(wgs, back),
        lessThan(0.2),
        reason: '偏移应可逆，否则写入系统的坐标会跑偏',
      );
      // 国内 GCJ 偏移量通常在数百米量级
      expect(Coord.distanceMeters(wgs, gcj), greaterThan(100));
    });

    test('百度墨卡托按官方系数反解，天安门误差小于 30 米', () {
      const expected = LatLng(39.908722, 116.397499); // 天安门 GCJ-02
      final actual = Coord.bd09McToGcj(12958160, 4825926);
      expect(Coord.distanceMeters(expected, actual), lessThan(30));
    });

    test('BD-09 与 GCJ-02 往返误差小于 1 米', () {
      const gcj = LatLng(29.747288, 106.586908);
      final back = Coord.bd09ToGcj(Coord.gcjToBd09(gcj));
      expect(Coord.distanceMeters(gcj, back), lessThan(1));
    });

    test('按米平移：向北 10 米只改变纬度', () {
      const origin = LatLng(29.747288, 106.586908);
      final moved = Coord.offsetMeters(origin, north: 10);
      expect(Coord.distanceMeters(origin, moved), closeTo(10, 0.05));
      expect(moved.longitude, closeTo(origin.longitude, 1e-9));
    });
  });

  group('坐标输入解析', () {
    test('裸坐标按 WGS-84 解释并转成 GCJ-02', () {
      final parsed = parseCoordinateQuery('29.750134, 106.583211');
      expect(parsed, isNotNull);
      final gcj = Coord.wgsToGcj(const LatLng(29.750134, 106.583211));
      expect(Coord.distanceMeters(parsed!, gcj), lessThan(0.01));
    });

    test('支持 gcj: 与全角逗号', () {
      final parsed = parseCoordinateQuery('gcj:29.7473，106.5869');
      expect(parsed, isNotNull);
      expect(Coord.distanceMeters(parsed!, const LatLng(29.7473, 106.5869)),
          lessThan(0.01));
    });

    test('非法内容不会被当成坐标', () {
      expect(parseCoordinateQuery('悦港中学'), isNull);
      expect(parseCoordinateQuery('29.7,106.5,3'), isNull);
      expect(parseCoordinateQuery('200,300'), isNull);
    });
  });

  test('常用地点可序列化并反序列化', () {
    const place = Place(name: '公司', gcj: LatLng(29.7, 106.5), address: '某路 1 号');
    final saved = SavedPlace.fromPlace(place);
    final restored = SavedPlace.tryFromJson(saved.toJson());
    expect(restored, isNotNull);
    expect(restored!.name, '公司');
    expect(restored.address, '某路 1 号');
    expect(restored.gcj.latitude, closeTo(29.7, 1e-9));
  });
}
