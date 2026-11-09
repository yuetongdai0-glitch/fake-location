import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/coord.dart';
import '../core/models.dart';
import '../core/route_tools.dart';
import '../core/storage.dart';
import '../core/user_message.dart';
import 'route_settings_sheet.dart';
import 'saved_routes_sheet.dart';

/// 路线模拟页：在地图上点出途经点，按速度沿路线移动，可循环/往返。
class RoutePage extends StatefulWidget {
  const RoutePage({
    super.key,
    required this.initial,
    required this.config,
    required this.storage,
  });

  final LatLng initial;
  final AppConfig config;
  final AppStorage storage;

  @override
  State<RoutePage> createState() => _RoutePageState();
}

enum _RouteTool { reverse, close, circle, start, fit, save, open, clear, help }

class _RoutePageState extends State<RoutePage> {
  static const _channel = MethodChannel('fake_location/mock');

  final MapController _map = MapController();
  final GlobalKey _panelViewportKey = GlobalKey();
  final List<LatLng> _points = [];
  final List<List<LatLng>> _undo = [];
  int? _editingIndex;
  bool _starting = false;
  bool _checkingStatus = true;
  List<LatLng>? _dragSnapshot;
  int? _dragIndex;
  Offset _dragScreenOffset = Offset.zero;

  bool get _simulationLocked => _running || _starting || _checkingStatus;
  bool get _editingLocked => _simulationLocked || _dragSnapshot != null;

  MotionMode _motion = MotionMode.walk;
  PlayMode _playMode = PlayMode.loop;
  double _speed = 1.4;
  double _stepFreq = 110;
  double _stepLength = 0.65;

