import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'coord.dart';

/// 摇杆一次更新的实际位置与运动参数，供界面和系统定位使用同一份结果。
class JoystickStep {
  const JoystickStep(this.point, this.speed, this.bearing);

  final LatLng point;
  final double speed;
  final double bearing;
}

/// 杆量决定速度，单调计时决定路程；长时间调度停顿最多补一秒，避免恢复时突然跳跃。
JoystickStep advanceJoystick({
  required LatLng origin,
  required double north,
  required double east,
  required double speed,
  required int elapsedMs,
}) {
  if (!Coord.isValidPoint(origin) ||
      !north.isFinite ||
      !east.isFinite ||
      !speed.isFinite ||
      speed < 0 ||
      speed > 300) {
    throw const FormatException('摇杆位置或速度无效');
  }
  final magnitude = math.sqrt(north * north + east * east);
  if (magnitude == 0 || elapsedMs <= 0 || speed == 0) {
    return JoystickStep(origin, 0, 0);
  }
  final bearing = math.atan2(east, north);
  final actualSpeed = speed * magnitude.clamp(0.0, 1.0);
  final meters = actualSpeed * elapsedMs.clamp(0, 1000) / 1000;
  return JoystickStep(
    Coord.offsetMeters(
      origin,
      north: meters * math.cos(bearing),
      east: meters * math.sin(bearing),
    ),
    actualSpeed,
    (bearing * 180 / math.pi + 360) % 360,
  );
}
