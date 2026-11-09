import 'package:latlong2/latlong.dart';

import 'coord.dart';

/// 地点数据来源，用于在搜索结果上做标识，也决定坐标是否需要再换算。
enum PlaceSource {
  amap('高德'),
  baidu('百度'),
  osm('开放地图'),
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
    final parts = [
      address,
      category,
    ].where((e) => e.trim().isNotEmpty).toList();
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
    name: (name ?? place.name).trim().isEmpty
        ? '未命名地点'
        : (name ?? place.name).trim(),
    gcj: place.gcj,
    address: place.address,
    savedAt: DateTime.now().millisecondsSinceEpoch,
  );

  Place toPlace() =>
      Place(name: name, gcj: gcj, address: address, source: PlaceSource.saved);

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
    if (!Coord.isValidPoint(LatLng(lat.toDouble(), lng.toDouble())) ||
        id.trim().isEmpty) {
      return null;
    }
    return SavedPlace(
      id: id,
      name: name,
      address: raw['address'] is String ? raw['address'] as String : '',
      gcj: LatLng(lat.toDouble(), lng.toDouble()),
      savedAt: raw['savedAt'] is num && (raw['savedAt'] as num).isFinite
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
  double get effectiveSpeed =>
      motion.usesSteps ? stepFreq / 60 * stepLength : speed;

  /// 默认按系统实际写入的 WGS-84 坐标计算，与原生路线引擎一致。
  double get distanceMeters => distanceForWrite();

  /// 高级直接写入模式使用地图原点，其它模式先转换每个途经点再量距。
  double distanceForWrite({bool writeGcj = false}) {
    if (points.any((point) => !Coord.isValidPoint(point))) return double.nan;
    final writtenPoints = writeGcj
        ? points
        : points.map(Coord.gcjToWgs).toList();
    var sum = 0.0;
    for (var i = 1; i < writtenPoints.length; i++) {
      sum += Coord.distanceMeters(writtenPoints[i - 1], writtenPoints[i]);
    }
    // 循环必须沿回程段回到起点，与原生引擎一致，不能在终点瞬移。
    if (playMode == PlayMode.loop && writtenPoints.length > 1) {
      sum += Coord.distanceMeters(writtenPoints.last, writtenPoints.first);
    }
    return sum;
  }

  /// 按当前速度完成一轮的预计耗时；往返模式包含两个方向。
  Duration get estimateDuration => durationForWrite();

  /// 与写入模式下的里程同步，往返预计耗时仍代表完整一轮。
  Duration durationForWrite({bool writeGcj = false}) {
    final v = effectiveSpeed;
    final meters =
        distanceForWrite(writeGcj: writeGcj) *
        (playMode == PlayMode.pingpong ? 2 : 1);
    if (!v.isFinite || v <= 0 || !meters.isFinite) return Duration.zero;
    return Duration(seconds: (meters / v).round());
  }

  /// 外部路线必须有真实位移且参数处于引擎和界面支持的范围。
  bool get isValid =>
      points.length >= 2 &&
      points.every(Coord.isValidPoint) &&
      // 与原生去零长度段阈值一致，日期线别名和极点不同经度仍是同一地点。
      points
          .skip(1)
          .any(
            (point) => Coord.distanceMeters(point, points.first) > 0.000001,
          ) &&
      speed.isFinite &&
      speed >= 0.1 &&
      speed <= 300 &&
      stepFreq.isFinite &&
      stepFreq >= 40 &&
      stepFreq <= 220 &&
      stepLength.isFinite &&
      stepLength >= 0.3 &&
      stepLength <= 1.2;

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
      if (lat is! num ||
          lng is! num ||
          !Coord.isValidPoint(LatLng(lat.toDouble(), lng.toDouble()))) {
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

    double? number(String key, double fallback, double min, double max) {
      final value = raw[key];
      if (value == null) return fallback;
      if (value is! num || !value.isFinite || value < min || value > max) {
        return null;
      }
      return value.toDouble();
    }

    final speed = number('speed', 1.4, 0.1, 300);
    final stepFreq = number('stepFreq', 110, 40, 220);
    final stepLength = number('stepLength', 0.65, 0.3, 1.2);
    if (speed == null || stepFreq == null || stepLength == null) return null;
    final plan = RoutePlan(
      points: points,
      motion: pick(MotionMode.values, raw['motion'], MotionMode.walk),
      playMode: pick(PlayMode.values, raw['playMode'], PlayMode.loop),
      speed: speed,
      stepFreq: stepFreq,
      stepLength: stepLength,
      name: raw['name'] is String ? raw['name'] as String : '路线',
    );
    return plan.isValid ? plan : null;
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
    this.intervalMs = 200,
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

  /// 系统边界统一收敛配置数值；不把非法坐标夹成另一个看似有效的位置。
  void normalize() {
    double bounded(double value, double fallback, double min, double max) =>
        value.isFinite ? value.clamp(min, max).toDouble() : fallback;
    radiusMeters = bounded(radiusMeters, 200, 1, 100000);
    intervalMs = intervalMs.clamp(50, 5000);
    accuracyMeters = bounded(accuracyMeters, 5, 1, 100);
    stepFreq = bounded(stepFreq, 110, 40, 220);
    stepLength = bounded(stepLength, 0.65, 0.3, 1.2);
    if (lastTarget != null && !Coord.isValidPoint(lastTarget!)) {
      lastTarget = null;
      lastName = null;
      lastAddress = null;
    }
    if (lastRoute != null && !lastRoute!.isValid) lastRoute = null;
  }

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

/// 单个系统定位源的读回结果，用于发现 GPS 成功而网络定位仍返回原位的情况。
class MockProviderReport {
  const MockProviderReport({
    required this.provider,
    this.point,
    this.isMock = false,
    this.ageMs = -1,
    this.error,
  });

  /// 解析原生诊断结果；没有缓存或权限不足时保留错误而不伪造坐标。
  factory MockProviderReport.fromMap(Map<dynamic, dynamic> value) {
    final rawLat = value['lat'];
    final rawLng = value['lng'];
    final point = rawLat is num && rawLng is num
        ? LatLng(rawLat.toDouble(), rawLng.toDouble())
        : null;
    final valid = point != null && Coord.isValidPoint(point);
    final age = value['ageMs'];
    return MockProviderReport(
      provider: '${value['provider'] ?? ''}',
      point: valid ? point : null,
      isMock: value['mock'] == true,
      ageMs: age is num && age.isFinite ? age.toInt() : -1,
      error: value['error'] is String
          ? value['error'] as String
          : valid
          ? null
          : '定位源未返回有效坐标',
    );
  }

  final String provider;
  final LatLng? point;
  final bool isMock;
  final int ageMs;
  final String? error;

  /// 仅接受近期且带模拟标记的位置，避免旧缓存被误判为仍在生效。
  bool get isFreshMock =>
      error == null && point != null && isMock && ageMs >= 0 && ageMs < 5000;

  /// 该源是否返回当前目标，最大允许 50 米的精度误差。
  bool matchesTarget(LatLng target) =>
      isFreshMock &&
      Coord.isValidPoint(target) &&
      Coord.distanceMeters(target, point!) <= 50;
}

/// 一次检测结果：逐源推送、逐源读回和 WiFi 状态，不代表第三方 SDK 的最终定位。
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
    this.expectedProviders = const [],
    this.providerErrors = const {},
    this.providerLocations = const [],
    this.wifiEnabled = false,
    this.wifiScanEnabled = false,
    this.ignoringBatteryOptimizations,
    this.powerSaveMode,
    this.backgroundRestricted,
    this.powerErrors = const {},
    this.pushedWgs,
    this.deviceInfo = const {},
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
  final List<String> expectedProviders;
  final Map<String, String> providerErrors;
  final List<MockProviderReport> providerLocations;
  final bool wifiEnabled;
  final bool wifiScanEnabled;

  /// 无法读取或系统不支持时保持未知，避免误报已允许后台运行。
  final bool? ignoringBatteryOptimizations;
  final bool? powerSaveMode;
  final bool? backgroundRestricted;
  final Map<String, String> powerErrors;

  /// 服务实际写入的点，与地图上尚未应用的草稿点区分。
  final LatLng? pushedWgs;

  /// 仅包含排查兼容性需要的机型、系统和应用版本，不含设备唯一标识。
  final Map<String, Object?> deviceInfo;

  /// 至少一个源成功不能代表全部覆盖；未上报预期源时也不能判定完整。
  bool get hasFullCoverage =>
      expectedProviders.isNotEmpty &&
      providerErrors.isEmpty &&
      expectedProviders.every(providers.contains);

  /// 服务需要持续推送，历史累计次数不能证明当前仍在运行。
  bool get isPushing =>
      serviceRunning && pushCount > 0 && elapsedMs >= 0 && elapsedMs < 5000;

  /// 系统当前返回的位置与目标点的偏差（米），未知时为空。
  double? distanceTo(LatLng target) =>
      systemWgs == null ||
          !Coord.isValidPoint(systemWgs!) ||
          !Coord.isValidPoint(target)
      ? null
      : Coord.distanceMeters(target, systemWgs!);

  /// 各系统源均持续返回模拟位置；目标匹配另由 [matchesTarget] 判断。
  bool get isEffective =>
      mockAppSelected &&
      isPushing &&
      hasFullCoverage &&
      expectedProviders.every(
        (name) => providerLocations.any(
          (location) => location.provider == name && location.isFreshMock,
        ),
      );

  /// 所有预期定位源必须同时命中目标，避免读取到某个成功源后掩盖其它源失败。
  bool matchesTarget(LatLng target) =>
      isEffective &&
      expectedProviders.every(
        (name) => providerLocations.any(
          (location) =>
              location.provider == name && location.matchesTarget(target),
        ),
      );
}
