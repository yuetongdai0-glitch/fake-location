import 'package:latlong2/latlong.dart';

import 'coord.dart';
import 'models.dart';
import 'user_message.dart';

/// 只导出当前检测所需的白名单字段，便于真机排障，不带出整份设置或设备标识。
String buildMockDiagnostic({
  required MockReport report,
  required LatLng draftWgs,
  DateTime? checkedAt,
}) {
  final text = StringBuffer('虚拟定位检测快照\n');
  void row(String label, Object value) => text.writeln('$label：$value');
  if (checkedAt != null) row('检测时间', checkedAt.toIso8601String());
  for (final field in const {
    'manufacturer': '厂商',
    'brand': '品牌',
    'model': '机型',
    'androidVersion': '安卓版本',
    'sdkInt': '安卓接口级别',
    'buildDisplay': '系统版本标识',
    'buildIncremental': '系统增量版本',
    'appVersionName': '应用版本',
    'appVersionCode': '应用构建号',
  }.entries) {
    row(field.value, _deviceValue(report.deviceInfo[field.key]));
  }

  final applied = report.pushedWgs;
  final target = report.serviceRunning && applied != null ? applied : draftWgs;
  row('当前选点（按写入方式换算）', _point(draftWgs));
  row('服务执行目标（按写入方式换算）', _point(applied));
  row('模拟位置授权', report.mockAppSelected ? '已选择本应用' : '未选择本应用');
  row('模拟服务', report.serviceRunning ? '运行中' : '未运行');
  row('累计推送计数', report.pushCount);
  row('距最近成功推送', _age(report.elapsedMs));
  row('预期定位源', _sources(report.expectedProviders));
  row('最近推送未报错源', _sources(report.providers));
  row('逐源目标校验', report.matchesTarget(target) ? '通过' : '未通过或尚未确认');
  row('系统汇总坐标', _point(report.systemWgs));
  row('系统汇总来源', _source(report.systemProvider ?? ''));
  row('系统汇总模拟标记', report.systemIsMock ? '有' : '无');
  row(
    '系统汇总精度',
    report.systemAccuracy?.isFinite == true && report.systemAccuracy! >= 0
        ? '${report.systemAccuracy!.toStringAsFixed(1)} 米'
        : '未知',
  );

  final names = {
    ...report.expectedProviders,
    ...report.providers,
    ...report.providerLocations.map((location) => location.provider),
    ...report.providerErrors.keys,
  };
  for (final name in names) {
    text.writeln('\n${_source(name)}：');
    final readbacks = report.providerLocations.where(
      (location) => location.provider == name,
    );
    if (readbacks.isEmpty) text.writeln('  读回：暂无结果');
    for (final location in readbacks) {
      text.writeln('  读回坐标：${_point(location.point)}');
      text.writeln('  模拟标记：${location.isMock ? '有' : '无'}');
      text.writeln('  缓存年龄：${_age(location.ageMs)}');
      final distance =
          location.point != null &&
              Coord.isValidPoint(location.point!) &&
              Coord.isValidPoint(target)
          ? Coord.distanceMeters(target, location.point!)
          : null;
      text.writeln(
        '  与校验目标偏差：${distance == null ? '未知' : '${distance.toStringAsFixed(1)} 米'}',
      );
      text.writeln(
        '  读回校验：${location.matchesTarget(target) ? '通过' : '未通过或尚未确认'}',
      );
      if (location.error != null) {
        text.writeln('  读回错误：${_failure(location.error!)}');
      }
    }
    final failure = report.providerErrors[name];
    if (failure != null) text.writeln('  推送错误：${_failure(failure)}');
  }

  text.writeln();
  row('无线网络开关', report.wifiEnabled ? '已开启' : '已关闭');
  row('无线网络扫描开关', report.wifiScanEnabled ? '已开启' : '已关闭');
  row('已豁免电池优化', _state(report.ignoringBatteryOptimizations));
  row('省电模式', _state(report.powerSaveMode));
  row('后台运行受限', _state(report.backgroundRestricted));
  for (final error in report.powerErrors.values) {
    row('后台状态读取错误', _failure(error));
  }
  text.writeln('\n系统读回校验不代表第三方应用采用。');
  return text.toString();
}

/// 设备版本仅输出约定的标量；禁止把后来添加的嵌套信息意外序列化出来。
String _deviceValue(Object? value) {
  if (value is num && value.isFinite) return '$value';
  if (value is! String || value.trim().isEmpty) return '未知';
  final line = value.trim().replaceAll(RegExp(r'[\r\n]'), ' ');
  return line.length > 256 ? line.substring(0, 256) : line;
}

String _point(LatLng? point) => point != null && Coord.isValidPoint(point)
    ? '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}'
    : '无有效坐标';

String _age(int ageMs) => ageMs >= 0 ? '$ageMs 毫秒' : '未知';

String _state(bool? value) => value == null
    ? '未知'
    : value
    ? '是'
    : '否';

String _failure(String value) =>
    userMessage(Exception(value), fallback: '读取或推送失败，具体原因未提供');

String _sources(List<String> sources) =>
    sources.isEmpty ? '无' : sources.map(_source).join('、');

String _source(String source) => switch (source) {
  'gps' => '卫星源（gps）',
  'network' => '网络源（network）',
  'fused' => '融合源（fused）',
  'passive' => '被动源（passive）',
  _ => source.isEmpty ? '未知' : '其他定位源',
};
