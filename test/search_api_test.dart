import 'dart:convert';

import 'package:fake_location/core/models.dart';
import 'package:fake_location/core/search_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

void main() {
  const center = LatLng(39.9, 116.4);

  test('高德联想保留坐标与地址，同名异地不合并并过滤非法点', () async {
    final requests = <Uri>[];
    final api = SearchApi(
      amapKey: 'test-key',
      client: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode({
            'status': '1',
            'tips': [
              {
                'name': '同名门店',
                'location': '116.4,39.9',
                'district': '东城区',
                'address': '甲街1号',
              },
              {'name': '同名门店', 'location': '116.5,39.8', 'district': '朝阳区'},
              {'name': '同名门店', 'location': '116.4,39.9'},
              {'name': '无坐标关键词', 'location': []},
              {'name': '非法坐标', 'location': 'NaN,39.9'},
              {'name': '越界坐标', 'location': '116.4,99'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final places = await api.suggest('同名', center: center);

    expect(requests, hasLength(1));
    expect(requests.single.path, '/v3/assistant/inputtips');
    expect(places, hasLength(2));
    expect(places.first.gcj, center);
    expect(places.first.address, '东城区 · 甲街1号');
    expect(places.first.source, PlaceSource.amap);
    expect(places.first.distanceMeters, 0);
    expect(places.last.gcj, const LatLng(39.8, 116.5));
  });

  test('无坐标联想通过正常搜索补全为可直接选点的 POI', () async {
    final requests = <String>[];
    final api = SearchApi(
      amapKey: 'test-key',
      client: MockClient((request) async {
        requests.add(request.url.path);
        return http.Response(
          jsonEncode(
            request.url.path.endsWith('inputtips')
                ? {
                    'status': '1',
                    'tips': [
                      {'name': '商场', 'location': []},
                    ],
                  }
                : {
                    'status': '1',
                    'pois': [
                      {
                        'name': '商场南门',
                        'location': '116.4,39.9',
                        'address': '商业街',
                      },
                    ],
                  },
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final places = await api.suggest('商场', center: center);

    expect(requests, ['/v3/assistant/inputtips', '/v3/place/text']);
    expect(places.single.name, '商场南门');
    expect(places.single.gcj, center);
  });
}
