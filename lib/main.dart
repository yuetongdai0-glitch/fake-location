import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

void main() => runApp(
  const MaterialApp(
    title: '虚拟定位',
    debugShowCheckedModeBanner: false,
    home: HomePage(),
  ),
);

const _ch = MethodChannel('fake_location/mock');
const _updateCh = MethodChannel('fake_location/update');
const _updateManifestUrl =
    'https://raw.githubusercontent.com/yuetongdai0-glitch/fake-location-releases/main/update.json';

/// 应用更新清单，只描述安卓最新版安装包及其完整性信息。
class AppUpdate {
  const AppUpdate({
    required this.appId,
    required this.versionName,
    required this.versionCode,
    required this.apkUrl,
    required this.sha256,
    required this.minSdk,
  });

  final String appId;
  final String versionName;
  final int versionCode;
  final Uri apkUrl;
  final String sha256;
  final int minSdk;

  /// 从发布仓库更新清单解析安卓版本。
  ///
  /// 清单只接受 GitHub HTTPS 地址和完整 SHA-256，避免把未知来源的包交给安装器。
  factory AppUpdate.fromJson(Map<String, dynamic> json) {
    final androidValue = json['android'];
    if (androidValue is! Map) throw const FormatException('更新清单缺少 android 段');
    final android = Map<String, dynamic>.from(androidValue);
    final appId = json['appId'];
    final versionName = android['versionName'];
    final versionCode = android['versionCode'];
    final apkUrlValue = android['apkUrl'];
    final sha256 = android['sha256'];
    final minSdk = android['minSdk'] ?? 1;

    if (appId != 'com.rz.fake_location' ||
        versionName is! String ||
        versionName.isEmpty ||
        versionCode is! int ||
        versionCode < 1 ||
        apkUrlValue is! String ||
        sha256 is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256) ||
        minSdk is! int) {
      throw const FormatException('更新清单字段无效');
    }

    final apkUrl = Uri.tryParse(apkUrlValue);
    final host = apkUrl?.host.toLowerCase();
    if (apkUrl == null ||
        apkUrl.scheme != 'https' ||
        apkUrl.userInfo.isNotEmpty ||
        apkUrl.fragment.isNotEmpty ||
        host == null ||
        (host != 'raw.githubusercontent.com' &&
            host != 'github.com' &&
            !host.endsWith('.github.io'))) {
      throw const FormatException('安装包地址必须来自受信任的 GitHub HTTPS 域名');
    }

    return AppUpdate(
      appId: appId as String,
      versionName: versionName,
      versionCode: versionCode,
      apkUrl: apkUrl,
      sha256: sha256.toLowerCase(),
      minSdk: minSdk,
    );
  }

  /// 判断当前清单是否比已安装版本更新。
  bool isNewerThan(int installedVersionCode) =>
      versionCode > installedVersionCode;
}

/// 拉取发布仓库中的最新安卓版本清单。
Future<AppUpdate> fetchLatestUpdate() async {
  final requestId = DateTime.now().millisecondsSinceEpoch;
  final response = await http
      .get(
        Uri.parse('$_updateManifestUrl?_=$requestId'),
        headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
      )
      .timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) {
    throw Exception('检查更新失败：HTTP ${response.statusCode}');
  }
  final decoded = jsonDecode(utf8.decode(response.bodyBytes));
  if (decoded is! Map) throw const FormatException('更新清单格式无效');
  return AppUpdate.fromJson(Map<String, dynamic>.from(decoded));
}

/// 坐标系转换：地图用高德瓦片（GCJ-02），而系统 GPS 必须写入 WGS-84。
/// 国内 App 会把 GPS 的 WGS-84 自行转成 GCJ-02，所以这里需要反向转换后再写入。
class Coord {
  static const _a = 6378245.0;
  static const _ee = 0.00669342162296594323;

  static bool _outOfChina(double lat, double lng) =>
      lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;

  static double _tLat(double x, double y) {
    var r =
        -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * sqrt(x.abs());
    r += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0;
    r += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0;
    r += (160.0 * sin(y / 12.0 * pi) + 320 * sin(y * pi / 30.0)) * 2.0 / 3.0;
    return r;
  }

  static double _tLng(double x, double y) {
    var r =
        300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(x.abs());
    r += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0;
    r += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0;
    r += (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0;
    return r;
  }

  static LatLng wgsToGcj(LatLng p) {
    if (_outOfChina(p.latitude, p.longitude)) return p;
    var dLat = _tLat(p.longitude - 105.0, p.latitude - 35.0);
    var dLng = _tLng(p.longitude - 105.0, p.latitude - 35.0);
    final radLat = p.latitude / 180.0 * pi;
    var magic = sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = sqrt(magic);
    dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * pi);
    dLng = (dLng * 180.0) / (_a / sqrtMagic * cos(radLat) * pi);
    return LatLng(p.latitude + dLat, p.longitude + dLng);
  }

