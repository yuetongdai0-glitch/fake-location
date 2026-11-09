import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/app_update.dart';
import '../core/coord.dart';
import '../core/coordinate_input.dart';
import '../core/models.dart';
import '../core/search_api.dart';
import '../core/storage.dart';
import '../core/user_message.dart';
import '../core/joystick_motion.dart';
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
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
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
  int _searchSeq = 0;
  int _mockGeneration = 0;

  /// 虚拟摇杆：开启后按住就能像走路一样实时移动目标点。
  bool _joystickOn = false;
  Offset _stick = Offset.zero;
  Timer? _stickTimer;
  final Stopwatch _stickClock = Stopwatch();
  int _lastStickTickMs = 0;
  double _stickBearing = 0;

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
    _stickTimer?.cancel();
    _stickClock.stop();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshRunning();
    } else if (_stick != Offset.zero) {
      // 失去前台时可能收不到松手事件，不能继续在后台按最后方向移动。
      _onStick(Offset.zero);
    }
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
    final generation = _mockGeneration;
    try {
      final running = await _mockChannel.invokeMethod<bool>('isRunning');
      if (mounted && running != null && generation == _mockGeneration) {
        setState(() => _running = running);
        if (running) _startHealthCheck();
      }
    } catch (_) {}
  }

  Future<void> _loadVersionAndCheckUpdate() async {
    try {
      final version = await _updateChannel.invokeMapMethod<String, dynamic>(
        'version',
      );
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
      if (mounted) _toast(userMessage(e, fallback: '下载安装失败，请重试'));
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
        {'fresh': fresh, 'realOnly': fresh},
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
        final message = userMessage(e, fallback: '未能读取位置，请检查定位权限');
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
    _cancelSearch();
    setState(() {
      _target = gcj;
      _targetName = name;
      _targetAddress = address;
      _targetSource = source;
      _results = const [];
      _searching = false;
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
    _persistTimer = Timer(const Duration(milliseconds: 600), () async {
      _config.lastTarget = _target;
      _config.lastName = _targetName;
      _config.lastAddress = _targetAddress;
      try {
        await _storage?.writeConfig(_config);
      } catch (error) {
        _toast(userMessage(error, fallback: '选点保存失败，下次打开可能无法恢复'));
      }
    });
  }

  void _scheduleReverseGeocode(LatLng point) {
    _resolveTimer?.cancel();
    _resolveTimer = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      setState(() => _resolving = true);
      final address = await SearchApi(amapKey: _config.amapKey)
          .reverseGeocode(point);
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

  /// 立刻废弃防抖和在途请求；即使网络回包较晚，也不能重新弹出已关闭的列表。
  void _cancelSearch() {
    _suggestTimer?.cancel();
    _searchSeq++;
  }

  /// 清空搜索时保留当前选点，并允许立即输入下一次搜索。
  void _clearSearch() {
    _cancelSearch();
    setState(() {
      _searchCtrl.clear();
      _results = const [];
      _searchHint = null;
      _searching = false;
    });
    _searchFocus.requestFocus();
  }

  /// 提交关键词搜索；结果只由当前请求更新，避免旧请求覆盖新输入或选点。
  Future<void> _search() async {
    _cancelSearch();
    final seq = _searchSeq;
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) {
      _clearSearch();
      return;
    }
    FocusScope.of(context).unfocus();

    final coord = parseCoordinateQuery(query);
    if (coord != null) {
      _setTarget(
        coord,
        name: CoordinateInput.containsLink(query) ? '链接选点' : '坐标选点',
        source: PlaceSource.pasted,
        move: true,
        resolve: true,
      );
      return;
    }

    if (CoordinateInput.containsLink(query) ||
        CoordinateInput.isGeoLink(query)) {
      // 未解析的短链不交给地点搜索，避免把链接 ID 或跟踪参数当成地点查询。
      setState(() {
        _searching = false;
        _results = const [];
        _searchHint = CoordinateInput.isGeoLink(query)
            ? '地理链接未包含明确且有效的单点坐标。请复制经纬度，地址查询不能直接用于定位。'
            : '链接未包含可直接读取的单点坐标。请复制经纬度，或使用带坐标的高德、百度、腾讯、谷歌地点链接。';
      });
      return;
    }

    setState(() {
      _searching = true;
      _results = const [];
      _searchHint = null;
    });
    try {
      final outcome = await SearchApi(amapKey: _config.amapKey)
          .search(query, center: _mapCenter(), origin: _real ?? _mapCenter());
      if (!mounted || seq != _searchSeq) return;
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
      if (mounted && seq == _searchSeq) {
        setState(() => _searchHint = '搜索失败，请检查网络连接后重试');
      }
    } finally {
      if (mounted && seq == _searchSeq) {
        setState(() => _searching = false);
      }
    }
  }

  /// 输入防抖后展示带地址和坐标的候选地点，与正式搜索共用一次选择即可落点的列表。
  void _onQueryChanged(String value) {
    _cancelSearch();
    final seq = _searchSeq;
    final query = value.trim();
    setState(() {
      _results = const [];
      _searchHint = null;
      _searching = false;
    });
    if (query.length < 2 ||
        CoordinateInput.containsLink(query) ||
        CoordinateInput.isGeoLink(query) ||
        parseCoordinateQuery(query) != null) {
      return;
    }
    _suggestTimer = Timer(const Duration(milliseconds: 400), () async {
      setState(() => _searching = true);
      try {
        final list = await SearchApi(amapKey: _config.amapKey)
            .suggest(query, center: _mapCenter());
        if (!mounted || seq != _searchSeq) return;
        setState(() => _results = list);
      } catch (_) {
        // 联想失败仍保留回车搜索入口，不弹出阻断输入的提示。
      } finally {
        if (mounted && seq == _searchSeq) {
          setState(() => _searching = false);
        }
      }
    });
  }

  /// 选中候选直接应用坐标，不再以候选名称发起第二轮搜索。
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
    Map<String, dynamic>? location;
    try {
      location = await _mockChannel.invokeMapMethod<String, dynamic>(
        'getLocation',
        {'fresh': false, 'cachedOnly': true},
      );
    } catch (_) {
      location = null;
    }
    // getLocation 在无缓存时可能等待更新，服务快照必须在等待结束后读取。
    final wifi = await _wifiStatus();
    final power = await _powerStatus();
    final status = await _mockChannel.invokeMapMethod<String, dynamic>(
      'mockStatus',
    );
    if (status == null) return null;
    final providers =
        (status['providers'] as List?)?.map((e) => '$e').toList() ??
        const <String>[];
    final lat = (location?['lat'] as num?)?.toDouble();
    final lng = (location?['lng'] as num?)?.toDouble();
    final pushedLat = (status['lat'] as num?)?.toDouble();
    final pushedLng = (status['lng'] as num?)?.toDouble();
    final pushed = pushedLat == null || pushedLng == null
        ? null
        : LatLng(pushedLat, pushedLng);
    return MockReport(
      pushedWgs: pushed != null && Coord.isValidPoint(pushed) ? pushed : null,
      serviceRunning: (status['serviceActive'] ?? status['running']) == true,
      mockAppSelected: status['mockApp'] == true,
      pushCount: (status['pushCount'] as num?)?.toInt() ?? 0,
      elapsedMs: (status['elapsedMs'] as num?)?.toInt() ?? -1,
      providers: providers,
      systemWgs: lat == null || lng == null ? null : LatLng(lat, lng),
      systemAccuracy: (location?['accuracy'] as num?)?.toDouble(),
      systemIsMock: location?['mock'] == true,
      systemProvider: location?['provider'] as String?,
      expectedProviders:
          (status['expectedProviders'] as List?)?.map((e) => '$e').toList() ??
          const [],
      providerErrors:
          (status['providerErrors'] as Map?)?.map(
            (key, value) => MapEntry('$key', '$value'),
          ) ??
          const {},
      providerLocations:
          (status['providerLocations'] as List?)
              ?.whereType<Map>()
              .map(MockProviderReport.fromMap)
              .toList() ??
          const [],
      wifiEnabled: wifi['enabled'] == true,
      wifiScanEnabled: wifi['scanAlwaysAvailable'] == true,
      ignoringBatteryOptimizations:
          power['ignoringBatteryOptimizations'] as bool?,
      powerSaveMode: power['powerSaveMode'] as bool?,
      backgroundRestricted: power['backgroundRestricted'] as bool?,
      powerErrors:
          (power['errors'] as Map?)?.map(
            (key, value) => MapEntry('$key', '$value'),
          ) ??
          const {},
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
        onRetryPush: _start,
        onOpenAppSettings: _openAppSettings,
        onOpenExternalApp: _openExternalApp,
      ),
    );
  }

  Future<void> _openExternalApp(String package) async {
    try {
      await _mockChannel.invokeMethod('openApp', {'package': package});
    } on PlatformException catch (e) {
      _toast(userMessage(e, fallback: '无法打开目标应用，请检查是否已安装'));
    }
  }

  /// 开始模拟后自动校验一次，没生效就提示用户去检测。
  Future<void> _verifyAfterStart(LatLng startedTarget, int generation) async {
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (!mounted || generation != _mockGeneration || !_running) return;
    try {
      final report = await _loadMockReport();
      if (report == null || !mounted || generation != _mockGeneration) return;
      if (!report.matchesTarget(startedTarget)) {
        _toastWithAction(
          report.mockAppSelected ? '部分定位源尚未确认生效，请查看检测详情' : '还没把本应用设为“模拟位置信息应用”',
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
      final generation = _mockGeneration;
      try {
        final status = await _mockChannel.invokeMapMethod<String, dynamic>(
          'mockStatus',
        );
        if (!mounted || status == null || generation != _mockGeneration) return;
        // 推送暂时失败时服务仍在自动重试，保留停止入口，不误报恢复真实定位。
        final alive = (status['serviceActive'] ?? status['running']) == true;
        if (!alive) {
          setState(() => _running = false);
          // 可能是被系统清理，也可能是在悬浮条上点了“回真实位置”
          _toastWithAction('模拟已停止，定位已恢复', '重新开始', _start);
        }
      } catch (_) {}
    });
  }

  /// WiFi 仅作为诊断信息，不把开启 WiFi 当成系统模拟失败的证据。
  Future<Map<String, dynamic>> _wifiStatus() async {
    try {
      return await _mockChannel.invokeMapMethod<String, dynamic>(
            'wifiStatus',
          ) ??
          const {};
    } catch (_) {
      return const {};
    }
  }

  /// 只读取后台限制，不替用户授予电池豁免或改变省电设置。
  Future<Map<String, dynamic>> _powerStatus() async {
    try {
      return await _mockChannel.invokeMapMethod<String, dynamic>(
            'powerStatus',
          ) ??
          const {};
    } catch (_) {
      return const {};
    }
  }

  /// 打开本应用详情，由用户按设备提供的选项调整后台运行权限。
  Future<void> _openAppSettings() async {
    try {
      await _mockChannel.invokeMethod('openAppSettings');
    } catch (error) {
      _toast(userMessage(error, fallback: '无法打开应用设置，请手动进入系统设置'));
    }
  }

  Future<void> _start() async {
    if (!mounted) return;
    final write = _writePoint;
    final generation = ++_mockGeneration;
    try {
      await _mockChannel.invokeMethod('start', {
        'lat': write.latitude,
        'lng': write.longitude,
        'intervalMs': _config.intervalMs,
        'accuracy': _config.accuracyMeters,
      });
      if (!mounted || generation != _mockGeneration) return;
      setState(() => _running = true);
      if (_config.floatBar) unawaited(_syncFloatBar(true));
      final place = Place(
        name: _targetName ?? _targetAddress ?? '自定义位置',
        gcj: _target,
        address: _targetAddress ?? '',
        source: _targetSource ?? PlaceSource.manual,
      );
      String? recentWarning;
      // 服务已经启动，历史记录保存失败不能遮住停止入口或跳过服务校验。
      try {
        await _storage?.addRecent(place);
      } catch (error) {
        recentWarning = userMessage(error, fallback: '最近记录保存失败');
      }
      if (!mounted || generation != _mockGeneration) return;
      setState(() => _recents = _storage?.readRecents() ?? _recents);
      unawaited(_locate(silent: true));
      unawaited(_verifyAfterStart(write, generation));
      _startHealthCheck();
      _toast(
        '已开始模拟：${_config.writeGcj ? 'GCJ-02' : 'WGS-84'} '
        '${formatLatLng(write, digits: 6)}'
        '${recentWarning == null ? '' : '；$recentWarning'}',
      );
    } on PlatformException catch (e) {
      if (!mounted || generation != _mockGeneration) return;
      if (e.code == 'NOT_MOCK_APP') {
        _showMockGuide();
      } else {
        _toast(userMessage(e, fallback: '启动失败，请检查模拟位置授权后重试'));
      }
    }
  }

  Future<void> _stop() async {
    final generation = ++_mockGeneration;
    _stickTimer?.cancel();
    _stickTimer = null;
    _stickClock
      ..stop()
      ..reset();
    _stick = Offset.zero;
    try {
      await _mockChannel.invokeMethod('stop');
      if (!mounted || generation != _mockGeneration) return;
      setState(() => _running = false);
      _healthTimer?.cancel();
      unawaited(_syncFloatBar(false));
      unawaited(_locate(silent: true, fresh: true));
      _toast('已停止，恢复真实定位');
    } on PlatformException catch (e) {
      _toast(userMessage(e, fallback: '停止失败，请重试'));
    }
  }

  // ---------------------------------------------------------------- 路线 / 摇杆

  Future<void> _openRoute() async {
    if (_stick != Offset.zero) _onStick(Offset.zero);
    _mockGeneration++;
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
    if (!_joystickOn) _onStick(Offset.zero);
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
    final wasMoving = _stick != Offset.zero || _stickTimer != null;
    setState(() => _stick = value);
    if (value == Offset.zero) {
      _stickTimer?.cancel();
      _stickTimer = null;
      _stickClock
        ..stop()
        ..reset();
      _lastStickTickMs = 0;
      if (_running && wasMoving) {
        unawaited(_pushManualMotion(0, _stickBearing));
      }
      return;
    }
    if (!_stickClock.isRunning) {
      _stickClock
        ..reset()
        ..start();
      _lastStickTickMs = 0;
    }
    _stickTimer ??= Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _stickStep(),
    );
  }

  /// 摇杆按实际经过时间、杆量及共享球面正解移动，速度与写入系统的字段一致。
  Future<void> _stickStep() async {
    final stick = _stick;
    if (stick == Offset.zero || !mounted) return;
    final now = _stickClock.elapsedMilliseconds;
    final elapsed = now - _lastStickTickMs;
    _lastStickTickMs = now;
    final motion = _config.motion;
    final speed = motion.usesSteps
        ? _config.stepFreq / 60 * _config.stepLength
        : motion.defaultSpeed;
    final step = advanceJoystick(
      origin: _config.writeGcj ? _target : Coord.gcjToWgs(_target),
      north: -stick.dy,
      east: stick.dx,
      speed: speed,
      elapsedMs: elapsed,
    );
    _stickBearing = step.bearing;
    final nextTarget = _config.writeGcj
        ? step.point
        : Coord.wgsToGcj(step.point);
    setState(() {
      _target = nextTarget;
      _targetName ??= '摇杆移动';
    });
    _moveTo(nextTarget, _mapReady ? _map.camera.zoom : 17);
    _schedulePersist();
    if (_running) await _pushManualMotion(step.speed, step.bearing);
  }

  /// 松杆时也立即下发零速度，不能让停止的坐标保留“正在移动”的速度标记。
  Future<void> _pushManualMotion(double speed, double bearing) async {
    _mockGeneration++;
    final write = _writePoint;
    try {
      await _mockChannel.invokeMethod('start', <String, Object?>{
        'lat': write.latitude,
        'lng': write.longitude,
        'manualSpeed': speed,
        'manualBearing': bearing,
        'intervalMs': _config.intervalMs,
        'accuracy': _config.accuracyMeters,
      });
    } catch (error) {
      _toast(userMessage(error, fallback: '位置更新失败，请重试'));
    }
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

    final list = List<SavedPlace>.of(_favorites);
    list.removeWhere(
      (e) => e.name == name && Coord.distanceMeters(e.gcj, place.gcj) < 50,
    );
    list.insert(0, SavedPlace.fromPlace(place, name: name));
    try {
      await _storage?.writeFavorites(list);
    } catch (error) {
      _toast(userMessage(error, fallback: '地点保存失败，请重试'));
      return;
    }
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
          if (_favorites.any((place) => place.id == saved.id)) {
            await _storage?.writeFavorites(list);
          } else {
            await _storage?.removeRecent(saved.id);
          }
          if (mounted) {
            setState(() {
              _favorites = list;
              _recents = _storage?.readRecents() ?? _recents;
            });
          }
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
          if (_running) unawaited(_pushManualMotion(0, 0));
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
          if (_running) unawaited(_pushManualMotion(0, 0));
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
          await _storage?.writeConfig(config);
          if (!mounted) return;
          setState(() => _config = config);
          await _syncFloatBar(wantedFloat);
        },
        onCheckUpdate: () => _checkUpdate(manual: true),
        onInstallUpdate: _installUpdate,
        onOpenUrl: _openUrl,
        storage: _storage!,
      ),
    );
    if (mounted && _storage != null) {
      setState(() {
        _favorites = _storage!.readFavorites();
        _recents = _storage!.readRecents();
      });
    }
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

  Future<void> _openUrl(String url) async {
    try {
      await _mockChannel.invokeMethod('openUrl', {'url': url});
    } on PlatformException catch (e) {
      _toast(userMessage(e, fallback: '无法打开链接，请检查浏览器'));
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

  /// 定位来源的中文短标签（gps / network / fused / passive）。
  String _providerLabel(String? provider) {
    if (provider == null || provider.isEmpty) return '';
    return switch (provider) {
      'gps' => ' · 卫星',
      'network' => ' · 网络',
      'fused' => ' · 融合',
      'passive' => ' · 被动',
      _ => ' · 未知来源',
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
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildDrawer(theme),
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
              ],
            ),
          ),
          if (_results.isEmpty) _buildMapControls(theme),
          if (_joystickOn) _buildJoystick(theme),
          _buildTargetPanel(theme),
        ],
      ),
    );
  }

  /// 侧边抽屉：参考 Fake Location 的分组菜单，底部不再放 tab。
  Widget _buildDrawer(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Drawer(
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 26, 20, 24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [scheme.primary, const Color(0xFF14A18C)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: const BorderRadius.only(
                  bottomRight: Radius.circular(26),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // 与桌面图标共用品牌资产，避免应用内外使用不同的定位标识。
                      Image.asset(
                        'assets/branding/app-icon.png',
                        width: 42,
                        height: 42,
                        semanticLabel: '虚拟定位标志',
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        '虚拟定位',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _installedVersionName.isEmpty
                          ? '免系统提权位置模拟'
                          : '版本 $_installedVersionName · 免系统提权',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _drawerItem(
                    theme,
                    Icons.place_outlined,
                    '位置模拟',
                    selected: true,
                  ),
                  _drawerItem(
                    theme,
                    Icons.pin_drop_outlined,
                    '坐标输入',
                    onTap: _openCoordinate,
                  ),
                  _drawerItem(
                    theme,
                    Icons.route_outlined,
                    '路线模拟',
                    onTap: _openRoute,
                  ),
                  _drawerItem(
                    theme,
                    Icons.control_camera_outlined,
                    '摇杆移动',
                    onTap: _toggleJoystick,
                  ),
                  _drawerItem(
                    theme,
                    Icons.star_outline,
                    '常用地点',
                    onTap: _openSaved,
                  ),
                  const Divider(indent: 16, endIndent: 16, height: 16),
                  _drawerItem(
                    theme,
                    Icons.open_with,
                    '微调位置',
                    onTap: _openNudge,
                  ),
                  _drawerItem(
                    theme,
                    Icons.verified_outlined,
                    '生效检测',
                    onTap: _openMockCheck,
                  ),
                  _drawerItem(
                    theme,
                    Icons.settings_outlined,
                    '设置',
                    onTap: _openSettings,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
              child: Row(
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '免系统提权方案 · 仅用于开发调试与学习',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerItem(
    ThemeData theme,
    IconData icon,
    String title, {
    bool selected = false,
    VoidCallback? onTap,
  }) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: ListTile(
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        tileColor: selected ? scheme.primary.withValues(alpha: 0.10) : null,
        leading: Icon(
          icon,
          size: 20,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? scheme.primary : scheme.onSurface,
          ),
        ),
        onTap: () {
          Navigator.of(context).pop();
          if (!selected && onTap != null) {
            // 等抽屉收起再打开下一个面板，避免两个路由打架
            Future<void>.delayed(const Duration(milliseconds: 220), onTap);
          }
        },
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
                        color: _running
                            ? const Color(0xFF17B978)
                            : scheme.primary,
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
                      color:
                          (_running ? const Color(0xFF17B978) : scheme.primary)
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
            urlTemplate: tiles('wprd0{s}', 'lang=zh_cn&size=1&scl=1&style=8'),
            subdomains: subdomains,
            maxNativeZoom: 18,
            userAgentPackageName: ua,
          ),
        ];
      case MapStyle.standard:
        return [
          TileLayer(
            urlTemplate: tiles('wprd0{s}', 'lang=zh_cn&size=1&scale=1&style=7'),
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 12,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: '菜单',
              icon: const Icon(Icons.menu_rounded, size: 22),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
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
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
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
              ),
            if (_searchCtrl.text.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20),
                tooltip: '清空搜索',
                onPressed: _clearSearch,
              ),
            IconButton(
              tooltip: '搜索',
              icon: Icon(
                Icons.arrow_forward_rounded,
                size: 20,
                color: scheme.primary,
              ),
              onPressed: _search,
            ),
          ],
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
                child: Text(_searchHint!, style: theme.textTheme.bodySmall),
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
            icon: Icons.add_rounded,
            tooltip: '放大',
            onTap: () => _map.move(
              _mapCenter(),
              min((_mapReady ? _map.camera.zoom : 16) + 1, 19),
            ),
          ),
          const SizedBox(height: 10),
          _ControlButton(
            icon: Icons.remove_rounded,
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
    try {
      await _storage?.writeConfig(_config);
    } catch (error) {
      _toast(userMessage(error, fallback: '地图样式保存失败，请重试'));
    }
  }

  Widget _buildTargetPanel(ThemeData theme) {
    final scheme = theme.colorScheme;
    final shown = _config.coordSystem.fromGcj(_target);
    final accuracy = _realAccuracy;
    final statusColor = _running ? const Color(0xFF17B978) : scheme.outline;
    final title =
        _targetName ?? (_resolving ? '正在解析地址…' : (_targetAddress ?? '地图选点'));
    final subtitle = _targetAddress ?? '未解析到地址';

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x16000000),
              blurRadius: 18,
              offset: Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8, bottom: 8),
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
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
                                    style: theme.textTheme.labelSmall?.copyWith(
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
                          ClipboardData(text: formatLatLng(shown, digits: 6)),
                        );
                        _toast('已复制 ${_config.coordSystem.label} 坐标');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.place_outlined,
                        size: 15,
                        color: scheme.primary,
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
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          _config.coordSystem.label,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
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
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: Text(_running ? '更新到此位置' : '开始模拟'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _running ? _stop : null,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                          side: BorderSide(color: scheme.outlineVariant),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        icon: const Icon(Icons.stop_rounded, size: 20),
                        label: const Text('停止'),
                      ),
                    ),
                  ],
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
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: highlight ? scheme.primary : scheme.surface,
        shape: BoxShape.circle,
        border: highlight ? null : Border.all(color: scheme.outlineVariant),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Tooltip(
            message: tooltip ?? '',
            child: Center(
              child: Icon(
                icon,
                size: 22,
                color: highlight ? scheme.onPrimary : scheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
