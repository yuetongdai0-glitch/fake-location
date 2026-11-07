import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'coord.dart';
import 'models.dart';

/// 本地持久化：配置、常用地点、最近模拟记录。
/// 全部走 SharedPreferences，卸载应用才会丢失。
class AppStorage {
  AppStorage._(this._prefs);

  final SharedPreferences _prefs;

  static const _kConfig = 'app_config_v1';
  static const _kFavorites = 'favorite_places_v1';
  static const _kRecents = 'recent_places_v1';
  static const _kRoutes = 'saved_routes_v1';
  static const int maxRecents = 30;

  static Future<AppStorage> load() async =>
      AppStorage._(await SharedPreferences.getInstance());

  AppConfig readConfig() {
    final raw = _prefs.getString(_kConfig);
    final config = AppConfig();
    if (raw == null || raw.isEmpty) return config;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return config;
      final key = map['amapKey'];
      if (key is String) config.amapKey = key;
      final style = map['mapStyle'];
      if (style is String) {
        config.mapStyle = MapStyle.values.firstWhere(
          (e) => e.name == style,
          orElse: () => MapStyle.standard,
        );
      }
      final system = map['coordSystem'];
      if (system is String) {
        config.coordSystem = CoordSystem.values.firstWhere(
          (e) => e.name == system,
          orElse: () => CoordSystem.gcj,
        );
      }
      if (map['showRadius'] is bool) config.showRadius = map['showRadius'] as bool;
      if (map['writeGcj'] is bool) config.writeGcj = map['writeGcj'] as bool;
      if (map['radiusMeters'] is num) {
        config.radiusMeters = (map['radiusMeters'] as num).toDouble();
      }
      final lat = map['lastLat'];
      final lng = map['lastLng'];
      if (lat is num && lng is num && lat.abs() <= 90 && lng.abs() <= 180) {
        config.lastTarget = LatLng(lat.toDouble(), lng.toDouble());
      }
      if (map['lastName'] is String) config.lastName = map['lastName'] as String;
      if (map['lastAddress'] is String) {
        config.lastAddress = map['lastAddress'] as String;
      }
      if (map['intervalMs'] is num) {
        config.intervalMs = (map['intervalMs'] as num).toInt().clamp(50, 5000);
      }
      if (map['accuracyMeters'] is num) {
        config.accuracyMeters = (map['accuracyMeters'] as num).toDouble();
      }
      if (map['floatBar'] is bool) config.floatBar = map['floatBar'] as bool;
      final motion = map['motion'];
      if (motion is String) {
        config.motion = MotionMode.values.firstWhere(
          (e) => e.name == motion,
          orElse: () => MotionMode.walk,
        );
      }
      if (map['stepFreq'] is num) {
        config.stepFreq = (map['stepFreq'] as num).toDouble();
      }
      if (map['stepLength'] is num) {
        config.stepLength = (map['stepLength'] as num).toDouble();
      }
      config.lastRoute = RoutePlan.tryFromJson(map['lastRoute']);
    } catch (_) {
      // 配置损坏时回落到默认值，不阻断启动。
    }
    return config;
  }

  Future<void> writeConfig(AppConfig config) async {
    await _prefs.setString(
      _kConfig,
      jsonEncode(<String, Object?>{
        'amapKey': config.amapKey,
        'mapStyle': config.mapStyle.name,
        'coordSystem': config.coordSystem.name,
        'showRadius': config.showRadius,
        'writeGcj': config.writeGcj,
        'radiusMeters': config.radiusMeters,
        'lastLat': config.lastTarget?.latitude,
        'lastLng': config.lastTarget?.longitude,
        'lastName': config.lastName,
        'lastAddress': config.lastAddress,
        'intervalMs': config.intervalMs,
        'accuracyMeters': config.accuracyMeters,
        'floatBar': config.floatBar,
        'motion': config.motion.name,
        'stepFreq': config.stepFreq,
        'stepLength': config.stepLength,
        'lastRoute': config.lastRoute?.toJson(),
      }),
    );
  }

  List<SavedPlace> readFavorites() => _readPlaces(_kFavorites);

  Future<void> writeFavorites(List<SavedPlace> places) =>
      _writePlaces(_kFavorites, places);

  List<SavedPlace> readRecents() => _readPlaces(_kRecents);

  Future<void> addRecent(Place place) async {
    final list = readRecents();
    // 同一坐标 30 米内视为同一地点，避免刷屏。
    list.removeWhere(
      (e) => Coord.distanceMeters(e.gcj, place.gcj) < 30 &&
          e.name == place.name,
    );
    list.insert(
      0,
      SavedPlace(
        id: 'r${DateTime.now().microsecondsSinceEpoch}',
        name: place.name,
        gcj: place.gcj,
        address: place.address,
        savedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (list.length > maxRecents) list.removeRange(maxRecents, list.length);
    await _writePlaces(_kRecents, list);
  }

  Future<void> clearRecents() => _prefs.remove(_kRecents);

  List<RoutePlan> readRoutes() {
    final raw = _prefs.getString(_kRoutes);
    if (raw == null || raw.isEmpty) return <RoutePlan>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <RoutePlan>[];
      return decoded.map(RoutePlan.tryFromJson).whereType<RoutePlan>().toList();
    } catch (_) {
      return <RoutePlan>[];
    }
  }

  Future<void> writeRoutes(List<RoutePlan> routes) async {
    await _prefs.setString(
      _kRoutes,
      jsonEncode(routes.map((e) => e.toJson()).toList()),
    );
  }

  List<SavedPlace> _readPlaces(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return <SavedPlace>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <SavedPlace>[];
      return decoded
          .map(SavedPlace.tryFromJson)
          .whereType<SavedPlace>()
          .toList(growable: true);
    } catch (_) {
      return <SavedPlace>[];
    }
  }

  Future<void> _writePlaces(String key, List<SavedPlace> places) async {
    await _prefs.setString(
      key,
      jsonEncode(places.map((e) => e.toJson()).toList()),
    );
  }
}