  /// 迭代法反解，精度约 1e-7 度（厘米级）
  static LatLng gcjToWgs(LatLng g) {
    var w = g;
    for (var i = 0; i < 5; i++) {
      final t = wgsToGcj(w);
      w = LatLng(
        w.latitude - (t.latitude - g.latitude),
        w.longitude - (t.longitude - g.longitude),
      );
    }
    return w;
  }
}

class Place {
  final String name;
  final LatLng gcj; // 统一以地图坐标系（GCJ-02）保存
  Place(this.name, this.gcj);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _map = MapController();
  final _q = TextEditingController();
  LatLng _picked = const LatLng(39.908722, 116.397499); // 默认天安门（GCJ-02）
  List<Place> _results = [];
  bool _running = false;
  bool _searching = false;
  bool _checkingUpdate = false;
  bool _updateBusy = false;
  int _installedVersionCode = 0;
  String _installedVersionName = '';
  AppUpdate? _availableUpdate;

  @override
  void initState() {
    super.initState();
    _ch
        .invokeMethod<bool>('isRunning')
        .then((v) => setState(() => _running = v ?? false));
    // 先申请权限，再定位到真实位置作为地图初始点
    _ch.invokeMethod('requestPermissions').then((_) => _locateMe(silent: true));
    _loadVersionAndCheckUpdate();
  }

  /// 读取本机版本并静默检查一次更新；启动时网络失败不打断定位功能。
  Future<void> _loadVersionAndCheckUpdate() async {
    try {
      final version = await _updateCh.invokeMapMethod<String, dynamic>(
        'version',
      );
      if (version != null && mounted) {
        setState(() {
          _installedVersionCode = version['versionCode'] as int? ?? 0;
          _installedVersionName = version['versionName'] as String? ?? '';
        });
      }
    } catch (_) {
      // 原生版本查询失败时仍保留手动检查入口。
    }
    await _checkUpdate(manual: false);
  }

