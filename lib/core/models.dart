import 'package:latlong2/latlong.dart';

import 'coord.dart';

/// 地点数据来源，用于在搜索结果上做标识，也决定坐标是否需要再换算。
enum PlaceSource {
  amap('高德'),
  baidu('百度'),
  osm('OSM'),
  manual('地图'),
  saved('常用'),
  pasted('坐标');

  const PlaceSource(this.label);

  final String label;
}

/// 一个候选地点。坐标统一以 GCJ-02 保存，与地图底图一致。
class Place {
  const Place({
    required this.name,
    required this.gcj,
    this.address = '',
    this.category = '',
    this.source = PlaceSource.manual,
    this.distanceMeters,
  });

  final String name;
  final String address;
  final String category;
  final LatLng gcj;
  final PlaceSource source;
  final double? distanceMeters;

  String get subtitle {
    final parts = [address, category].where((e) => e.trim().isNotEmpty).toList();
    return parts.join(' · ');
  }

  Place withDistance(double? meters) => Place(
    name: name,
    gcj: gcj,
    address: address,
    category: category,
    source: source,
    distanceMeters: meters,
  );
}

/// 用户收藏的常用地点。
class SavedPlace {
  const SavedPlace({
    required this.id,
    required this.name,
    required this.gcj,
    this.address = '',
    required this.savedAt,
  });

  final String id;
  final String name;
  final String address;
  final LatLng gcj;
  final int savedAt;

  factory SavedPlace.fromPlace(Place place, {String? name}) => SavedPlace(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    name: (name ?? place.name).trim().isEmpty ? '未命名地点' : (name ?? place.name).trim(),
    gcj: place.gcj,
    address: place.address,
    savedAt: DateTime.now().millisecondsSinceEpoch,
  );

  Place toPlace() => Place(
    name: name,
    gcj: gcj,
    address: address,
    source: PlaceSource.saved,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'address': address,
    'lat': gcj.latitude,
    'lng': gcj.longitude,
    'savedAt': savedAt,
  };

  static SavedPlace? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final lat = raw['lat'];
    final lng = raw['lng'];
    if (id is! String || name is! String || lat is! num || lng is! num) {
      return null;
    }
    if (lat.abs() > 90 || lng.abs() > 180) return null;
    return SavedPlace(
      id: id,
      name: name,
      address: raw['address'] is String ? raw['address'] as String : '',
      gcj: LatLng(lat.toDouble(), lng.toDouble()),
      savedAt: raw['savedAt'] is num
          ? (raw['savedAt'] as num).toInt()
          : DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// 底图样式。
enum MapStyle {
  standard('标准'),
  satellite('卫星'),
  road('路网');

  const MapStyle(this.label);

  final String label;
}

/// 移动方式与默认速度（米/秒），对应 Fake Location 的速度档位。
enum MotionMode {
  walk('步行', 1.4),
  run('跑步', 3.2),
  cycle('骑行', 5.5),
  drive('驾车', 13.9),
  flight('飞行', 55.0),
  custom('自定义', 2.0);

  const MotionMode(this.label, this.defaultSpeed);

  final String label;
  final double defaultSpeed;

  /// 是否用「步频 × 步幅」来推算速度（走路和跑步才讲步频）。
  bool get usesSteps => this == MotionMode.walk || this == MotionMode.run;
}

/// 路线播放方式。
enum PlayMode {
  once('单程'),
  loop('循环'),
  pingpong('往返');

  const PlayMode(this.label);

  final String label;
}

/// 一条路线：途经点（GCJ-02）+ 速度参数。
class RoutePlan {
  RoutePlan({
    required this.points,
    this.motion = MotionMode.walk,
    this.playMode = PlayMode.loop,
    this.speed = 1.4,
    this.stepFreq = 110,
    this.stepLength = 0.65,
    this.name = '路线',
  });

  final List<LatLng> points;
  MotionMode motion;
  PlayMode playMode;
  double speed;

  /// 步频，步/分钟。
  double stepFreq;

  /// 步幅，米/步。
  double stepLength;
  String name;

  /// 实际使用的速度：步行/跑步按步频步幅算，其它用档位速度。
  double get effectiveSpeed => motion.usesSteps ? stepFreq / 60 * stepLength : speed;

  double get distanceMeters {
    var sum = 0.0;
    for (var i = 1; i < points.length; i++) {
      sum += Coord.distanceMeters(points[i - 1], points[i]);
    }
    return sum;
  }

  /// 按当前速度走完全程预计耗时。
  Duration get estimateDuration {
    final v = effectiveSpeed;
    if (v <= 0) return Duration.zero;
    return Duration(seconds: (distanceMeters / v).round());
  }

  RoutePlan copy() => RoutePlan(
    points: List<LatLng>.from(points),
    motion: motion,
    playMode: playMode,
    speed: speed,
    stepFreq: stepFreq,
    stepLength: stepLength,
    name: name,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'motion': motion.name,
    'playMode': playMode.name,
    'speed': speed,
    'stepFreq': stepFreq,
    'stepLength': stepLength,
    'points': points
        .map((p) => <String, double>{'lat': p.latitude, 'lng': p.longitude})
        .toList(),
  };

  static RoutePlan? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final list = raw['points'];
    if (list is! List || list.length < 2) return null;
    final points = <LatLng>[];
    for (final item in list) {
      if (item is! Map) return null;
      final lat = item['lat'];
      final lng = item['lng'];
      if (lat is! num || lng is! num || lat.abs() > 90 || lng.abs() > 180) {
        return null;
      }
      points.add(LatLng(lat.toDouble(), lng.toDouble()));
    }
    T pick<T extends Enum>(List<T> values, Object? raw, T fallback) {
      if (raw is! String) return fallback;
      for (final v in values) {
        if (v.name == raw) return v;
      }
      return fallback;
    }

    return RoutePlan(
      points: points,
      motion: pick(MotionMode.values, raw['motion'], MotionMode.walk),
      playMode: pick(PlayMode.values, raw['playMode'], PlayMode.loop),
      speed: (raw['speed'] as num?)?.toDouble() ?? 1.4,
      stepFreq: (raw['stepFreq'] as num?)?.toDouble() ?? 110,
      stepLength: (raw['stepLength'] as num?)?.toDouble() ?? 0.65,
      name: raw['name'] is String ? raw['name'] as String : '路线',
    );
  }
}

/// 应用配置（可持久化）。
class AppConfig {
  AppConfig({
    this.amapKey = '',
    this.mapStyle = MapStyle.standard,
    this.coordSystem = CoordSystem.gcj,
    this.showRadius = true,
    this.radiusMeters = 200,
    this.writeGcj = false,
    this.lastTarget,
    this.lastName,
    this.lastAddress,
    this.intervalMs = 500,
    this.accuracyMeters = 5,
    this.floatBar = false,
    this.motion = MotionMode.walk,
    this.stepFreq = 110,
    this.stepLength = 0.65,
    this.lastRoute,
  });