  bool _running = false;
  bool _serviceActive = false;
  bool _holdingEndpoint = false;
  bool _paused = false;
  int _statusRevision = 0;
  double _progress = 0;
  double _travelled = 0;
  double _total = 0;
  LatLng? _current;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _motion = widget.config.motion;
    _speed = _motion.defaultSpeed;
    _stepFreq = widget.config.stepFreq;
    _stepLength = widget.config.stepLength;
    final last = widget.config.lastRoute;
    if (last != null && last.points.length >= 2) {
      _points.addAll(last.points);
      _motion = last.motion;
      _playMode = last.playMode;
      _speed = last.speed;
      _stepFreq = last.stepFreq;
      _stepLength = last.stepLength;
    } else {
      // 先使用当前目标为起点，也允许单独重选或删除。
      _points.add(widget.initial);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitRoute());
    unawaited(_restoreRunningRoute());
  }

  /// 返回路线页时继续控制已有任务，避免页面重建后把运行中的路线当作草稿。
  Future<void> _restoreRunningRoute() async {
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>(
        'mockStatus',
      );
      if (!mounted) return;
      if (status != null) _applyStatus(status);
      if (_serviceActive) _startPolling();
    } on PlatformException catch (e) {
      _toast(userMessage(e, fallback: '暂时无法读取路线状态，请返回后重试'));
    } finally {
      if (mounted) setState(() => _checkingStatus = false);
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _map.dispose();
    super.dispose();
  }

  double get _effectiveSpeed =>
      _motion.usesSteps ? _stepFreq / 60 * _stepLength : _speed;

  /// 与原生播放规则共用模型语义，循环包含回程，往返耗时包含来回。
  double get _distance =>
      _buildPlan().distanceForWrite(writeGcj: widget.config.writeGcj);

  String get _durationLabel {
    final seconds = _buildPlan()
        .durationForWrite(writeGcj: widget.config.writeGcj)
        .inSeconds;
    if (_effectiveSpeed <= 0 || _distance <= 0) return '—';
    if (seconds < 60) return '$seconds 秒';
    if (seconds < 3600) return '${(seconds / 60).toStringAsFixed(1)} 分钟';
    return '${(seconds / 3600).toStringAsFixed(1)} 小时';
  }

  /// 工具仅修改草稿；每个操作仍由既有快照撤销保护，并沿用运行锁。
  Future<void> _openRouteTools() async {
    if (_dragSnapshot != null) return;
    final tool = await showModalBottomSheet<_RouteTool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('路线工具')),
            for (final item in [
              (
                Icons.edit_location_alt_outlined,
                '重选起点',
                _RouteTool.start,
                !_editingLocked && _points.isNotEmpty,
              ),
              (
                Icons.center_focus_strong_outlined,
                '视角回到路线',
                _RouteTool.fit,
                true,
              ),
              (
                Icons.swap_vert,
                '反转路线',
                _RouteTool.reverse,
                !_editingLocked && _points.length >= 2,
              ),
              (
                Icons.join_full,
                '闭合路线',
                _RouteTool.close,
                !_editingLocked && _points.length >= 2,
              ),
              (
                Icons.circle_outlined,
                '按半径生成环线',
                _RouteTool.circle,
                !_editingLocked,
              ),
              (
                Icons.bookmark_add_outlined,
                '保存路线',
                _RouteTool.save,
                !_editingLocked && _points.length >= 2,
              ),
              (
                Icons.folder_open_outlined,
                '已保存路线',
                _RouteTool.open,
                !_editingLocked,
              ),
              (
                Icons.delete_sweep_outlined,
                '清空路线',
                _RouteTool.clear,
                !_editingLocked && _points.isNotEmpty,
              ),
              (Icons.help_outline, '编辑帮助', _RouteTool.help, true),
            ])
              ListTile(
                leading: Icon(item.$1),
                title: Text(item.$2),
                enabled: item.$4,
                onTap: item.$4 ? () => Navigator.pop(context, item.$3) : null,
              ),
          ],
        ),
      ),
    );
    if (!mounted || tool == null) return;
    if (tool == _RouteTool.fit) {
      _fitRoute();
      return;
    }
    if (tool == _RouteTool.help) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('编辑帮助'),
          content: const Text(
            '点击地图添加途经点。点击标记可重选或删除，长按可拖动。\n\n密集路线可放大后编辑小圆点；闭合路线的起终点重合时，可用“重选起点”。\n\n工具操作可撤销；循环模式会沿浅色回程线返回起点。运行中请先停止再编辑。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    if (_editingLocked) return;
    switch (tool) {
      case _RouteTool.start:
        _selectPoint(0);
        return;
      case _RouteTool.save:
        await _saveRoute();
        return;
      case _RouteTool.open:
        await _openSaved();
        return;
      case _RouteTool.clear:
        final clear = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('清空路线'),
            content: const Text('清空当前草稿？清空后仍可撤销。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('清空'),
              ),
            ],
          ),
        );
        if (mounted && clear == true && !_editingLocked) {
          _changePoints(_points.clear);
        }
        return;
      default:
        break;
    }
    if (!mounted || _editingLocked) return;
    try {
      final List<LatLng> points;
      if (tool == _RouteTool.circle) {
        final center = _points.isEmpty
            ? widget.initial
            : _points[_editingIndex ?? 0];
        final options = await showDialog<({double radius, bool clockwise})>(
          context: context,
          builder: (_) => _CircleRouteDialog(
            center: center,
            centerName: _points.isEmpty
                ? '当前目标'
                : _editingIndex == null
                ? '当前起点'
                : '选中的第 ${_editingIndex! + 1} 个点',
          ),
        );
        if (!mounted || options == null || _editingLocked) return;
        points = RouteTools.circle(
          center: center,
          radiusMeters: options.radius,
          clockwise: options.clockwise,
        );
      } else {
        points = tool == _RouteTool.reverse
            ? RouteTools.reverse(_points)
            : RouteTools.close(_points);
        if (tool == _RouteTool.close && points.length == _points.length) {
          _toast('路线已经闭合，无需重复添加起点');
          return;
        }
      }
      _changePoints(
        () => _points
          ..clear()
          ..addAll(points),
      );
      _fitRoute();
      _toast(switch (tool) {
        _RouteTool.reverse => '路线已反转，可撤销',
        _RouteTool.close => '路线已闭合，可撤销',
        _RouteTool.circle => '环线已生成，可撤销；点击开始模拟后才会运行',
        _ => '路线已更新，可撤销',
      });
    } catch (error) {
      _toast(userMessage(error, fallback: '路线工具执行失败，请检查参数'));
    }
  }

  /// 弹层只修改自己的参数副本，点击完成后一次性应用，取消不污染当前草稿。
  Future<void> _openRouteSettings() async {
    if (_editingLocked) return;
    final settings = await showModalBottomSheet<RoutePlan>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => RouteSettingsSheet(initial: _buildPlan()),
    );
    if (!mounted || settings == null || _editingLocked) return;
    setState(() {
      _motion = settings.motion;
      _playMode = settings.playMode;
      _speed = settings.speed;
      _stepFreq = settings.stepFreq;
      _stepLength = settings.stepLength;
    });
  }

  /// 所有描点操作保留快照，修改、删除和清空后都能撤销。
  void _changePoints(VoidCallback change) {
    if (_editingLocked) return;
    setState(() {
      _undo.add(List<LatLng>.of(_points));
      change();
      _editingIndex = null;
      if (!_serviceActive) _current = null;
    });
  }

  /// 选中已有点后，下一次地图点击替换该点，不再误追加一个途经点。
  void _selectPoint(int index) {
    if (_editingLocked) return;
    setState(() => _editingIndex = index);
  }

  /// 空白地图点击用于追加；编辑状态用于移动起点、终点或途经点。
  void _tapMap(LatLng point) {
    final index = _editingIndex;
    _changePoints(() {
      if (index == null) {
        _points.add(point);
      } else {
        _points[index] = point;
      }
    });
  }

  /// 以标记中心开始拖动，保留手指按下偏移，避免拖动起点时图标跳到指尖。
  void _beginPointDrag(int index) {
    if (_editingLocked) return;
    setState(() {
      _dragSnapshot = List<LatLng>.of(_points);
      _dragIndex = index;
      _dragScreenOffset = _map.camera.latLngToScreenOffset(_points[index]);
      _editingIndex = index;
    });
  }

  /// 通过地图投影换算屏幕位移，缩放和旋转后拖点仍保持正确距离与方向。
  void _updatePointDrag(int index, Offset offset) {
    if (_simulationLocked || _dragIndex != index || _dragSnapshot == null) {
      return;
    }
    final point = _map.camera.screenOffsetToLatLng(_dragScreenOffset + offset);
    setState(() => _points[index] = point);
  }

  /// 一次完整拖动只记一次撤销；系统取消手势时恢复原位，不留下半次编辑。
  void _finishPointDrag(int index, {bool canceled = false}) {
    final snapshot = _dragSnapshot;
    if (!mounted || _dragIndex != index || snapshot == null) return;
    setState(() {
      if (canceled) {
        _points
          ..clear()
          ..addAll(snapshot);
      } else if (_points[index] != snapshot[index]) {
        _undo.add(snapshot);
        if (!_serviceActive) _current = null;
      }
      _dragSnapshot = null;
      _dragIndex = null;
      _editingIndex = null;
    });
  }

  /// 恢复上一次完整草稿，避免清空或删错起点后无法找回。
  void _undoEdit() {
    if (_editingLocked || _undo.isEmpty) return;
    setState(() {
      _points
        ..clear()
        ..addAll(_undo.removeLast());
      _editingIndex = null;
      if (!_serviceActive) _current = null;
    });
  }

  void _fitRoute() {
    if (!mounted) return;
    if (_points.length < 2) {
      try {
        _map.move(_points.isEmpty ? widget.initial : _points.first, 16);
      } catch (_) {}
      return;
    }
    final lats = _points.map((e) => e.latitude);
    // 沿路线展开最短经差，跨日期变更线的环线仍在同一地图世界中缩放。
    var previous = _points.first.longitude;
    var west = previous;
    var east = previous;
    for (final point in _points.skip(1)) {
      previous += (point.longitude - previous + 180) % 360 - 180;
      west = math.min(west, previous);
      east = math.max(east, previous);
    }
    final bounds = LatLngBounds.worldSafe(
      north: lats.reduce(math.max),
      south: lats.reduce(math.min),
      longitudeCenter: ((west + east) / 2 + 180) % 360 - 180,
      longitudeWidth: east - west,
    );
    try {
      _map.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: EdgeInsets.fromLTRB(
            48,
            100,
            48,
            (_panelViewportKey.currentContext?.size?.height ?? 200) + 20,
          ),
        ),
      );
    } catch (_) {}
  }

  Future<void> _start() async {
    if (_editingLocked) return;
    if (_points.length < 2) {
      _toast('至少在地图上点两个点，才能形成路线');
      return;
    }
    setState(() {
      _starting = true;
      _editingIndex = null;
    });
    final flat = <double>[];
    for (final point in _points) {
      final wgs = widget.config.writeGcj ? point : Coord.gcjToWgs(point);
      flat
        ..add(wgs.latitude)
        ..add(wgs.longitude);
    }
    try {
      await _channel.invokeMethod('startRoute', <String, Object?>{
        'points': flat,
        'speed': _effectiveSpeed,
        'mode': _playMode.name,
        'intervalMs': widget.config.intervalMs,
        'accuracy': widget.config.accuracyMeters,
        'stepLength': _stepLength,
      });
      if (!mounted) return;
      setState(() {
        _statusRevision++;
        _serviceActive = true;
        _holdingEndpoint = false;
        _running = true;
        _paused = false;
        _progress = 0;
      });
      _startPolling();
      // 原生任务已启动，缓存失败不能撤回运行态或隐藏恢复真实定位的入口。
      try {
        await widget.storage.writeConfig(
          widget.config
            ..motion = _motion
            ..stepFreq = _stepFreq
            ..stepLength = _stepLength
            ..lastRoute = _buildPlan(),
        );
      } catch (error) {
        _toast('路线已启动，但草稿保存失败：${userMessage(error, fallback: '请稍后重试保存')}');
      }
    } on PlatformException catch (e) {
      if (e.code == 'NOT_MOCK_APP') {
        _toast('请先在开发者选项里把“虚拟定位”设为模拟位置信息应用');
      } else {
        _toast(userMessage(e, fallback: '路线启动失败，请检查定位设置和路线参数后重试'));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _togglePause() async {
    try {
      await _channel.invokeMethod(_paused ? 'resumeMock' : 'pauseMock');
      if (!mounted) return;
      setState(() => _paused = !_paused);
    } on PlatformException catch (e) {
      _toast(userMessage(e, fallback: '路线控制失败，请稍后重试'));
    }
  }

  Future<void> _stop() async {
    try {
      await _channel.invokeMethod('stop');
    } on PlatformException catch (e) {
      _toast(userMessage(e, fallback: '停止失败，请重试'));
      return;
    }
    _poll?.cancel();
    if (!mounted) return;
    setState(() {
      _statusRevision++;
      _serviceActive = false;
      _holdingEndpoint = false;
      _running = false;
      _paused = false;
      _progress = 0;
      _travelled = 0;
      _total = 0;
      _current = null;
    });
    _toast('已停止，恢复真实定位');
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 700), (_) async {
      if (!mounted) return;
      try {
        final revision = _statusRevision;
        final status = await _channel.invokeMapMethod<String, dynamic>(
          'mockStatus',
        );
        // 停止或启动成功前发出的旧状态不能覆盖新状态。
        if (!mounted || status == null || revision != _statusRevision) return;
        _applyStatus(status);
        if (!_serviceActive) _poll?.cancel();
      } catch (_) {}
    });
  }

  /// 路线完成只结束移动，服务仍在终点持续推送；与普通定点模拟一样允许编辑草稿。
  void _applyStatus(Map<String, dynamic> status) {
    final serviceActive =
        (status['serviceActive'] ?? status['running']) == true;
    final active = status['routeActive'] == true;
    final total = (status['routeTotal'] as num?)?.toDouble() ?? 0;
    final progress = (status['routeProgress'] as num?)?.toDouble() ?? 0;
    final lat = (status['lat'] as num?)?.toDouble();
    final lng = (status['lng'] as num?)?.toDouble();
    setState(() {
      _serviceActive = serviceActive;
      _running = serviceActive && active;
      // 普通定点模拟的路线长度为零，不能误标成单程完成。
      _holdingEndpoint =
          serviceActive && !active && total > 0 && progress >= 1 - 1e-9;
      _progress = progress;
      _total = total;
      _travelled = (status['routeTravelled'] as num?)?.toDouble() ?? 0;
      _paused = _running && status['routePaused'] == true;
      if (!serviceActive) {
        _current = null;
      } else if (lat != null && lng != null) {
        _current = widget.config.writeGcj
            ? LatLng(lat, lng)
            : Coord.wgsToGcj(LatLng(lat, lng));
      }
    });
  }

  RoutePlan _buildPlan() => RoutePlan(
    points: List<LatLng>.from(_points),
    motion: _motion,
    playMode: _playMode,
    speed: _speed,
    stepFreq: _stepFreq,
    stepLength: _stepLength,
    name: '路线 ${_points.length} 点',
  );

  Future<void> _saveRoute() async {
    if (_editingLocked) return;
    if (_points.length < 2) {
      _toast('先画出路线再保存');
      return;
    }
    final controller = TextEditingController(text: '路线 ${_points.length} 点');
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('保存路线'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(
            labelText: '路线名称',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(c, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    if (!mounted || _editingLocked) return;
    if (widget.storage.readRoutes().any((route) => route.name == name)) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('替换同名路线'),
          content: Text('已经保存过「$name」。是否用当前草稿替换？取消会保留原路线。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('替换'),
            ),
          ],
        ),
      );
      if (!mounted || replace != true || _editingLocked) return;
    }
    final plan = _buildPlan()..name = name;
    final routes = widget.storage.readRoutes()
      ..removeWhere((e) => e.name == name)
      ..insert(0, plan);
    try {
      await widget.storage.writeRoutes(routes);
      if (mounted) _toast('已保存「$name」');
    } catch (error) {
      _toast(userMessage(error, fallback: '路线保存失败，请重试；原已存路线保持不变'));
    }
  }

  Future<void> _openSaved() async {
    if (_editingLocked) return;
    final routes = widget.storage.readRoutes();
    if (routes.isEmpty) {
      _toast('还没有保存过的路线');
      return;
    }
    final picked = await showModalBottomSheet<RoutePlan>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SavedRoutesSheet(storage: widget.storage),
    );
    if (picked == null || !mounted) return;
    _changePoints(() {
      _points
        ..clear()
        ..addAll(picked.points);
      _motion = picked.motion;
      _playMode = picked.playMode;
      _speed = picked.speed;
      _stepFreq = picked.stepFreq;
      _stepLength = picked.stepLength;
    });
    _fitRoute();
  }

  void _toast(String message) {
    if (!mounted) return;
    final media = MediaQuery.of(context);
    final text = TextPainter(
      text: TextSpan(
        text: message,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      textDirection: Directionality.of(context),
      textScaler: media.textScaler,
    )..layout(maxWidth: math.max(1, media.size.width - 64));
    // 大字号或矮窗口预留提示本身的高度，避免浮动提示被挤到屏幕外。
    final maxBottom = math.max(
      12.0,
      media.size.height - media.padding.vertical - text.height - 60,
    );
    text.dispose();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          // 提示停在概览上方，不遮挡开始、停止或参数入口。
          margin: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            math.min(
              (_panelViewportKey.currentContext?.size?.height ?? 200) + 12,
              maxBottom,
            ),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Stack(
        children: [
          _buildMap(theme),
          _buildTopBar(theme),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ConstrainedBox(
              key: _panelViewportKey,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.58,
              ),
              child: SingleChildScrollView(child: _buildPanel(theme)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMap(ThemeData theme) {
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _points.isEmpty ? widget.initial : _points.first,
        initialZoom: 15,
        minZoom: 3,
        // 允许放大已有底图细调密集采样点，不额外请求超过瓦片原生层级的数据。
        maxZoom: 22,
        onTap: (_, point) => _tapMap(point),
      ),
      children: [
        _tileLayer(),
        if (_points.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: _points,
                strokeWidth: 5,
                color: theme.colorScheme.primary.withValues(alpha: 0.75),
              ),
              if (_playMode == PlayMode.loop && _points.last != _points.first)
                Polyline(
                  points: [_points.last, _points.first],
                  strokeWidth: 4,
                  color: theme.colorScheme.primary.withValues(alpha: 0.3),
                ),
            ],
          ),
        MarkerLayer(
          markers: [
            for (var i = 0; i < _points.length; i++)
              Marker(
                point: _points[i],
                width: 44,
                height: 44,
                child: Semantics(
                  button: true,
                  label: '编辑路线第 ${i + 1} 个点',
                  child: GestureDetector(
                    key: ValueKey('route-point-$i'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _editingLocked ? null : () => _selectPoint(i),
                    // 拖动预览会重建标记，手势回调须在拖动期间保留，直到结束或取消。
                    onLongPressStart: _simulationLocked
                        ? null
                        : (_) => _beginPointDrag(i),
                    onLongPressMoveUpdate: _simulationLocked
                        ? null
                        : (details) =>
                              _updatePointDrag(i, details.offsetFromOrigin),
                    onLongPressEnd: _simulationLocked
                        ? null
                        : (_) => _finishPointDrag(i),
                    onLongPressCancel: () =>
                        _finishPointDrag(i, canceled: true),
                    child: Center(child: _pointBadge(theme, i)),
                  ),
                ),
              ),
            if (_current != null)
              Marker(
                point: _current!,
                width: 30,
                height: 30,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF17B978),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 8,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.navigation,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _tileLayer() {
    const subdomains = ['1', '2', '3', '4'];
    const ua = 'com.rz.fake_location';
    final style = widget.config.mapStyle;
    if (style == MapStyle.satellite) {
      return TileLayer(
        urlTemplate: 'https://webst0{s}.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}',
        subdomains: subdomains,
        maxNativeZoom: 18,
        userAgentPackageName: ua,
      );
    }
    final query = style == MapStyle.road
        ? 'lang=zh_cn&size=1&scl=1&style=8'
        : 'lang=zh_cn&size=1&scale=1&style=7';
    return TileLayer(
      urlTemplate:
          'https://wprd0{s}.is.autonavi.com/appmaptile?$query&x={x}&y={y}&z={z}',
      subdomains: subdomains,
      maxNativeZoom: 18,
      userAgentPackageName: ua,
    );
  }

  Widget _pointBadge(ThemeData theme, int index) {
    final isFirst = index == 0;
    final isLast = index == _points.length - 1;
    final selected = _editingIndex == index;
    // 密集采样只缩小可见圆点，外层仍保留完整点击和长按拖动区域。
    final compact = _points.length > 16 && !isFirst && !isLast && !selected;
    final color = isFirst
        ? const Color(0xFF17B978)
        : isLast
        ? const Color(0xFFD93025)
        : theme.colorScheme.primary;
    return Container(
      key: ValueKey('route-point-badge-$index'),
      width: selected ? 34 : (compact ? 8 : 28),
      height: selected ? 34 : (compact ? 8 : 28),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? theme.colorScheme.onSurface : Colors.white,
          width: compact ? 1 : 2,
        ),
      ),
      alignment: Alignment.center,
      child: compact
          ? null
          : Text(
              isFirst ? '起' : (isLast ? '终' : '$index'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }

  Widget _buildTopBar(ThemeData theme) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: Material(
          elevation: 1,
          color: theme.colorScheme.surface,
          shadowColor: Colors.black.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '路线模拟',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '撤销上一步',
                  onPressed: _editingLocked || _undo.isEmpty ? null : _undoEdit,
                  icon: const Icon(Icons.undo_rounded),
                ),
                IconButton(
                  key: const ValueKey('route-tools-button'),
                  tooltip: '路线工具',
                  onPressed: _dragSnapshot != null ? null : _openRouteTools,
                  icon: const Icon(Icons.more_horiz),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _statusLabel {
    if (_checkingStatus) return '确认中';
    if (_starting) return '启动中';
    if (_running) return _paused ? '已暂停' : '移动中';
    if (_holdingEndpoint) return '终点保持中';
    if (_serviceActive) return '定点模拟中';
    return _points.length < 2 ? '待描点' : '待开始';
  }

  Widget _buildPanel(ThemeData theme) {
    final scheme = theme.colorScheme;
    final active = _running || _holdingEndpoint || _serviceActive;
    return Material(
      key: const ValueKey('route-summary-panel'),
      elevation: 2,
      color: scheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      formatDistance(_distance),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: active
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _statusLabel,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: active
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                _running
                    ? '已走 ${formatDistance(_travelled)} / ${formatDistance(_total)}'
                    : '预计 $_durationLabel · ${_points.length} 个点',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (_running) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _progress.clamp(0, 1),
                    minHeight: 3,
                  ),
                ),
              ],
              if (_holdingEndpoint) ...[
                const SizedBox(height: 3),
                Text(
                  '停止恢复真实定位',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _editingLocked ? null : _openRouteSettings,
                      borderRadius: BorderRadius.circular(10),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 2,
                            children: [
                              Text(
                                '${_motion.label} · ${_playMode.label}',
                                style: theme.textTheme.bodyMedium,
                              ),
                              Text(
                                '${(_effectiveSpeed * 3.6).toStringAsFixed(1)} 公里/小时',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('route-settings-button'),
                    onPressed: _editingLocked ? null : _openRouteSettings,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('调整'),
                        SizedBox(width: 2),
                        Icon(Icons.chevron_right, size: 18),
                      ],
                    ),
                  ),
                ],
              ),
              _buildEditingControls(theme),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      onPressed: _starting || _checkingStatus
                          ? null
                          : _running
                          ? _togglePause
                          : _points.length < 2
                          ? null
                          : _start,
                      icon: Icon(
                        _running
                            ? (_paused
                                  ? Icons.play_arrow_rounded
                                  : Icons.pause_rounded)
                            : Icons.play_arrow_rounded,
                        size: 20,
                      ),
                      label: Text(
                        _starting
                            ? '启动中…'
                            : _running
                            ? (_paused ? '继续' : '暂停')
                            : _holdingEndpoint
                            ? '重新模拟'
                            : '开始模拟',
                      ),
                    ),
                  ),
                  if (_serviceActive) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Tooltip(
                        message: '停止恢复真实定位',
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                          ),
                          onPressed: _stop,
                          icon: const Icon(Icons.stop_rounded, size: 20),
                          label: const Text('停止'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 正常草稿不常驻教学文字；仅在缺点、选点或拖动时解释当前动作。
  Widget _buildEditingControls(ThemeData theme) {
    if (_dragSnapshot != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text('松开完成移动', style: theme.textTheme.bodySmall),
      );
    }
    if (_editingLocked) return const SizedBox.shrink();
    final index = _editingIndex;
    if (index != null) {
      final label = index == 0
          ? '起点'
          : index == _points.length - 1
          ? '终点'
          : '第 ${index + 1} 个点';
      return Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Text('点击地图重选$label', style: theme.textTheme.bodySmall),
          Wrap(
            children: [
              TextButton(
                onPressed: () => _changePoints(() => _points.removeAt(index)),
                child: const Text('删除此点'),
              ),
              TextButton(
                onPressed: () => setState(() => _editingIndex = null),
                child: const Text('取消'),
              ),
            ],
          ),
        ],
      );
    }
    if (_points.length < 2) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          _points.isEmpty ? '点击地图设置起点' : '点击地图添加终点',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// 环线参数只在确认后返回，半径非法或取消时不触碰用户已有草稿。
class _CircleRouteDialog extends StatefulWidget {
  const _CircleRouteDialog({required this.center, required this.centerName});

  final LatLng center;
  final String centerName;

  @override
  State<_CircleRouteDialog> createState() => _CircleRouteDialogState();
}

class _CircleRouteDialogState extends State<_CircleRouteDialog> {
  final _radius = TextEditingController(text: '250');
  bool _clockwise = true;
  String? _error;

  @override
  void dispose() {
    _radius.dispose();
    super.dispose();
  }

  /// 只接受有限半径，错误留在输入位置说明，不清空或改动当前路线。
  void _generate() {
    final radius = double.tryParse(_radius.text.trim());
    if (radius == null ||
        !radius.isFinite ||
        radius < RouteTools.minRadiusMeters ||
        radius > RouteTools.maxRadiusMeters) {
      setState(() => _error = '请输入 10 至 10000 米之间的半径');
      return;
    }
    Navigator.pop(context, (radius: radius, clockwise: _clockwise));
  }

  @override
  Widget build(BuildContext context) {
    final radius = double.tryParse(_radius.text.trim());
    final valid =
        radius != null &&
        radius.isFinite &&
        radius >= RouteTools.minRadiusMeters &&
        radius <= RouteTools.maxRadiusMeters;
    return AlertDialog(
      scrollable: true,
      title: const Text('按半径生成环线'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('圆心：${widget.centerName}'),
          Text(formatLatLng(widget.center)),
          const SizedBox(height: 8),
          const Text('以选中点或当前起点为圆心，起点设在圆心正北。新环线替换草稿后可撤销，沿用当前运动方式和播放方式。'),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('circle-radius-input'),
            controller: _radius,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: '环线半径',
              suffixText: '米',
              helperText: '可输入 10 至 10000 米',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _generate(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('顺时针'),
                selected: _clockwise,
                showCheckmark: false,
                onSelected: (_) => setState(() => _clockwise = true),
              ),
              ChoiceChip(
                label: const Text('逆时针'),
                selected: !_clockwise,
                showCheckmark: false,
                onSelected: (_) => setState(() => _clockwise = false),
              ),
            ],
          ),
          if (valid) ...[
            const SizedBox(height: 8),
            Text('预计一圈约 ${formatDistance(2 * math.pi * radius)}'),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _generate, child: const Text('生成环线')),
      ],
    );
  }
}
