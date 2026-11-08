import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../core/app_update.dart';
import '../core/coord.dart';
import '../core/models.dart';
import '../core/storage.dart';

/// 常用地点 / 最近记录面板。
class SavedPlacesSheet extends StatefulWidget {
  const SavedPlacesSheet({
    super.key,
    required this.favorites,
    required this.recents,
    required this.onPick,
    required this.onDelete,
    required this.onRename,
    required this.onSaveCurrent,
    required this.onClearRecents,
  });

  final List<SavedPlace> favorites;
  final List<SavedPlace> recents;
  final ValueChanged<SavedPlace> onPick;
  final Future<void> Function(SavedPlace) onDelete;
  final Future<void> Function(SavedPlace, String) onRename;
  final VoidCallback onSaveCurrent;
  final Future<void> Function() onClearRecents;

  @override
  State<SavedPlacesSheet> createState() => _SavedPlacesSheetState();
}

class _SavedPlacesSheetState extends State<SavedPlacesSheet> {
  bool _showRecents = false;
  late List<SavedPlace> _favorites = List.of(widget.favorites);
  late List<SavedPlace> _recents = List.of(widget.recents);

  List<SavedPlace> get _items => _showRecents ? _recents : _favorites;

  Future<void> _rename(SavedPlace place) async {
    final controller = TextEditingController(text: place.name);
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '地点名称',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(c, v),
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
    if (result == null || result.isEmpty || result == place.name) return;
    await widget.onRename(place, result);
    if (!mounted) return;
    setState(() {
      _favorites = _favorites
          .map(
            (e) => e.id == place.id
                ? SavedPlace(
                    id: e.id,
                    name: result,
                    gcj: e.gcj,
                    address: e.address,
                    savedAt: e.savedAt,
                  )
                : e,
          )
          .toList();
    });
  }

  Future<void> _confirmDelete(SavedPlace place) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除地点'),
        content: Text('确定删除“${place.name}”吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.onDelete(place);
    if (!mounted) return;
    setState(() {
      _favorites = _favorites.where((e) => e.id != place.id).toList();
      _recents = _recents.where((e) => e.id != place.id).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('我的地点', style: theme.textTheme.titleMedium),
              const Spacer(),
              SegmentedButton<bool>(
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('常用')),
                  ButtonSegment(value: true, label: Text('最近')),
                ],
                selected: {_showRecents},
                onSelectionChanged: (v) => setState(() => _showRecents = v.first),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: _items.isEmpty
                ? SizedBox(
                    height: 150,
                    child: Center(
                      child: Text(
                        _showRecents
                            ? '还没有模拟记录。\n每次开始模拟都会自动记在这里。'
                            : '还没有常用地点。\n点下面的按钮把当前选点存起来。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final place = _items[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.primaryContainer,
                          child: Icon(
                            _showRecents ? Icons.history : Icons.star_rounded,
                            size: 20,
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                        ),
                        title: Text(
                          place.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          place.address.isEmpty
                              ? formatLatLng(place.gcj)
                              : place.address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          widget.onPick(place);
                        },
                        trailing: _showRecents
                            ? IconButton(
                                tooltip: '删除',
                                icon: const Icon(Icons.close, size: 20),
                                onPressed: () => _confirmDelete(place),
                              )
                            : PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert, size: 20),
                                onSelected: (value) {
                                  if (value == 'rename') _rename(place);
                                  if (value == 'delete') _confirmDelete(place);
                                  if (value == 'copy') {
                                    Clipboard.setData(
                                      ClipboardData(text: formatLatLng(place.gcj)),
                                    );
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('坐标已复制')),
                                    );
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(value: 'rename', child: Text('重命名')),
                                  PopupMenuItem(value: 'copy', child: Text('复制坐标')),
                                  PopupMenuItem(value: 'delete', child: Text('删除')),
                                ],
                              ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                widget.onSaveCurrent();
              },
              icon: const Icon(Icons.add_location_alt_outlined),
              label: const Text('把当前选点存为常用地点'),
            ),
          ),
          if (_showRecents && _recents.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                await widget.onClearRecents();
                if (mounted) setState(() => _recents = <SavedPlace>[]);
              },
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('清空最近记录'),
            ),
        ],
      ),
    );
  }
}