  /// 检查发布仓库的最新版本，并更新底部更新按钮。
  Future<void> _checkUpdate({required bool manual}) async {
    if (_checkingUpdate || _updateBusy) return;
    setState(() => _checkingUpdate = true);
    try {
      final latest = await fetchLatestUpdate();
      final available =
          _installedVersionCode > 0 && latest.isNewerThan(_installedVersionCode)
          ? latest
          : null;
      if (!mounted) return;
      setState(() => _availableUpdate = available);
      if (manual) {
        _toast(
          available == null
              ? '当前已是最新版本 ${_installedVersionName.isEmpty ? '' : _installedVersionName}'
              : '发现新版本 ${available.versionName}',
        );
      }
    } catch (e) {
      if (manual && mounted) _toast('检查更新失败：${_friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  /// 下载并交给系统安装最新安卓包。
  Future<void> _installUpdate() async {
    final update = _availableUpdate;
    if (update == null || _updateBusy) return;
    setState(() {
      _updateBusy = true;
      _checkingUpdate = false;
    });
    try {
      await _updateCh.invokeMethod<bool>('downloadAndInstall', {
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

  /// 把异常转换为适合直接展示给用户的短文本。
  String _friendlyError(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  /// 获取系统当前位置（WGS-84）并转为地图坐标系显示。
  /// 注意：模拟进行中时系统返回的就是模拟位置，可用于核对是否生效。
  Future<void> _locateMe({bool silent = false}) async {
    try {
      final r = await _ch.invokeMapMethod<String, double>('getLocation');
      if (r == null) {
        if (!silent) _toast('获取位置失败，请确认已开启定位并授权');
        return;
      }
      _select(Coord.wgsToGcj(LatLng(r['lat']!, r['lng']!)));
    } on PlatformException catch (e) {
      if (!silent) _toast('获取位置失败：${e.message}');
    }
  }

  void _toast(String s) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(s)));

  /// 搜索：支持直接输入“纬度,经度”（按 WGS-84 解释），否则走 Photon 地名搜索。
  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    final m = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*[,，\s]\s*(-?\d+(?:\.\d+)?)\s*$')
        .firstMatch(q);
    if (m != null) {
      final lat = double.parse(m[1]!), lng = double.parse(m[2]!);
      if (lat.abs() > 90 || lng.abs() > 180) return _toast('坐标超出范围');
      _select(Coord.wgsToGcj(LatLng(lat, lng)));
      return;
    }
    setState(() => _searching = true);
    try {
      // Nominatim 在国内被墙，改用 Photon（同为 OSM 数据，国内可访问，返回 WGS-84）。
      // 传入地图中心作为位置偏好，让附近结果排在前面。
      final c = Coord.gcjToWgs(_map.camera.center);
      final uri = Uri.https('photon.komoot.io', '/api/', {
        'q': q,
        'limit': '15',
        'lat': c.latitude.toStringAsFixed(4),
        'lon': c.longitude.toStringAsFixed(4),
      });
      final res = await http
          .get(uri, headers: {'User-Agent': 'fake_location_app/1.0'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw '服务返回 ${res.statusCode}';
      final features =
          (jsonDecode(utf8.decode(res.bodyBytes))['features'] as List?) ?? [];
      setState(
        () => _results = features.map((f) {
          final pr = f['properties'] as Map;
          final xy = f['geometry']['coordinates'] as List;
          // 拼出“名称 · 区 · 市 · 省”便于区分同名地点
          final name = [
            pr['name'],
            pr['street'],
            pr['district'],
            pr['city'],
            pr['state'],
          ].where((e) => e != null && '$e'.isNotEmpty).toSet().join(' · ');
          return Place(
            name.isEmpty ? '未命名地点' : name,
            Coord.wgsToGcj(
              LatLng((xy[1] as num).toDouble(), (xy[0] as num).toDouble()),
            ),
          );
        }).toList(),
      );
      if (_results.isEmpty) _toast('没有搜索结果');
    } catch (e) {
      _toast('搜索失败（网络超时或无结果），可直接输入坐标：$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _select(LatLng gcj) {
    setState(() {
      _picked = gcj;
      _results = [];
    });
    _map.move(gcj, max(_map.camera.zoom, 16));
    FocusScope.of(context).unfocus();
  }

  Future<void> _start() async {
    final wgs = Coord.gcjToWgs(_picked);
    try {
      await _ch.invokeMethod('start', {
        'lat': wgs.latitude,
        'lng': wgs.longitude,
      });
      setState(() => _running = true);
      _toast('已开始模拟定位');
    } on PlatformException catch (e) {
      if (e.code == 'NOT_MOCK_APP') {
        _showMockGuide();
      } else {
        _toast('启动失败：${e.message}');
      }
    }
  }

  Future<void> _stop() async {
    await _ch.invokeMethod('stop');
    setState(() => _running = false);
    _toast('已停止，恢复真实定位');
  }

  void _showMockGuide() => showDialog(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('需要开启模拟位置'),
      content: const Text(
        '1. 设置 → 关于手机 → 连续点击“版本号”7次开启开发者选项\n'
        '2. 开发者选项 → “选择模拟位置信息应用” → 选择“虚拟定位”\n'
        '3. 返回本应用点击开始',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            Navigator.pop(c);
            _ch.invokeMethod('openDevSettings');
          },
          child: const Text('去设置'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final wgs = Coord.gcjToWgs(_picked);
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _picked,
              initialZoom: 15,
              onTap: (_, p) => _select(p),
            ),
            children: [
              // 高德瓦片：国内可直接访问，中文标注，坐标系为 GCJ-02
              TileLayer(
                urlTemplate: 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
                subdomains: const ['1', '2', '3', '4'],
                userAgentPackageName: 'com.rz.fake_location',
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: _picked,
                    width: 40,
                    height: 40,
                    alignment: Alignment.topCenter,
                    child: Icon(
                      Icons.location_on,
                      size: 40,
                      color: _running ? Colors.green : Colors.red,
                    ),
                  ),
                ],
              ),
            ],
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(8),
                    child: TextField(
                      controller: _q,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        hintText: '搜索地点，或输入 纬度,经度',
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.all(14),
                        suffixIcon: _searching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(Icons.search),
                                onPressed: _search,
                              ),
                      ),
                    ),
                  ),
                  if (_results.isNotEmpty)
                    Material(
                      elevation: 4,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 300),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _results.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) => ListTile(
                            dense: true,
                            title: Text(
                              _results[i].name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _select(_results[i].gcj),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 170,
            child: FloatingActionButton.small(
              heroTag: 'me',
              onPressed: _locateMe,
              child: const Icon(Icons.my_location),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 24,
            child: Card(
              elevation: 6,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '目标(WGS-84)：${wgs.latitude.toStringAsFixed(6)}, ${wgs.longitude.toStringAsFixed(6)}',
                    ),
                    Text(
                      _running ? '状态：模拟中' : '状态：未启动',
                      style: TextStyle(
                        color: _running ? Colors.green : Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _start,
                            icon: const Icon(Icons.play_arrow),
                            label: Text(_running ? '更新到此处' : '开始模拟'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _running ? _stop : null,
                            icon: const Icon(Icons.stop),
                            label: const Text('停止'),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 16),
                    Row(
                      children: [
                        Text(
                          _installedVersionName.isEmpty
                              ? '应用版本读取中'
                              : '版本 $_installedVersionName',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const Spacer(),
                        if (_checkingUpdate || _updateBusy)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          TextButton.icon(
                            onPressed: _availableUpdate == null
                                ? () => _checkUpdate(manual: true)
                                : _installUpdate,
                            icon: Icon(
                              _availableUpdate == null
                                  ? Icons.refresh
                                  : Icons.system_update_alt,
                            ),
                            label: Text(
                              _availableUpdate == null
                                  ? '检查更新'
                                  : '更新到 ${_availableUpdate!.versionName}',
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
