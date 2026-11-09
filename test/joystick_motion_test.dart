import 'package:fake_location/core/coord.dart';
import 'package:fake_location/core/joystick_motion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('半杆减半速度，飞行档不再被每步五米截断', () {
    const start = LatLng(30, 120);
    final full = advanceJoystick(
      origin: start,
      north: 1,
      east: 0,
      speed: 55,
      elapsedMs: 200,
    );
    final half = advanceJoystick(
      origin: start,
      north: 0.5,
      east: 0,
      speed: 55,
      elapsedMs: 200,
    );
    expect(Coord.distanceMeters(start, full.point), closeTo(11, 0.001));
    expect(Coord.distanceMeters(start, half.point), closeTo(5.5, 0.001));
    expect(half.speed, 27.5);
    expect(half.bearing, 0);
  });

  test('按实际调度时间移动，负时间不倒走，长停顿不补整段跳跃', () {
    const start = LatLng(0, 0);
    final step = advanceJoystick(
      origin: start,
      north: 0,
      east: 1,
      speed: 2,
      elapsedMs: 350,
    );
    expect(Coord.distanceMeters(start, step.point), closeTo(0.7, 0.001));
    expect(step.bearing, 90);
    expect(
      advanceJoystick(
        origin: start,
        north: 1,
        east: 0,
        speed: 2,
        elapsedMs: -1,
      ).point,
      start,
    );
    final resumed = advanceJoystick(
      origin: start,
      north: 1,
      east: 0,
      speed: 2,
      elapsedMs: 60_000,
    );
    expect(Coord.distanceMeters(start, resumed.point), closeTo(2, 0.001));
  });

  test('极点和日期线不产生非法坐标，异常输入直接拒绝', () {
    for (final start in [const LatLng(90, 0), const LatLng(0, 179.99999)]) {
      final step = advanceJoystick(
        origin: start,
        north: 0,
        east: 1,
        speed: 55,
        elapsedMs: 200,
      );
      expect(Coord.isValidPoint(step.point), isTrue);
      expect(Coord.distanceMeters(start, step.point), closeTo(11, 0.001));
    }
    expect(
      () => advanceJoystick(
        origin: const LatLng(0, 0),
        north: double.nan,
        east: 1,
        speed: 2,
        elapsedMs: 200,
      ),
      throwsFormatException,
    );
  });
}
