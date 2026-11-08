import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/app_update.dart';
import '../core/coord.dart';
import '../core/models.dart';
import '../core/search_api.dart';
import '../core/storage.dart';
import 'coordinate_sheet.dart';
import 'route_page.dart';
import 'sheets.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const _mockChannel = MethodChannel('fake_location/mock');
  static const _updateChannel = MethodChannel('fake_location/update');
  static const _defaultTarget = LatLng(39.908722, 116.397499); // 天安门（GCJ-02）

  final MapController _map = MapController();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  AppStorage? _storage;
  AppConfig _config = AppConfig();

  LatLng _target = _defaultTarget;
  String? _targetName;
  String? _targetAddress;
  PlaceSource? _targetSource;

  LatLng? _real;
  double? _realAccuracy;
  String? _realProvider;
  bool _realIsMock = false;

  bool _running = false;
  bool _searching = false;
  bool _locating = false;
  bool _resolving = false;
  bool _mapReady = false;

  List<Place> _results = const [];
  List<String> _suggestions = const [];
  String? _searchHint;

  List<SavedPlace> _favorites = const [];
  List<SavedPlace> _recents = const [];

  int _installedVersionCode = 0;
  String _installedVersionName = '';
  AppUpdate? _availableUpdate;
  bool _checkingUpdate = false;
  bool _updateBusy = false;
  bool _updateChecked = false;

  Timer? _persistTimer;
  Timer? _resolveTimer;
  Timer? _suggestTimer;
  Timer? _healthTimer;
  int _suggestSeq = 0;

  /// 虚拟摇杆：开启后按住就能像走路一样实时移动目标点。
  bool _joystickOn = false;
  Offset _stick = Offset.zero;
  Timer? _stickTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _persistTimer?.cancel();
    _resolveTimer?.cancel();
    _suggestTimer?.cancel();
    _healthTimer?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshRunning();
  }

  // ---------------------------------------------------------------- 初始化

  Future<void> _bootstrap() async {
    final storage = await AppStorage.load();
    if (!mounted) return;
    final config = storage.readConfig();
    setState(() {
      _storage = storage;
      _config = config;
      _favorites = storage.readFavorites();
      _recents = storage.readRecents();
      if (config.lastTarget != null) _target = config.lastTarget!;
      _targetName = config.lastName;
      _targetAddress = config.lastAddress;
    });

    await _refreshRunning();
    try {
      await _mockChannel.invokeMethod('requestPermissions');
    } catch (_) {}
    await _locate(
      silent: true,
      moveMap: _config.lastTarget == null,
      adopt: _config.lastTarget == null,
    );
    await _loadVersionAndCheckUpdate();
  }

  Future<void> _refreshRunning() async {
    try {
      final running = await _mockChannel.invokeMethod<bool>('isRunning');
      if (mounted && running != null) setState(() => _running = running);
    } catch (_) {}
  }

  Future<void> _loadVersionAndCheckUpdate() async {
    try {
      final version = await _updateChannel
          .invokeMapMethod<String, dynamic>('version');
      if (version != null && mounted) {
        setState(() {
          _installedVersionCode = version['versionCode'] as int? ?? 0;
          _installedVersionName = version['versionName'] as String? ?? '';
        });
      }
    } catch (_) {
      // 版本读取失败时仍保留手动检查入口。
    }
    try {
      await _checkUpdate(manual: false);
    } catch (_) {
      // 自动检查失败不打扰用户，手动检查会就地显示原因。
    }
  }

  Future<AppUpdate?> _checkUpdate({required bool manual}) async {
    if (_checkingUpdate || _updateBusy) return null;
    setState(() => _checkingUpdate = true);
    try {
      final latest = await fetchLatestUpdate();
      final available =
          _installedVersionCode > 0 && latest.isNewerThan(_installedVersionCode)
          ? latest
          : null;
      if (!mounted) return available;
      final fresh = available != null && _availableUpdate == null;
      setState(() {
        _availableUpdate = available;
        _updateChecked = true;
      });
      // 手动检查由设置面板自己就地展示结果，这里只在自动检查时提示
      if (!manual && fresh) {
        _toastWithAction(
          '发现新版本 ${latest.versionName}',
          '更新',
          () => _installUpdate(latest),
        );
      }
      return available;
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _installUpdate(AppUpdate update) async {
    if (_updateBusy) return;
    setState(() {
      _updateBusy = true;
      _checkingUpdate = false;
    });
    try {
      await _updateChannel.invokeMethod<bool>('downloadAndInstall', {
        'packageId': update.appId,
        'versionName': update.versionName,
        'versionCode': update.versionCode,
        'apkUrl': update.apkUrl.toString(),
        'sha256': update.sha256,
        'minSdk': update.minSdk,
      });
      if (mounted) _toast('安装包已下载，请在系统安装器中完成更新');
    } on PlatformException catch (e) {
      if (mounted) _toast(e.message ?? '更新失败');
    } finally {
      if (mounted) setState(() => _updateBusy = false);
    }
  }

  // ---------------------------------------------------------------- 定位

  Future<void> _locate({
    bool silent = false,
    bool moveMap = false,
    bool adopt = false,
    bool fresh = false,
  }) async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      final raw = await _mockChannel.invokeMapMethod<String, dynamic>(
        'getLocation',
        {'fresh': fresh},
      );
      if (raw == null) {
        if (!silent) _showLocationHelp();
        return;
      }
      final lat = (raw['lat'] as num?)?.toDouble();
      final lng = (raw['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) {
        if (!silent) _showLocationHelp();
        return;
      }
      final gcj = Coord.wgsToGcj(LatLng(lat, lng));
      setState(() {
        _real = gcj;
        _realAccuracy = (raw['accuracy'] as num?)?.toDouble();
        _realProvider = raw['provider'] as String?;
        _realIsMock = raw['mock'] == true;
      });
      if (adopt) {
        _setTarget(
          gcj,
          name: '当前位置',
          move: moveMap,
          resolve: true,
          keepSearchText: true,
        );
      } else if (moveMap) {
        _moveTo(gcj, 17);
      }
      if (!silent) {
        final accuracy = _realAccuracy;
        _toast(
          _realIsMock
              ? '当前显示的是模拟位置'
              : accuracy == null || accuracy > 60
              ? '已定位（精度较低${accuracy == null ? '' : ' ±${accuracy.round()} 米'}），可到空旷处重试'
              : '已定位，精度 ±${accuracy.round()} 米',
        );
      }
    } catch (e) {
      if (!silent) {
        final message = e is PlatformException
            ? (e.message ?? e.code)
            : e.toString();
        _toast('获取位置失败：$message');
        _showLocationHelp();
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  // ---------------------------------------------------------------- 选点

  LatLng _mapCenter() {
    try {
      return _map.camera.center;
    } catch (_) {
      return _target;
    }
  }

  void _moveTo(LatLng point, double zoom) {
    if (!_mapReady) return;
    try {
      _map.move(point, zoom);
    } catch (_) {}
  }

  void _setTarget(
    LatLng gcj, {
    String? name,
    String? address,
    PlaceSource? source,
    bool move = false,
    bool resolve = false,
    bool keepSearchText = false,
  }) {
    setState(() {
      _target = gcj;
      _targetName = name;
      _targetAddress = address;
      _targetSource = source;
      _results = const [];
      _suggestions = const [];
      _searchHint = null;
      if (!keepSearchText) _searchCtrl.clear();
    });
    _schedulePersist();
    if (move) _moveTo(gcj, max(_mapReady ? _map.camera.zoom : 16, 17));
    if (resolve) _scheduleReverseGeocode(gcj);
    HapticFeedback.selectionClick();
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 600), () {
      _config.lastTarget = _target;
      _config.lastName = _targetName;
      _config.lastAddress = _targetAddress;
      _storage?.writeConfig(_config);
    });
  }

  void _scheduleReverseGeocode(LatLng point) {
    _resolveTimer?.cancel();
    _resolveTimer = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      setState(() => _resolving = true);
      final address = await SearchApi(
        amapKey: _config.amapKey,
      ).reverseGeocode(point);
      if (!mounted) return;
      setState(() {
        _resolving = false;
        if (address != null && address.isNotEmpty && _target == point) {
          _targetAddress = address;
        }
      });
    });
  }

  // ---------------------------------------------------------------- 搜索

  Future<void> _search() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) {
      _searchFocus.requestFocus();
      return;
    }
    FocusScope.of(context).unfocus();

    final coord = parseCoordinateQuery(query);
    if (coord != null) {
      _setTarget(
        coord,
        name: '坐标选点',
        source: PlaceSource.pasted,
        move: true,
        resolve: true,
      );
      return;
    }

    setState(() {
      _searching = true;
      _results = const [];
      _suggestions = const [];
      _searchHint = null;
    });
    try {
      final outcome = await SearchApi(amapKey: _config.amapKey).search(
        query,
        center: _mapCenter(),
        origin: _real ?? _mapCenter(),
      );
      if (!mounted) return;
      setState(() {
        _results = outcome.places;
        _searchHint = outcome.places.isEmpty
            ? '没有找到“$query”。${outcome.notes.isEmpty ? '' : '\n${outcome.notes.join('；')}'}'
            : null;
      });
      if (outcome.places.isEmpty && outcome.notes.isNotEmpty) {
        _toastWithAction('搜索失败：${outcome.notes.first}', '设置搜索源', _openSettings);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _searchHint = '搜索失败：${_friendly(e)}');
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// 输入时做 400ms 防抖的联想，减少“名称不完整搜不到”的情况。
  void _onQueryChanged(String value) {
    _suggestTimer?.cancel();
    final query = value.trim();
    if (query.length < 2 || parseCoordinateQuery(query) != null) {
      // 输入的是坐标时不需要联想，直接回车跳转。
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }
    _suggestTimer = Timer(const Duration(milliseconds: 400), () async {
      final seq = ++_suggestSeq;
      final list = await SearchApi(
        amapKey: _config.amapKey,
      ).suggest(query, center: _mapCenter());
      if (!mounted || seq != _suggestSeq) return;
      setState(() => _suggestions = list);
    });
  }

  void _applyResult(Place place) {
    _setTarget(
      place.gcj,
      name: place.name,
      address: place.address,
      source: place.source,
      move: true,
      keepSearchText: true,
    );
    _searchCtrl.text = place.name;
    FocusScope.of(context).unfocus();
  }

  // ---------------------------------------------------------------- 模拟

  /// 写入系统的坐标：默认 WGS-84，开启“按 GCJ 写入”时直接下发地图坐标。
  LatLng get _writePoint =>
      _config.writeGcj ? _target : Coord.gcjToWgs(_target);

  /// 读取一次「模拟是否生效」的检测数据：服务状态 + 系统读回的位置。
  Future<MockReport?> _loadMockReport() async {
    final status = await _mockChannel.invokeMapMethod<String, dynamic>(
      'mockStatus',
    );
    Map<String, dynamic>? location;
    try {
      location = await _mockChannel.invokeMapMethod<String, dynamic>(
        'getLocation',
        {'fresh': false},
      );
    } catch (_) {
      location = null;
    }
    if (status == null) return null;
    final providers =
        (status['providers'] as List?)?.map((e) => '$e').toList() ??
        const <String>[];
    final lat = (location?['lat'] as num?)?.toDouble();
    final lng = (location?['lng'] as num?)?.toDouble();
    return MockReport(
      serviceRunning: status['running'] == true,
      mockAppSelected: status['mockApp'] == true,
      pushCount: (status['pushCount'] as num?)?.toInt() ?? 0,
      elapsedMs: (status['elapsedMs'] as num?)?.toInt() ?? -1,
      providers: providers,
      systemWgs: lat == null || lng == null ? null : LatLng(lat, lng),
      systemAccuracy: (location?['accuracy'] as num?)?.toDouble(),
      systemIsMock: location?['mock'] == true,
      systemProvider: location?['provider'] as String?,
    );
  }

  Future<void> _openMockCheck() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => MockCheckSheet(
        loadReport: _loadMockReport,
        targetWgs: _writePoint,
        onRetryPush: () => _mockChannel.invokeMethod('start', {
          'lat': _writePoint.latitude,
          'lng': _writePoint.longitude,
        }),
        onOpenExternalApp: _openExternalApp,
      ),
    );
  }

  Future<void> _openExternalApp(String package) async {
    try {
      await _mockChannel.invokeMethod('openApp', {'package': package});
    } on PlatformException catch (e) {
      _toast(e.message ?? '无法打开该应用');
    }
  }

  /// 开始模拟后自动校验一次，没生效就提示用户去检测。
  Future<void> _verifyAfterStart() async {
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (!mounted) return;
    try {
      final report = await _loadMockReport();
      if (report == null || !mounted) return;
      final distance = report.distanceTo(_writePoint);
      final effective =
          report.systemIsMock && (distance == null || distance < 60);
      if (!effective) {
        _toastWithAction(
          report.mockAppSelected
              ? '模拟坐标还没生效：系统仍返回真实位置'
              : '还没把本应用设为“模拟位置信息应用”',
          '查看检测',
          _openMockCheck,
        );
      }
      setState(() => _running = report.serviceRunning);
    } catch (_) {}
  }

  /// 模拟进行中定期确认服务还活着，被系统清理时及时提示。
  void _startHealthCheck() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 6), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (!_running) return;
      try {
        final status = await _mockChannel.invokeMapMethod<String, dynamic>(
          'mockStatus',
        );
        if (!mounted || status == null) return;
        final alive = status['running'] == true && (status['pushCount'] as num? ?? 0) > 0;
        if (!alive) {
          setState(() => _running = false);
          // 可能是被系统清理，也可能是在悬浮条上点了“回真实位置”
          _toastWithAction('模拟已停止，定位已恢复', '重新开始', _start);
        }
      } catch (_) {}
    });
  }

  /// 本次会话是否已经提示过 WiFi 干扰。
  bool _wifiPrompted = false;

  /// 读 WiFi 状态。开着 WiFi 或「WiFi 扫描」时，第三方 SDK 会自己用热点指纹算位置，
  /// 刷新后就把系统里的模拟值盖掉了——表现就是「刚开始对、刷新一下又回到原地」。
  Future<Map<String, dynamic>> _wifiStatus() async {
    try {
      return await _mockChannel.invokeMapMethod<String, dynamic>('wifiStatus') ??
          const {};
    } catch (_) {
      return const {};
    }
  }

  /// 开始模拟前确认 WiFi 干扰。返回 true 表示继续开始。
  Future<bool> _confirmWifiInterference() async {
    if (_wifiPrompted) return true;
    final wifi = await _wifiStatus();
    if (wifi['interfering'] != true) return true;
    if (!mounted) return true;
    _wifiPrompted = true;

    final ssid = wifi['ssid'] as String?;
    final scanAlways = wifi['scanAlwaysAvailable'] == true;
    final reason = ssid != null
        ? '当前连接着「$ssid」'
        : scanAlways
        ? '「WiFi 扫描始终可用」是开着的'
        : 'WiFi 是开着的';

    final action = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('WiFi 会盖掉模拟位置'),
        content: Text(
          '$reason。\n\n'
          '高德、微信这类应用会用自己的 SDK 读 WiFi 热点指纹算一次位置，'
          '刷新时就盖掉系统里的模拟值——这就是「刚开始对、刷新一下又回原地」的原因。\n\n'
          '临时关掉 WiFi（或关掉「WiFi 扫描」）后，它们只能读系统位置，模拟就稳了。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'settings'),
            child: const Text('去关闭 WiFi'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'proceed'),
            child: const Text('仍然开始'),
          ),
        ],
      ),
    );

    if (action == 'settings') {
      await _mockChannel.invokeMethod('openWifiSettings');
      return false;
    }
    return action == 'proceed';
  }

  Future<void> _start() async {
    if (!await _confirmWifiInterference()) return;
    if (!mounted) return;
    final write = _writePoint;
    try {
      await _mockChannel.invokeMethod('start', {
        'lat': write.latitude,
        'lng': write.longitude,
        'intervalMs': _config.intervalMs,
        'accuracy': _config.accuracyMeters,
      });
      setState(() => _running = true);
      if (_config.floatBar) unawaited(_syncFloatBar(true));
      final place = Place(
        name: _targetName ?? _targetAddress ?? '自定义位置',
        gcj: _target,
        address: _targetAddress ?? '',
        source: _targetSource ?? PlaceSource.manual,
      );
      await _storage?.addRecent(place);
      if (mounted) setState(() => _recents = _storage?.readRecents() ?? _recents);
      unawaited(_locate(silent: true));
      unawaited(_verifyAfterStart());
      _startHealthCheck();
      _toast(
        '已开始模拟：${_config.writeGcj ? 'GCJ-02' : 'WGS-84'} '
        '${formatLatLng(write, digits: 6)}',
      );
    } on PlatformException catch (e) {
      if (e.code == 'NOT_MOCK_APP') {
        _showMockGuide();
      } else {
        _toast('启动失败：${e.message}');
      }
    }
  }

  Future<void> _stop() async {
    try {
      await _mockChannel.invokeMethod('stop');
      setState(() => _running = false);
      _healthTimer?.cancel();
      unawaited(_syncFloatBar(false));
      unawaited(_locate(silent: true, fresh: true));
      _toast('已停止，恢复真实定位');
    } on PlatformException catch (e) {
      _toast('停止失败：${e.message}');
    }
  }

  // ---------------------------------------------------------------- 路线 / 摇杆

  Future<void> _openRoute() async {
    final storage = _storage;
    if (storage == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            RoutePage(initial: _target, config: _config, storage: storage),
      ),
    );
    if (!mounted) return;
    // 路线页里可能已经启动了服务，回来同步一次状态
    try {
      final running =
          await _mockChannel.invokeMethod<bool>('isRunning') ?? false;
      if (mounted) setState(() => _running = running);
      unawaited(_locate(silent: true));
    } catch (_) {}
  }

  void _toggleJoystick() {
    setState(() => _joystickOn = !_joystickOn);
    if (!_joystickOn) {
      _stick = Offset.zero;
      _stickTimer?.cancel();
      _stickTimer = null;
    }
  }

  /// 把指针位置换算成 -1~1 的方向向量。
  void _updateStick(Offset local, double size) {
    final center = Offset(size / 2, size / 2);
    var vector = (local - center) / (size / 2);
    if (vector.distance > 1) vector = vector / vector.distance;
    _onStick(vector);
  }

  /// 摇杆回调：值为 -1~1 的方向向量，松手回零。
  void _onStick(Offset value) {
    setState(() => _stick = value);
    if (value == Offset.zero) {
      _stickTimer?.cancel();
      _stickTimer = null;
      return;
    }
    _stickTimer ??= Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _stickStep(),
    );
  }

  /// 每 200ms 沿摇杆方向走一步，速度由运动方式（步频步幅或档位）决定。
  Future<void> _stickStep() async {
    final stick = _stick;
    if (stick == Offset.zero) return;
    final motion = _config.motion;
    final double speed = (motion.usesSteps
            ? _config.stepFreq / 60 * _config.stepLength
            : motion.defaultSpeed)
        .clamp(0.3, 60.0)
        .toDouble();
    // 200ms 走一步，单步不超过 5 米，避免异常值把目标点甩飞
    final double meters = (speed * 0.2).clamp(0.05, 5.0).toDouble();
    final rad = atan2(stick.dx, -stick.dy);
    final lat = _target.latitude;
    final lng = _target.longitude;
    final cosLat = cos(lat * pi / 180).abs();
    final double dLat = meters * cos(rad) / 110540.0;
    final double dLng = meters * sin(rad) / (111320.0 * (cosLat < 0.01 ? 0.01 : cosLat));
    if (!dLat.isFinite || !dLng.isFinite) return;
    final next = LatLng(lat + dLat, lng + dLng);
    setState(() {
      _target = next;
      _targetName ??= '摇杆移动';
    });
    _moveTo(next, _mapReady ? _map.camera.zoom : 17);
    _schedulePersist();
    if (!_running) return;
    final write = _writePoint;
    try {
      await _mockChannel.invokeMethod('start', <String, Object?>{
        'lat': write.latitude,
        'lng': write.longitude,
        'intervalMs': _config.intervalMs,
        'accuracy': _config.accuracyMeters,
      });
    } catch (_) {}
  }

  // ---------------------------------------------------------------- 常用地点

  Future<void> _savePlace(Place place) async {
    final controller = TextEditingController(text: place.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('存为常用地点'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 30,
              decoration: const InputDecoration(
                labelText: '名称',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(c, v.trim()),
            ),
            Text(
              place.address.isEmpty ? formatLatLng(place.gcj) : place.address,
              style: Theme.of(c).textTheme.bodySmall,
            ),
          ],
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

    final list = List<SavedPlace>.of(_favorites);
    list.removeWhere(
      (e) => e.name == name && Coord.distanceMeters(e.gcj, place.gcj) < 50,
    );
    list.insert(
      0,
      SavedPlace.fromPlace(place, name: name),
    );
    await _storage?.writeFavorites(list);
    if (!mounted) return;
    setState(() => _favorites = list);
    _toast('已保存“$name”');
  }

  Future<void> _openSaved() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => SavedPlacesSheet(
        favorites: _favorites,
        recents: _recents,
        onPick: (saved) => _setTarget(
          saved.gcj,
          name: saved.name,
          address: saved.address,
          source: PlaceSource.saved,
          move: true,
          keepSearchText: true,
        ),
        onDelete: (saved) async {
          final list = _favorites.where((e) => e.id != saved.id).toList();
          await _storage?.writeFavorites(list);
          if (mounted) setState(() => _favorites = list);
        },
        onRename: (saved, name) async {
          final list = _favorites
              .map(
                (e) => e.id == saved.id
                    ? SavedPlace(
                        id: e.id,
                        name: name,
                        gcj: e.gcj,
                        address: e.address,
                        savedAt: e.savedAt,
                      )
                    : e,
              )
              .toList();
          await _storage?.writeFavorites(list);
          if (mounted) setState(() => _favorites = list);
        },
        onSaveCurrent: () => _savePlace(
          Place(
            name: _targetName ?? _targetAddress ?? '自定义位置',
            gcj: _target,
            address: _targetAddress ?? '',
            source: _targetSource ?? PlaceSource.manual,
          ),
        ),
        onClearRecents: () async {
          await _storage?.clearRecents();
          if (mounted) setState(() => _recents = const []);
        },
      ),
    );
  }

  Future<void> _openNudge() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => NudgeSheet(
        target: _target,
        onChanged: (p) {
          setState(() {
            _target = p;
            _targetName ??= '微调位置';
            _targetAddress = null;
          });
          if (_running) {
            final write = _config.writeGcj ? p : Coord.gcjToWgs(p);
            _mockChannel.invokeMethod('start', {
              'lat': write.latitude,
              'lng': write.longitude,
            });
          }
          _schedulePersist();
        },
      ),
    );
  }

  Future<void> _openCoordinate() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => CoordinateSheet(
        initial: _target,
        resolveAddress: (gcj) =>
            SearchApi(amapKey: _config.amapKey).reverseGeocode(gcj),
        onPick: (gcj) {
          _setTarget(
            gcj,
            name: '坐标选点',
            source: PlaceSource.pasted,
            move: true,
            resolve: true,
          );
          if (_running) {
            final write = _config.writeGcj ? gcj : Coord.gcjToWgs(gcj);
            _mockChannel.invokeMethod('start', {
              'lat': write.latitude,
              'lng': write.longitude,
            });
          }
        },
      ),
    );
  }

  Future<void> _openMore() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (c) => MoreSheet(
        onNudge: () {
          Navigator.pop(c);
          _openNudge();
        },
        onMockCheck: () {
          Navigator.pop(c);
          _openMockCheck();
        },
        onSettings: () {
          Navigator.pop(c);
          _openSettings();
        },
      ),
    );
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => SettingsSheet(
        config: _config,
        versionName: _installedVersionName,
        availableUpdate: _availableUpdate,
        updateChecked: _updateChecked,
        checkingUpdate: _checkingUpdate,
        updateBusy: _updateBusy,
        onConfigChanged: (config) async {
          final wantedFloat = config.floatBar;
          setState(() => _config = config);
          await _storage?.writeConfig(config);
          await _syncFloatBar(wantedFloat);
        },
        onCheckUpdate: () => _checkUpdate(manual: true),
        onInstallUpdate: _installUpdate,
        onOpenUrl: _openUrl,
        storage: _storage!,
      ),
    );
  }

  /// 显示/隐藏悬浮控制条；没有悬浮窗权限时引导去系统设置里授权。
  Future<void> _syncFloatBar(bool show) async {
    if (!show) {
      try {
        await _mockChannel.invokeMethod('hideFloat');
      } catch (_) {}
      return;
    }
    try {
      final shown = await _mockChannel.invokeMethod<bool>('showFloat') ?? false;
      if (!shown && mounted) {
        _toastWithAction(
          '没有悬浮窗权限，无法在其它应用上显示控制条',
          '去授权',
          () => _mockChannel.invokeMethod('openOverlaySettings'),
        );
      }
    } catch (_) {}
  }

  Future<void> _openUrl(String url) async {    try {
      await _mockChannel.invokeMethod('openUrl', {'url': url});
    } on PlatformException catch (e) {
      _toast(e.message ?? '无法打开链接');
    }
  }

  // ---------------------------------------------------------------- 提示

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 210),
        ),
      );
  }

  void _toastWithAction(String message, String action, VoidCallback onPressed) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 6),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 210),
          action: SnackBarAction(label: action, onPressed: onPressed),
        ),
      );
  }

  String _friendly(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  /// 定位来源的中文短标签（gps / network / fused / passive）。
  String _providerLabel(String? provider) {
    if (provider == null || provider.isEmpty) return '';
    return switch (provider) {
      'gps' => ' · GPS',
      'network' => ' · 网络',
      'fused' => ' · 融合',
      'passive' => ' · 被动',
      _ => ' · $provider',
    };
  }

  void _showMockGuide() => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('需要开启模拟位置'),
      content: const Text(
        '1. 设置 → 关于手机 → 连续点击“版本号”7 次开启开发者选项\n'
        '2. 开发者选项 → “选择模拟位置信息应用” → 选择“虚拟定位”\n'
        '3. 返回本应用点击开始',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            Navigator.pop(c);
            _mockChannel.invokeMethod('openDevSettings');
          },
          child: const Text('去设置'),
        ),
      ],
    ),
  );

  void _showLocationHelp() => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('定位不可用'),
      content: const Text(
        '请确认：\n'
        '· 已授予定位权限\n'
        '· 手机的“位置信息”开关已打开\n'
        '· 在室内时可到窗边重试，或手动搜索地点',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('知道了')),
        TextButton(
          onPressed: () async {
            Navigator.pop(c);
            await _mockChannel.invokeMethod('requestPermissions');
            await _locate(moveMap: true, adopt: !_running);
          },
          child: const Text('重新授权并定位'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(c);
            _mockChannel.invokeMethod('openLocationSettings');
          },
          child: const Text('定位设置'),
        ),
      ],
    ),
  );

  // ---------------------------------------------------------------- 视图

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_storage == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      body: Stack(
        children: [
          _buildMap(theme),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                _buildSearchBar(theme),
                if (_searchHint != null) _buildHintCard(theme),
                if (_results.isNotEmpty) Flexible(child: _buildResults(theme)),
                if (_results.isEmpty &&
                    _searchHint == null &&
                    _suggestions.isNotEmpty)
                  Flexible(child: _buildSuggestions(theme)),
              ],
            ),
          ),
          if (_results.isEmpty && _suggestions.isEmpty)
            _buildMapControls(theme),
          if (_joystickOn) _buildJoystick(theme),
          _buildTargetPanel(theme),
        ],
      ),
    );
  }

  Widget _buildMap(ThemeData theme) {
    final scheme = theme.colorScheme;
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _target,
        initialZoom: 16,
        minZoom: 3,
        maxZoom: 19,
        backgroundColor: const Color(0xFFEDEBE6),
        onMapReady: () {
          _mapReady = true;
          // 定位可能早于地图初始化返回，这里把地图对齐到当前目标点
          try {
            _map.move(_target, 16);
          } catch (_) {}
        },
        onTap: (_, point) => _setTarget(point, resolve: true),
        onLongPress: (_, point) {
          HapticFeedback.mediumImpact();
          _setTarget(point, resolve: true);
        },
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        ..._tileLayers(),
        if (_config.showRadius)
          CircleLayer(
            circles: [
              CircleMarker(
                point: _target,
                radius: _config.radiusMeters,
                useRadiusInMeter: true,
                color: scheme.primary.withValues(alpha: 0.10),
                borderColor: scheme.primary.withValues(alpha: 0.55),
                borderStrokeWidth: 1.5,
              ),
            ],
          ),
        if (_real != null)
          CircleLayer(
            circles: [
              CircleMarker(
                point: _real!,
                radius: max(_realAccuracy ?? 20, 10),
                useRadiusInMeter: true,
                color: Colors.blue.withValues(alpha: 0.10),
                borderColor: Colors.blue.withValues(alpha: 0.35),
                borderStrokeWidth: 1,
              ),
            ],
          ),
        if (_real != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _real!,
                width: 22,
                height: 22,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            Marker(
              point: _target,
              width: 40,
              height: 46,
              alignment: Alignment.bottomCenter,
              child: IgnorePointer(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: _running ? const Color(0xFF17B978) : scheme.primary,
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
                      child: Icon(
                        _running ? Icons.navigation : Icons.place,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                    Container(
                      width: 2,
                      height: 12,
                      color: (_running
                              ? const Color(0xFF17B978)
                              : scheme.primary)
                          .withValues(alpha: 0.8),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        Scalebar(
          alignment: Alignment.bottomLeft,
          padding: const EdgeInsets.only(left: 12, bottom: 220),
          textStyle: const TextStyle(fontSize: 11, color: Color(0xFF444444)),
          lineColor: const Color(0xFF666666),
        ),
      ],
    );
  }

  List<Widget> _tileLayers() {
    const subdomains = ['1', '2', '3', '4'];
    const ua = 'com.rz.fake_location';
    String tiles(String host, String query) =>
        'https://$host.is.autonavi.com/appmaptile?$query&x={x}&y={y}&z={z}';

    switch (_config.mapStyle) {
      case MapStyle.satellite:
        return [
          TileLayer(
            urlTemplate: tiles('webst0{s}', 'style=6'),
            subdomains: subdomains,
            maxNativeZoom: 18,
            userAgentPackageName: ua,
          ),
          TileLayer(
            urlTemplate: tiles('webst0{s}', 'style=8'),
            subdomains: subdomains,
            maxNativeZoom: 18,
            userAgentPackageName: ua,
          ),
        ];
      case MapStyle.road:
        return [
          TileLayer(
            urlTemplate: tiles(
              'wprd0{s}',
              'lang=zh_cn&size=1&scl=1&style=8',
            ),
            subdomains: subdomains,
            maxNativeZoom: 18,
            userAgentPackageName: ua,
          ),
        ];
      case MapStyle.standard:
        return [
          TileLayer(
            urlTemplate: tiles(
              'wprd0{s}',
              'lang=zh_cn&size=1&scale=1&style=7',
            ),
            subdomains: subdomains,
            maxNativeZoom: 18,
            userAgentPackageName: ua,
          ),
        ];
    }
  }

  Widget _buildSearchBar(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Material(
        elevation: 4,
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(26),
        color: scheme.surface,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 14),
              Icon(Icons.search, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  onChanged: _onQueryChanged,
                  decoration: const InputDecoration(
                    hintText: '搜索地点，或输入 29.75,106.58',
                    hintMaxLines: 1,
                  ),
                ),
              ),
              if (_searching)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (_searchCtrl.text.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => setState(() {
                    _searchCtrl.clear();
                    _results = const [];
                    _searchHint = null;
                  }),
                ),
              IconButton(
                icon: const Icon(Icons.arrow_forward, size: 20),
                onPressed: _search,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHintCard(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(14),
        color: theme.colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _searchHint!,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 16),
                onPressed: () => setState(() => _searchHint = null),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSuggestions(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(16),
        color: theme.colorScheme.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: _suggestions.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 48),
            itemBuilder: (context, index) {
              final text = _suggestions[index];
              return ListTile(
                dense: true,
                leading: Icon(
                  Icons.search,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  _searchCtrl
                    ..text = text
                    ..selection = TextSelection.collapsed(
                      offset: text.length,
                    );
                  setState(() => _suggestions = const []);
                  _search();
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(16),
        color: theme.colorScheme.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 340),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: _results.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
            itemBuilder: (context, index) {
              final place = _results[index];
              return ListTile(
                dense: true,
                leading: _sourceBadge(theme, place.source),
                title: Text(
                  place.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    if (place.subtitle.isNotEmpty) place.subtitle,
                    if (place.distanceMeters != null)
                      formatDistance(place.distanceMeters!),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => _applyResult(place),
                onLongPress: () => _savePlace(place),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _sourceBadge(ThemeData theme, PlaceSource source) {
    final color = switch (source) {
      PlaceSource.amap => const Color(0xFF1E7FD6),
      PlaceSource.baidu => const Color(0xFFDA3A20),
      PlaceSource.osm => const Color(0xFF5B8DEF),
      _ => theme.colorScheme.primary,
    };
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        source.label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 虚拟摇杆：按住拖动即刻移动，松手停下，模拟“人在地图上走”。
  Widget _buildJoystick(ThemeData theme) {
    const size = 132.0;
    final scheme = theme.colorScheme;
    return Positioned(
      left: 16,
      bottom: 300,
      // 给定明确尺寸，避免 Column 在 Positioned 里被拉成整屏导致点击区域错位
      width: size + 24,
      height: size + 42,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: scheme.surface.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Text(
                '按住拖动 · 松手停下',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Listener(
            // 用原始指针事件，避免和地图的拖动手势抢手势竞技场
            onPointerDown: (event) => _updateStick(event.localPosition, size),
            onPointerMove: (event) => _updateStick(event.localPosition, size),
            onPointerUp: (_) => _onStick(Offset.zero),
            onPointerCancel: (_) => _onStick(Offset.zero),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xCC1B1B1F),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.25),
                  width: 1.5,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.add,
                    color: Colors.white.withValues(alpha: 0.18),
                    size: 26,
                  ),
                  Align(
                    alignment: Alignment(_stick.dx, _stick.dy),
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.primary,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(
                        Icons.navigation,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapControls(ThemeData theme) {
    return Positioned(
      right: 12,
      bottom: 236,
      child: Column(
        children: [
          _ControlButton(
            icon: Icons.layers_outlined,
            tooltip: '底图：${_config.mapStyle.label}',
            onTap: _pickMapStyle,
          ),
          const SizedBox(height: 10),
          _ControlButton(
            icon: Icons.sports_esports_outlined,
            tooltip: _joystickOn ? '关闭摇杆' : '摇杆移动',
            highlight: _joystickOn,
            onTap: _toggleJoystick,
          ),
          const SizedBox(height: 10),
          _ControlButton(
            icon: Icons.zoom_in,
            tooltip: '放大',
            onTap: () => _map.move(
              _mapCenter(),
              min((_mapReady ? _map.camera.zoom : 16) + 1, 19),
            ),
          ),
          const SizedBox(height: 10),
          _ControlButton(
            icon: Icons.zoom_out,
            tooltip: '缩小',
            onTap: () => _map.move(
              _mapCenter(),
              max((_mapReady ? _map.camera.zoom : 16) - 1, 3),
            ),
          ),
          const SizedBox(height: 10),
          _ControlButton(
            icon: _locating ? Icons.hourglass_top : Icons.my_location,
            tooltip: '定位到当前位置',
            highlight: true,
            onTap: () => _locate(moveMap: true, adopt: !_running),
          ),
        ],
      ),
    );
  }

  Future<void> _pickMapStyle() async {
    final chosen = await showModalBottomSheet<MapStyle>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final style in MapStyle.values)
              ListTile(
                leading: Icon(
                  style == MapStyle.satellite
                      ? Icons.satellite_alt_outlined
                      : style == MapStyle.road
                      ? Icons.map_outlined
                      : Icons.layers_outlined,
                ),
                title: Text(style.label),
                trailing: _config.mapStyle == style
                    ? const Icon(Icons.check, size: 20)
                    : null,
                onTap: () => Navigator.pop(c, style),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || chosen == _config.mapStyle) return;
    setState(() => _config.mapStyle = chosen);
    await _storage?.writeConfig(_config);
  }

  Widget _buildTargetPanel(ThemeData theme) {
    final scheme = theme.colorScheme;
    final shown = _config.coordSystem.fromGcj(_target);
    final accuracy = _realAccuracy;
    final statusColor = _running ? const Color(0xFF17B978) : scheme.outline;
    final title = _targetName ??
        (_resolving ? '正在解析地址…' : (_targetAddress ?? '地图选点'));
    final subtitle = _targetAddress ?? '未解析到地址';

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: scheme.surface,
        elevation: 12,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: statusColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _running ? '模拟中' : '未启动',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: statusColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (accuracy != null) ...[
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    _realIsMock
                                        ? (_running
                                              ? '系统已接管 ±${accuracy.round()} 米'
                                              : '正在恢复真实定位…')
                                        : '真实定位 ±${accuracy.round()} 米'
                                              '${_providerLabel(_realProvider)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '存为常用地点',
                      icon: const Icon(Icons.star_border),
                      onPressed: () => _savePlace(
                        Place(
                          name: _targetName ?? _targetAddress ?? '自定义位置',
                          gcj: _target,
                          address: _targetAddress ?? '',
                          source: _targetSource ?? PlaceSource.manual,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '复制坐标',
                      icon: const Icon(Icons.copy_rounded),
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(
                            text: formatLatLng(shown, digits: 6),
                          ),
                        );
                        _toast('已复制 ${_config.coordSystem.label} 坐标');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.place_outlined,
                        size: 15,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          formatLatLng(shown, digits: 6),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Text(
                        _config.coordSystem.label,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _start,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(_running ? '更新到此位置' : '开始模拟'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _running ? _stop : null,
                        icon: const Icon(Icons.stop_rounded),
                        label: const Text('停止'),
                      ),
                    ),
                  ],
                ),
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: scheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      _PanelAction(
                        icon: Icons.pin_drop_outlined,
                        label: '坐标',
                        onTap: _openCoordinate,
                      ),
                      _PanelAction(
                        icon: Icons.route_outlined,
                        label: '路线',
                        onTap: _openRoute,
                      ),
                      _PanelAction(
                        icon: Icons.star_outline,
                        label: '常用',
                        onTap: _openSaved,
                      ),
                      _PanelAction(
                        icon: Icons.more_horiz,
                        label: '更多',
                        onTap: _openMore,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.highlight = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: highlight ? scheme.primary : scheme.surface,
      elevation: 3,
      shadowColor: Colors.black26,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip ?? '',
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              icon,
              size: 22,
              color: highlight ? scheme.onPrimary : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelAction extends StatelessWidget {
  const _PanelAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: scheme.onSurfaceVariant),
              const SizedBox(height: 3),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
