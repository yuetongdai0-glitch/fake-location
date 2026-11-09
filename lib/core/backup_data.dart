import 'dart:convert';

import 'coord.dart';
import 'models.dart';

/// 已完整预检的版本一备份；解析阶段不修改配置或本地存储。
class BackupData {
  const BackupData({
    required this.favorites,
    required this.routes,
    required this.config,
  });

  final List<SavedPlace> favorites;
  final List<RoutePlan> routes;
  final AppConfig config;

  /// 整份备份校验通过后才返回结果，不能先覆盖有效部分再忽略后面的坏数据。
  factory BackupData.parse(String source, {required AppConfig baseline}) {
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded['app'] != 'fake_location') {
      throw const FormatException('这段文本不是本应用的备份');
    }
    if (decoded['version'] != 1) {
      throw const FormatException('不支持此备份版本');
    }
    final rawFavorites = decoded['favorites'];
    final rawRoutes = decoded['routes'];
    final rawConfig = decoded['config'];
    if (rawFavorites is! List || rawRoutes is! List || rawConfig is! Map) {
      throw const FormatException('备份缺少完整的地点、路线或配置');
    }

    final favorites = <SavedPlace>[];
    for (final raw in rawFavorites) {
      final place = SavedPlace.tryFromJson(raw);
      if (place == null) throw const FormatException('备份中包含无效地点');
      favorites.add(place);
    }
    final routes = <RoutePlan>[];
    for (final raw in rawRoutes) {
      if (raw is! Map) throw const FormatException('备份中包含无效路线');
      // 路线模型兼容旧本地数据时可回落默认枚举，外部导入不能静默改变运动方式。
      _enum(raw, 'motion', MotionMode.values, MotionMode.walk, '路线运动方式');
      _enum(raw, 'playMode', PlayMode.values, PlayMode.loop, '路线播放方式');
      final route = RoutePlan.tryFromJson(raw);
      if (route == null) throw const FormatException('备份中包含无效路线');
      routes.add(route);
    }

    // 当前选点、名称和上次路线未出现在旧版导出中，必须从现有配置保留。
    final config = baseline.copy()
      ..amapKey = _string(rawConfig, 'amapKey', baseline.amapKey, '搜索密钥')
      ..mapStyle = _enum(
        rawConfig,
        'mapStyle',
        MapStyle.values,
        baseline.mapStyle,
        '地图样式',
      )
      ..coordSystem = _enum(
        rawConfig,
        'coordSystem',
        CoordSystem.values,
        baseline.coordSystem,
        '坐标显示方式',
      )
      ..motion = _enum(
        rawConfig,
        'motion',
        MotionMode.values,
        baseline.motion,
        '运动方式',
      )
      ..showRadius = _boolean(
        rawConfig,
        'showRadius',
        baseline.showRadius,
        '范围圈开关',
      )
      ..writeGcj = _boolean(rawConfig, 'writeGcj', baseline.writeGcj, '系统坐标开关')
      ..floatBar = _boolean(rawConfig, 'floatBar', baseline.floatBar, '悬浮控制条开关')
      ..radiusMeters = _number(
        rawConfig,
        'radiusMeters',
        baseline.radiusMeters,
        1,
        100000,
        '范围圈半径',
      )
      ..accuracyMeters = _number(
        rawConfig,
        'accuracyMeters',
        baseline.accuracyMeters,
        1,
        100,
        '模拟精度',
      )
      ..stepFreq = _number(
        rawConfig,
        'stepFreq',
        baseline.stepFreq,
        40,
        220,
        '步频',
      )
      ..stepLength = _number(
        rawConfig,
        'stepLength',
        baseline.stepLength,
        0.3,
        1.2,
        '步幅',
      );
    final interval = _number(
      rawConfig,
      'intervalMs',
      baseline.intervalMs.toDouble(),
      50,
      5000,
      '推送间隔',
    );
    if (interval != interval.truncateToDouble()) {
      throw const FormatException('备份中的推送间隔必须为整数');
    }
    config.intervalMs = interval.toInt();
    config.normalize();
    return BackupData(favorites: favorites, routes: routes, config: config);
  }

  /// 保留缺省项以兼容已有版本一备份，但显式提供的错误类型必须拒绝。
  static String _string(Map raw, String key, String fallback, String label) {
    if (!raw.containsKey(key)) return fallback;
    final value = raw[key];
    if (value is! String) throw FormatException('备份中的$label格式不正确');
    return value;
  }

  static bool _boolean(Map raw, String key, bool fallback, String label) {
    if (!raw.containsKey(key)) return fallback;
    final value = raw[key];
    if (value is! bool) throw FormatException('备份中的$label格式不正确');
    return value;
  }

  /// 先验证有限值与允许范围，再转换，禁止用夹紧方式掩盖外部坏数据。
  static double _number(
    Map raw,
    String key,
    double fallback,
    double min,
    double max,
    String label,
  ) {
    if (!raw.containsKey(key)) return fallback;
    final value = raw[key];
    if (value is! num || !value.isFinite || value < min || value > max) {
      throw FormatException('备份中的$label超出允许范围');
    }
    return value.toDouble();
  }

  static T _enum<T extends Enum>(
    Map raw,
    String key,
    List<T> values,
    T fallback,
    String label,
  ) {
    if (!raw.containsKey(key)) return fallback;
    for (final value in values) {
      if (value.name == raw[key]) return value;
    }
    throw FormatException('备份中的$label无效');
  }
}