/// 精调面板：用方向键按米微调目标点，避免地图点击误差。
class NudgeSheet extends StatefulWidget {
  const NudgeSheet({
    super.key,
    required this.target,
    required this.onChanged,
  });

  final LatLng target;
  final ValueChanged<LatLng> onChanged;

  @override
  State<NudgeSheet> createState() => _NudgeSheetState();
}

class _NudgeSheetState extends State<NudgeSheet> {
  late LatLng _point = widget.target;
  double _step = 1;

  void _move({double north = 0, double east = 0}) {
    setState(() {
      _point = Coord.offsetMeters(_point, north: north, east: east);
    });
    widget.onChanged(_point);
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('微调位置', style: theme.textTheme.titleMedium),
              const Spacer(),
              SegmentedButton<double>(
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 1, label: Text('1米')),
                  ButtonSegment(value: 10, label: Text('10米')),
                  ButtonSegment(value: 100, label: Text('100米')),
                ],
                selected: {_step},
                onSelectionChanged: (v) => setState(() => _step = v.first),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Text(
                  formatLatLng(_point),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'WGS-84 ${formatLatLng(Coord.gcjToWgs(_point))}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 220,
            height: 220,
            child: Stack(
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: _NudgeButton(
                    icon: Icons.keyboard_arrow_up,
                    onTap: () => _move(north: _step),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _NudgeButton(
                    icon: Icons.keyboard_arrow_down,
                    onTap: () => _move(north: -_step),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _NudgeButton(
                    icon: Icons.keyboard_arrow_left,
                    onTap: () => _move(east: -_step),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: _NudgeButton(
                    icon: Icons.keyboard_arrow_right,
                    onTap: () => _move(east: _step),
                  ),
                ),
                Center(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.my_location,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Text(
            '每次点击移动 $_step 米，地图上的绿点会同步更新。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 56,
          height: 56,
          child: Icon(icon, size: 28),
        ),
      ),
    );
  }
}

/// 设置面板：搜索源、底图、坐标显示、更新与帮助。
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.config,
    required this.versionName,
    required this.availableUpdate,
    required this.updateChecked,
    required this.checkingUpdate,
    required this.updateBusy,
    required this.onConfigChanged,
    required this.onCheckUpdate,
    required this.onInstallUpdate,
    required this.onOpenUrl,
    required this.storage,
  });

  final AppConfig config;
  final String versionName;
  final AppUpdate? availableUpdate;
  final bool updateChecked;
  final bool checkingUpdate;
  final bool updateBusy;
  final Future<void> Function(AppConfig) onConfigChanged;
  final Future<AppUpdate?> Function() onCheckUpdate;
  final Future<void> Function(AppUpdate) onInstallUpdate;
  final Future<void> Function(String url) onOpenUrl;
  final AppStorage storage;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late final TextEditingController _keyController =
      TextEditingController(text: widget.config.amapKey);
  late final AppConfig _config = widget.config.copy();

  Future<void> _apply() async {
    await widget.onConfigChanged(_config);
  }

  // 更新状态放在面板内部：这是独立路由，首页 setState 不会重建这里，
  // 反馈（转圈、结果、失败原因）必须就地显示，否则点了像没反应。
  late AppUpdate? _available = widget.availableUpdate;
  late bool _checked = widget.updateChecked;
  bool _checking = false;
  bool _busy = false;
  String? _updateError;

  Future<void> _checkUpdate() async {
    if (_checking || _busy) return;
    setState(() {
      _checking = true;
      _updateError = null;
    });
    try {
      final latest = await widget.onCheckUpdate();
      if (!mounted) return;
      setState(() {
        _available = latest;
        _checked = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _updateError = _updateMessage(e));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _install(AppUpdate update) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _updateError = null;
    });
    try {
      await widget.onInstallUpdate(update);
    } catch (e) {
      if (!mounted) return;
      setState(() => _updateError = _updateMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _updateMessage(Object error) {
    final text = error is PlatformException
        ? (error.message ?? error.code)
        : '$error';
    return text.replaceFirst('Exception: ', '');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 把常用地点、路线和设置导出成一段 JSON 文本，放进剪贴板。
  Future<void> _exportData() async {
    final data = <String, Object?>{
      'app': 'fake_location',
      'version': 1,
      'favorites': widget.storage.readFavorites().map((e) => e.toJson()).toList(),
      'routes': widget.storage.readRoutes().map((e) => e.toJson()).toList(),
      'config': <String, Object?>{
        'amapKey': _config.amapKey,
        'mapStyle': _config.mapStyle.name,
        'coordSystem': _config.coordSystem.name,
        'showRadius': _config.showRadius,
        'radiusMeters': _config.radiusMeters,
        'writeGcj': _config.writeGcj,
        'intervalMs': _config.intervalMs,
        'accuracyMeters': _config.accuracyMeters,
        'floatBar': _config.floatBar,
        'motion': _config.motion.name,
        'stepFreq': _config.stepFreq,
        'stepLength': _config.stepLength,
      },
    };
    await Clipboard.setData(ClipboardData(text: jsonEncode(data)));
    _toast('已复制到剪贴板，粘贴到记事本保存即可');
  }

  /// 从剪贴板恢复备份，只接受本应用导出的格式。
  Future<void> _importData() async {
    final raw = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (raw == null || raw.trim().isEmpty) {
      _toast('剪贴板里没有内容');
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['app'] != 'fake_location') {
        _toast('这段文本不是本应用的备份');
        return;
      }
      final favorites = decoded['favorites'];
      if (favorites is List) {
        final list = favorites
            .map(SavedPlace.tryFromJson)
            .whereType<SavedPlace>()
            .toList();
        await widget.storage.writeFavorites(list);
      }
      final routes = decoded['routes'];
      if (routes is List) {
        final list = routes.map(RoutePlan.tryFromJson).whereType<RoutePlan>().toList();
        await widget.storage.writeRoutes(list);
      }
      final config = decoded['config'];
      if (config is Map) {
        _config
          ..amapKey = config['amapKey'] is String ? config['amapKey'] as String : _config.amapKey
          ..showRadius = config['showRadius'] is bool ? config['showRadius'] as bool : _config.showRadius
          ..writeGcj = config['writeGcj'] is bool ? config['writeGcj'] as bool : _config.writeGcj
          ..floatBar = config['floatBar'] is bool ? config['floatBar'] as bool : _config.floatBar;
        if (config['mapStyle'] is String) {
          _config.mapStyle = MapStyle.values.firstWhere(
            (e) => e.name == config['mapStyle'],
            orElse: () => _config.mapStyle,
          );
        }
        if (config['coordSystem'] is String) {
          _config.coordSystem = CoordSystem.values.firstWhere(
            (e) => e.name == config['coordSystem'],
            orElse: () => _config.coordSystem,
          );
        }
        if (config['motion'] is String) {
          _config.motion = MotionMode.values.firstWhere(
            (e) => e.name == config['motion'],
            orElse: () => _config.motion,
          );
        }
        if (config['intervalMs'] is num) {
          _config.intervalMs = (config['intervalMs'] as num).toInt();
        }
        if (config['accuracyMeters'] is num) {
          _config.accuracyMeters = (config['accuracyMeters'] as num).toDouble();
        }
        if (config['radiusMeters'] is num) {
          _config.radiusMeters = (config['radiusMeters'] as num).toDouble();
        }
        if (config['stepFreq'] is num) {
          _config.stepFreq = (config['stepFreq'] as num).toDouble();
        }
        if (config['stepLength'] is num) {
          _config.stepLength = (config['stepLength'] as num).toDouble();
        }
        _keyController.text = _config.amapKey;
        await _apply();
      }
      if (!mounted) return;
      setState(() {});
      _toast('导入完成');
    } catch (_) {
      _toast('导入失败：内容不是合法的备份文本');
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        children: [
          Text('设置', style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          Text('地图', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<MapStyle>(
            showSelectedIcon: false,
            segments: MapStyle.values
                .map((e) => ButtonSegment(value: e, label: Text(e.label)))
                .toList(),
            selected: {_config.mapStyle},
            onSelectionChanged: (v) {
              setState(() => _config.mapStyle = v.first);
              _apply();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('显示签到范围圈'),
            subtitle: Text('以目标点为圆心画 ${_config.radiusMeters.round()} 米圆，便于判断是否在范围内'),
            value: _config.showRadius,
            onChanged: (v) {
              setState(() => _config.showRadius = v);
              _apply();
            },
          ),
          if (_config.showRadius)
            Wrap(
              spacing: 8,
              children: [100.0, 200.0, 500.0]
                  .map(
                    (r) => ChoiceChip(
                      label: Text('${r.round()} 米'),
                      selected: _config.radiusMeters == r,
                      onSelected: (_) {
                        setState(() => _config.radiusMeters = r);
                        _apply();
                      },
                    ),
                  )
                  .toList(),
            ),
          const Divider(height: 28),
          Text('坐标显示', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<CoordSystem>(
            showSelectedIcon: false,
            segments: CoordSystem.values
                .map((e) => ButtonSegment(value: e, label: Text(e.label)))
                .toList(),
            selected: {_config.coordSystem},
            onSelectionChanged: (v) {
              setState(() => _config.coordSystem = v.first);
              _apply();
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '这里只影响界面显示；写入系统的坐标由下面的选项决定。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 28),
          Text('写入系统坐标', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('WGS-84（默认）')),
              ButtonSegment(value: true, label: Text('GCJ-02')),
            ],
            selected: {_config.writeGcj},
            onSelectionChanged: (v) {
              setState(() => _config.writeGcj = v.first);
              _apply();
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '模拟后在其它应用里若看到约 500 米偏移，切换为 GCJ-02 再试。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 28),
          Text('模拟参数', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text('位置更新频率', style: theme.textTheme.bodyMedium),
              ),
              Text(
                '${_config.intervalMs} 毫秒',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [100, 200, 500, 1000]
                .map(
                  (ms) => ChoiceChip(
                    label: Text('$ms'),
                    selected: _config.intervalMs == ms,
                    onSelected: (_) {
                      setState(() => _config.intervalMs = ms);
                      _apply();
                    },
                  ),
                )
                .toList(),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 10),
            child: Text(
              '微信、运动类应用建议 100~200 毫秒，普通场景 500 即可；越小越费电。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text('模拟精度', style: theme.textTheme.bodyMedium),
              ),
              Text(
                '±${_config.accuracyMeters.round()} 米',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [3.0, 5.0, 10.0, 20.0]
                .map(
                  (m) => ChoiceChip(
                    label: Text('${m.round()} 米'),
                    selected: _config.accuracyMeters == m,
                    onSelected: (_) {
                      setState(() => _config.accuracyMeters = m);
                      _apply();
                    },
                  ),
                )
                .toList(),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '精度越小，其它应用越相信这是 GPS 定位；设得太大时会退化成“大致位置”。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('悬浮控制条'),
            subtitle: const Text('在其它应用上显示模拟状态，可直接暂停或回到真实位置'),
            value: _config.floatBar,
            onChanged: (v) {
              setState(() => _config.floatBar = v);
              _apply();
            },
          ),
          const Divider(height: 28),
          Row(
            children: [
              Text('地点搜索', style: theme.textTheme.labelLarge),
              const Spacer(),
              TextButton.icon(
                onPressed: () => widget.onOpenUrl(
                  'https://console.amap.com/dev/key/app',
                ),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('获取 Key'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _keyController,
            decoration: const InputDecoration(
              hintText: '粘贴高德 Web 服务 Key（可选）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => _config.amapKey = v.trim(),
            onSubmitted: (_) => _apply(),
          ),
          const SizedBox(height: 8),
          Text(
            '填写后搜索将直接使用高德数据（POI 更全、坐标与高德地图完全一致），'
            '并支持高德逆地理。留空时自动使用百度地图网页数据，再由 OSM 兜底。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Row(
            children: [
              TextButton(
                onPressed: () async {
                  _keyController.clear();
                  _config.amapKey = '';
                  await _apply();
                },
                child: const Text('清除 Key'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () async {
                  await _apply();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('设置已保存')),
                    );
                  }
                },
                child: const Text('保存'),
              ),
            ],
          ),
          const Divider(height: 28),
          Text('数据备份', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Row(
            children: [
              TextButton.icon(
                onPressed: _exportData,
                icon: const Icon(Icons.upload_file_outlined, size: 16),
                label: const Text('导出到剪贴板'),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _importData,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('从剪贴板导入'),
              ),
            ],
          ),
          Text(
            '包含常用地点、保存的路线和全部设置；换机时导出这段文本，在新手机上导入即可恢复。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: 28),
          Text('需要 Root 的功能', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Text(
            'WiFi 模拟、基站模拟、独立模拟（只对某个应用生效）、反检测和 Root 隐藏，'
            '都需要系统级权限（Root / Xposed）才能实现。本应用走免 Root 方案，'
            '这些开关即使做出来也不会真正生效，所以没有提供。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
          const Divider(height: 28),
          Text('关于', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: Text(
              widget.versionName.isEmpty ? '虚拟定位' : '虚拟定位 ${widget.versionName}',
            ),
            subtitle: Text(
              _busy
                  ? '正在下载安装包…'
                  : _checking
                  ? '正在检查…'
                  : _available != null
                  ? '发现新版本 ${_available!.versionName}'
                  : _checked
                  ? '已是最新版本'
                  : '尚未检查更新',
            ),
            trailing: _checking || _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: () {
                      if (_available != null) {
                        _install(_available!);
                      } else {
                        _checkUpdate();
                      }
                    },
                    child: Text(_available == null ? '检查更新' : '立即更新'),
                  ),
          ),
          if (_updateError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 40),
              child: Text(
                '更新失败：$_updateError',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFFD93025),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('使用提示', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                Text(
                  '· 需要在开发者选项里把“选择模拟位置信息应用”设为“虚拟定位”。\n'
                  '· 微信等应用会缓存定位，修改目标后建议退出并重新进入对应页面。\n'
                  '· 室内信号差时定位精度可能只有几十米，可在微调面板手动校正。',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              '坐标转换：WGS-84 ↔ GCJ-02 ↔ BD-09',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「模拟是否生效」检测面板：直接对比服务推送状态与系统读回的位置。
class MockCheckSheet extends StatefulWidget {
  const MockCheckSheet({
    super.key,
    required this.loadReport,
    required this.targetWgs,
    required this.onRetryPush,
    required this.onOpenExternalApp,
  });

  final Future<MockReport?> Function() loadReport;
  final LatLng targetWgs;
  final VoidCallback onRetryPush;
  final Future<void> Function(String package) onOpenExternalApp;

  @override
  State<MockCheckSheet> createState() => _MockCheckSheetState();
}

class _MockCheckSheetState extends State<MockCheckSheet> {
  MockReport? _report;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await widget.loadReport();
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = _report;
    final distance = report?.distanceTo(widget.targetWgs);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('检测模拟是否生效', style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(
                tooltip: '重新检测',
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Text('检测失败：$_error', style: theme.textTheme.bodySmall)
          else if (report != null) ...[
            _verdict(theme, report, distance),
            const SizedBox(height: 12),
            _row(theme, '模拟服务',
                report.serviceRunning ? '运行中' : '未运行',
                ok: report.serviceRunning),
            _row(
              theme,
              '坐标推送',
              report.pushCount == 0
                  ? '尚未推送'
                  : '已推送 ${report.pushCount} 次'
                        '${report.elapsedMs >= 0 ? '，${(report.elapsedMs / 1000).toStringAsFixed(1)} 秒前' : ''}',
              ok: report.pushCount > 0 && report.elapsedMs >= 0 && report.elapsedMs < 5000,
            ),
            _row(
              theme,
              '接管的定位源',
              report.providers.isEmpty ? '无（可能未获授权）' : report.providers.join(' / '),
              ok: report.providers.isNotEmpty,
            ),
            _row(
              theme,
              '系统读回位置',
              report.systemWgs == null
                  ? '读取失败'
                  : '${report.serviceRunning ? '' : '上次 '}'
                        '${formatLatLng(report.systemWgs!, digits: 5)}'
                        '${report.systemAccuracy == null ? '' : ' ±${report.systemAccuracy!.round()} 米'}',
              ok: report.systemWgs != null && report.serviceRunning,
            ),
            _row(
              theme,
              '系统标记',
              report.systemIsMock ? '模拟定位（mock）' : '普通真实定位',
              ok: report.systemIsMock && report.serviceRunning,
            ),
            if (distance != null)
              _row(theme, '与目标偏差', formatDistance(distance), ok: distance < 50),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      widget.onRetryPush();
                      Future<void>.delayed(
                        const Duration(milliseconds: 800),
                        _refresh,
                      );
                    },
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: const Text('重新推送'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      await widget.onOpenExternalApp('com.autonavi.minimap');
                    },
                    icon: const Icon(Icons.map_outlined, size: 18),
                    label: const Text('打开高德'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '系统读回 mock 且偏差很小时，说明坐标已经全局生效。\n'
              '如果高德仍显示原位，按顺序排查：\n'
              '① 打开高德后点一下右下角“定位”按钮——地图不会自动跟随；\n'
              '② 系统设置 → 应用 → 高德 → 权限 → 位置，改成“精确位置”；\n'
              '③ 从最近任务里划掉高德，重新打开；\n'
              '④ 临时关掉 WiFi。高德/微信会用自己的 SDK 读 WiFi 热点指纹算位置，'
              '刷新时会盖掉模拟值——典型表现就是“刚开始对，刷新一下又回原地”。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFE8710A).withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: const Color(0xFFE8710A).withValues(alpha: 0.24),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.shield_outlined,
                        size: 16,
                        color: Color(0xFFE8710A),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '其它应用能不能识破',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: const Color(0xFFE8710A),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '系统投递这个位置时会打上“模拟”标记（FLAG_MOCK），'
                    '任何有定位权限的应用一行代码就能读到，免 root 去不掉。'
                    '实测两个常见应用：\n'
                    '· 飞书：内置高德定位 SDK，会读这个标记；\n'
                    '· 微信：读的是 Android 6 以前的旧开关，现代系统上通常读不到。\n'
                    '钉钉这类强风控应用另有策略，无法保证。'
                    '要去掉标记只能用 root + LSPosed，或把目标应用装进容器里运行。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _verdict(ThemeData theme, MockReport report, double? distance) {
    final Color color;
    final IconData icon;
    final String title;
    final String detail;

    if (!report.mockAppSelected) {
      color = const Color(0xFFD93025);
      icon = Icons.error_outline;
      title = '未设为模拟位置应用';
      detail = '开发者选项 →“选择模拟位置信息应用”→ 选择“虚拟定位”，再点开始模拟。';
    } else if (!report.serviceRunning || report.pushCount == 0) {
      color = const Color(0xFFD93025);
      icon = Icons.error_outline;
      title = '模拟服务没有在推送';
      detail = '可能被系统清理了，点下面“重新推送”，并在电池设置里允许后台运行。';
    } else if (!report.systemIsMock) {
      color = const Color(0xFFE8710A);
      icon = Icons.warning_amber_rounded;
      title = '系统仍返回真实定位';
      detail = '测试源可能被 ROM 拦截；请确认开发者选项里的模拟位置应用，并尝试重启手机后再开始。';
    } else if (distance != null && distance > 50) {
      color = const Color(0xFFE8710A);
      icon = Icons.warning_amber_rounded;
      title = '系统位置与目标不一致';
      detail = '系统返回的位置与目标相差 ${formatDistance(distance)}，请点“重新推送”再检测。';
    } else {
      color = const Color(0xFF17B978);
      icon = Icons.check_circle_outline;
      title = '已生效，全局位置已改到目标点';
      detail = '其它应用还显示原位时：先点它右下角的“定位”按钮刷新，或从最近任务划掉重开。';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(color: color),
                ),
                const SizedBox(height: 2),
                Text(detail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    ThemeData theme,
    String label,
    String value, {
    required bool ok,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: ok
                    ? theme.colorScheme.onSurface
                    : const Color(0xFFD93025),
                fontWeight: ok ? FontWeight.w500 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
