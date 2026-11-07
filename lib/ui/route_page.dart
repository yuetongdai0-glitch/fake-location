import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/coord.dart';
import '../core/models.dart';
import '../core/storage.dart';

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

class _RoutePageState extends State<RoutePage> {
  static const _channel = MethodChannel('fake_location/mock');

  final MapController _map = MapController();
  final List<LatLng> _points = [];

  MotionMode _motion = MotionMode.walk;
  PlayMode _playMode = PlayMode.loop;
  double _speed = 1.4;
  double _stepFreq = 110;
  double _stepLength = 0.65;

  bool _running = false;
  bool _paused = false;
  bool _finished = false;
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
      // 默认从当前位置延伸一段，省得用户先点两个点
      _points.add(widget.initial);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitRoute());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  double get _effectiveSpeed =>
      _motion.usesSteps ? _stepFreq / 60 * _stepLength : _speed;

  double get _distance {
    var sum = 0.0;
    for (var i = 1; i < _points.length; i++) {
      sum += Coord.distanceMeters(_points[i - 1], _points[i]);
    }
    return sum;
  }

  String get _durationLabel {
    final v = _effectiveSpeed;
    if (v <= 0 || _distance <= 0) return '—';
    final seconds = (_distance / v).round();
    if (seconds < 60) return '$seconds 秒';
    if (seconds < 3600) return '${(seconds / 60).toStringAsFixed(1)} 分钟';
    return '${(seconds / 3600).toStringAsFixed(1)} 小时';
  }

  void _fitRoute() {
    if (!mounted) return;
    if (_points.length < 2) {
      try {
        _map.move(_points.first, 16);
      } catch (_) {}
      return;
    }
    final lats = _points.map((e) => e.latitude);
    final lngs = _points.map((e) => e.longitude);
    final bounds = LatLngBounds(
      LatLng(lats.reduce(math.min), lngs.reduce(math.min)),
      LatLng(lats.reduce(math.max), lngs.reduce(math.max)),
    );
    try {
      _map.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(56)),
      );
    } catch (_) {}
  }

  Future<void> _start() async {
    if (_points.length < 2) {
      _toast('至少在地图上点两个点，才能形成路线');
      return;
    }
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
      widget.storage.writeConfig(
        widget.config
          ..motion = _motion
          ..stepFreq = _stepFreq
          ..stepLength = _stepLength
          ..lastRoute = _buildPlan(),
      );
      if (!mounted) return;
      setState(() {
        _running = true;
        _paused = false;
        _finished = false;
        _progress = 0;
      });
      _startPolling();
    } on PlatformException catch (e) {
      if (e.code == 'NOT_MOCK_APP') {
        _toast('请先在开发者选项里把“虚拟定位”设为模拟位置信息应用');
      } else {
        _toast(e.message ?? '启动失败');
      }
    }
  }

  Future<void> _togglePause() async {
    try {
      await _channel.invokeMethod(_paused ? 'resumeMock' : 'pauseMock');
      if (!mounted) return;
      setState(() => _paused = !_paused);
    } on PlatformException catch (e) {
      _toast(e.message ?? '操作失败');
    }
  }

  Future<void> _stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
    _poll?.cancel();
    if (!mounted) return;
    setState(() {
      _running = false;
      _paused = false;
    });
    _toast('已停止，恢复真实定位');
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 700), (_) async {
      if (!mounted) return;
      try {
        final status = await _channel.invokeMapMethod<String, dynamic>(
          'mockStatus',
        );
        if (!mounted || status == null) return;
        final lat = (status['lat'] as num?)?.toDouble();
        final lng = (status['lng'] as num?)?.toDouble();
        final active = status['routeActive'] == true;
        final running = status['running'] == true;
        setState(() {
          _progress = (status['routeProgress'] as num?)?.toDouble() ?? 0;
          _travelled = (status['routeTravelled'] as num?)?.toDouble() ?? 0;
          _total = (status['routeTotal'] as num?)?.toDouble() ?? 0;
          _paused = status['routePaused'] == true;
          if (lat != null && lng != null) {
            _current = widget.config.writeGcj
                ? LatLng(lat, lng)
                : Coord.wgsToGcj(LatLng(lat, lng));
          }
          if (!running) {
            _running = false;
          } else if (!active && _running) {
            // 单程路线走完，服务还在推最后一点
            _finished = true;
            _running = false;
            _poll?.cancel();
          }
        });
      } catch (_) {}
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
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final plan = _buildPlan()..name = name;
    final routes = widget.storage.readRoutes()
      ..removeWhere((e) => e.name == name)
      ..insert(0, plan);
    await widget.storage.writeRoutes(routes);
    if (mounted) _toast('已保存「$name」');
  }

  Future<void> _openSaved() async {
    final routes = widget.storage.readRoutes();
    if (routes.isEmpty) {
      _toast('还没有保存过的路线');
      return;
    }
    final picked = await showModalBottomSheet<RoutePlan>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('已保存的路线'),
            ),
            for (final route in routes)
              ListTile(
                leading: const Icon(Icons.route_outlined),
                title: Text(route.name),
                subtitle: Text(
                  '${route.points.length} 个点 · ${formatDistance(route.distanceMeters)}'
                  ' · ${route.motion.label}',
                ),
                onTap: () => Navigator.pop(c, route),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final rest = widget.storage.readRoutes()
                      ..removeWhere((e) => e.name == route.name);
                    await widget.storage.writeRoutes(rest);
                    if (c.mounted) Navigator.pop(c);
                  },
                ),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), margin: const EdgeInsets.all(16)),
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
            child: _buildPanel(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildMap(ThemeData theme) {
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _points.first,
        initialZoom: 15,
        minZoom: 3,
        maxZoom: 19,
        onTap: (_, point) {
          setState(() => _points.add(point));
        },
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
            ],
          ),
        MarkerLayer(
          markers: [
            for (var i = 0; i < _points.length; i++)
              Marker(
                point: _points[i],
                width: 26,
                height: 26,
                child: _pointBadge(theme, i),
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
        urlTemplate:
            'https://webst0{s}.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}',
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
    final color = isFirst
        ? const Color(0xFF17B978)
        : isLast
        ? const Color(0xFFD93025)
        : theme.colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      alignment: Alignment.center,
      child: Text(
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
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Row(
          children: [
            Material(
              elevation: 3,
              shape: const CircleBorder(),
              color: scheme.surface,
              child: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Material(
                elevation: 3,
                borderRadius: BorderRadius.circular(14),
                color: scheme.surface,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.route, size: 18, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _points.length < 2
                              ? '点击地图添加途经点（至少 2 个）'
                              : '${_points.length} 个点 · ${formatDistance(_distance)} · 约 $_durationLabel',
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Material(
              elevation: 3,
              shape: const CircleBorder(),
              color: scheme.surface,
              child: IconButton(
                tooltip: '撤销上一个点',
                icon: const Icon(Icons.undo, size: 20),
                onPressed: _points.length <= 1
                    ? null
                    : () => setState(() => _points.removeLast()),
              ),
            ),
            const SizedBox(width: 6),
            Material(
              elevation: 3,
              shape: const CircleBorder(),
              color: scheme.surface,
              child: IconButton(
                tooltip: '清空',
                icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                onPressed: () => setState(() {
                  _points.clear();
                  _points.add(widget.initial);
                }),
              ),
            ),
            const SizedBox(width: 6),
            Material(
              elevation: 3,
              shape: const CircleBorder(),
              color: scheme.surface,
              child: IconButton(
                tooltip: '视角回到路线',
                icon: const Icon(Icons.center_focus_strong_outlined, size: 20),
                onPressed: _fitRoute,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Material(
      elevation: 12,
      color: scheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('运动方式', style: theme.textTheme.labelMedium),
                  const SizedBox(width: 6),
                  Text(
                    'km/h',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (_running)
                    Text(
                      _paused ? '已暂停' : '移动中',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: _paused
                            ? const Color(0xFFE8710A)
                            : const Color(0xFF17B978),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: MotionMode.values.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (_, i) {
                    final mode = MotionMode.values[i];
                    final selected = mode == _motion;
                    return ChoiceChip(
                      label: Text(
                        '${mode.label} ${(mode == MotionMode.custom ? _speed : mode.defaultSpeed * 3.6).toStringAsFixed(0)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: selected ? scheme.onPrimary : null,
                        ),
                      ),
                      visualDensity: VisualDensity.compact,
                      selected: selected,
                      showCheckmark: false,
                      onSelected: (_) => setState(() {
                        _motion = mode;
                        if (mode != MotionMode.custom) _speed = mode.defaultSpeed;
                      }),
                    );
                  },
                ),
              ),
              const SizedBox(height: 6),
              if (_motion.usesSteps)
                Row(
                  children: [
                    Expanded(
                      child: _stepper(
                        theme,
                        label: '步频',
                        value: '${_stepFreq.round()} 步/分',
                        onMinus: () => setState(
                          () => _stepFreq = (_stepFreq - 5).clamp(40, 220),
                        ),
                        onPlus: () => setState(
                          () => _stepFreq = (_stepFreq + 5).clamp(40, 220),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _stepper(
                        theme,
                        label: '步幅',
                        value: '${_stepLength.toStringAsFixed(2)} 米',
                        onMinus: () => setState(
                          () => _stepLength =
                              double.parse((_stepLength - 0.05).clamp(0.3, 1.2).toStringAsFixed(2)),
                        ),
                        onPlus: () => setState(
                          () => _stepLength =
                              double.parse((_stepLength + 0.05).clamp(0.3, 1.2).toStringAsFixed(2)),
                        ),
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    Text(
                      '速度',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: _speed.clamp(0.5, 60),
                        min: 0.5,
                        max: 60,
                        divisions: 119,
                        label: '${(_speed * 3.6).toStringAsFixed(1)} km/h',
                        onChanged: (v) => setState(() {
                          _motion = MotionMode.custom;
                          _speed = v;
                        }),
                      ),
                    ),
                    Text(
                      '${(_speed * 3.6).toStringAsFixed(1)} km/h',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              Row(
                children: [
                  Text(
                    '播放方式',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  for (final mode in PlayMode.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(
                          mode.label,
                          style: const TextStyle(fontSize: 11),
                        ),
                        visualDensity: VisualDensity.compact,
                        selected: mode == _playMode,
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _playMode = mode),
                      ),
                    ),
                  const Spacer(),
                  Text(
                    '${(_effectiveSpeed * 3.6).toStringAsFixed(1)} km/h',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              if (_running) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: _progress.clamp(0, 1),
                    minHeight: 6,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      '已走 ${formatDistance(_travelled)}',
                      style: theme.textTheme.labelSmall,
                    ),
                    const Spacer(),
                    Text(
                      _total <= 0
                          ? '—'
                          : '全程 ${formatDistance(_total)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
              if (_finished) ...[
                const SizedBox(height: 6),
                Text(
                  '单程路线已走完，位置停在终点',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: const Color(0xFF17B978),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _running ? _togglePause : _start,
                      icon: Icon(
                        _running
                            ? (_paused
                                  ? Icons.play_arrow_rounded
                                  : Icons.pause_rounded)
                            : Icons.play_circle_outline,
                        size: 20,
                      ),
                      label: Text(
                        _running ? (_paused ? '继续' : '暂停') : '开始模拟',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_running)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _stop,
                        icon: const Icon(Icons.stop_circle_outlined, size: 20),
                        label: const Text('停止'),
                      ),
                    )
                  else ...[
                    Tooltip(
                      message: '保存这条路线',
                      child: OutlinedButton(
                        onPressed: _saveRoute,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        child: const Icon(
                          Icons.bookmark_add_outlined,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: '打开已保存的路线',
                      child: OutlinedButton(
                        onPressed: _openSaved,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        child: const Icon(Icons.folder_open_outlined, size: 20),
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

  Widget _stepper(
    ThemeData theme, {
    required String label,
    required String value,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
  }) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: onMinus,
            icon: const Icon(Icons.remove),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  value,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: onPlus,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