  String amapKey;
  MapStyle mapStyle;
  CoordSystem coordSystem;
  bool showRadius;
  double radiusMeters;

  /// 写入系统的坐标是否使用 GCJ-02。
  /// 绝大多数手机返回 WGS-84，保持 false 即可；个别国产 ROM / 应用会把系统坐标
  /// 直接当成 GCJ-02 使用，此时打开可以消掉约 500 米的偏移。
  bool writeGcj;
  LatLng? lastTarget;

  /// 上次选点的名称与地址，重开应用时直接复用，避免显示成“地图选点”。
  String? lastName;
  String? lastAddress;

  /// 坐标推送间隔（毫秒）。微信这类应用建议 100~200，普通场景 500 足够。
  int intervalMs;

  /// 模拟精度（米），写进 Location.accuracy，影响其它应用显示的范围圈。
  double accuracyMeters;

  /// 是否显示悬浮控制条。
  bool floatBar;

  /// 上次使用的运动方式与步频步幅，路线页默认沿用。
  MotionMode motion;
  double stepFreq;
  double stepLength;

  /// 上次的路线，重开应用后可一键复用。
  RoutePlan? lastRoute;

  AppConfig copy() => AppConfig(
    amapKey: amapKey,
    mapStyle: mapStyle,
    coordSystem: coordSystem,
    showRadius: showRadius,
    radiusMeters: radiusMeters,
    writeGcj: writeGcj,
    lastTarget: lastTarget,
    lastName: lastName,
    lastAddress: lastAddress,
    intervalMs: intervalMs,
    accuracyMeters: accuracyMeters,
    floatBar: floatBar,
    motion: motion,
    stepFreq: stepFreq,
    stepLength: stepLength,
    lastRoute: lastRoute,
  );
}

/// 一次「模拟是否生效」的检测结果：服务侧推送状态 + 系统读回的位置。
class MockReport {
  const MockReport({
    required this.serviceRunning,
    required this.mockAppSelected,
    required this.pushCount,
    required this.elapsedMs,
    required this.providers,
    this.systemWgs,
    this.systemAccuracy,
    this.systemIsMock = false,
    this.systemProvider,
  });

  final bool serviceRunning;
  final bool mockAppSelected;
  final int pushCount;

  /// 距最后一次成功推送的毫秒数，-1 表示从未推送。
  final int elapsedMs;
  final List<String> providers;
  final LatLng? systemWgs;
  final double? systemAccuracy;
  final bool systemIsMock;
  final String? systemProvider;

  /// 系统当前返回的位置与目标点的偏差（米），未知时为空。
  double? distanceTo(LatLng target) =>
      systemWgs == null ? null : Coord.distanceMeters(target, systemWgs!);

  /// 是否真正生效：服务在推送、系统读回的是模拟源、且位置基本吻合。
  bool get isEffective {
    if (!serviceRunning || !mockAppSelected || pushCount == 0) return false;
    if (systemWgs == null || !systemIsMock) return false;
    return true;
  }
}
