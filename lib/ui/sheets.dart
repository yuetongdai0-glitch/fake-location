import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../core/app_update.dart';
import '../core/backup_data.dart';
import '../core/coord.dart';
import '../core/models.dart';
import '../core/storage.dart';
import '../core/user_message.dart';

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
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  late List<SavedPlace> _favorites = List.of(widget.favorites);
  late List<SavedPlace> _recents = List.of(widget.recents);

  /// 搜索只读取当前列表；按名称、地址和坐标分词匹配，不请求网络。
  List<SavedPlace> get _items {
    final all = _showRecents ? _recents : _favorites;
    final words = _query
        .trim()
        .toLowerCase()
        .split(RegExp(r'[\s,，]+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return all;
    return all.where((place) {
      final text = '${place.name} ${place.address} ${formatLatLng(place.gcj)}'
          .toLowerCase();
      return words.every(text.contains);
    }).toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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
    if (result == null || result.isEmpty || result == place.name) return;
    try {
      await widget.onRename(place, result);
    } catch (error) {
      _showSaveError(error, '重命名失败，请重试');
      return;
    }
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
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.onDelete(place);
    } catch (error) {
      _showSaveError(error, '删除失败，请重试');
      return;
    }
    if (!mounted) return;
    setState(() {
      _favorites = _favorites.where((e) => e.id != place.id).toList();
      _recents = _recents.where((e) => e.id != place.id).toList();
    });
  }

  /// 保存失败时保留当前筛选和原记录，避免界面显示成功但重新打开又恢复。
  void _showSaveError(Object error, String fallback) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(userMessage(error, fallback: fallback))),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text('我的地点', style: theme.textTheme.titleMedium),
                const Spacer(),
                SegmentedButton<bool>(
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('常用')),
                    ButtonSegment(value: true, label: Text('最近')),
                  ],
                  selected: {_showRecents},
                  onSelectionChanged: (v) =>
                      setState(() => _showRecents = v.first),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索名称、地址或坐标',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空地点搜索',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          _searchController.clear();
                          _query = '';
                        }),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: items.isEmpty
                  ? SizedBox(
                      height: 150,
                      child: Center(
                        child: Text(
                          _query.trim().isNotEmpty
                              ? '没有找到匹配的地点，试试名称、地址或坐标。'
                              : _showRecents
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
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final place = items[index];
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
                                    if (value == 'rename') {
                                      _rename(place);
                                    }
                                    if (value == 'delete') {
                                      _confirmDelete(place);
                                    }
                                    if (value == 'copy') {
                                      Clipboard.setData(
                                        ClipboardData(
                                          text: formatLatLng(place.gcj),
                                        ),
                                      );
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(content: Text('坐标已复制')),
                                      );
                                    }
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: 'rename',
                                      child: Text('重命名'),
                                    ),
                                    PopupMenuItem(
                                      value: 'copy',
                                      child: Text('复制坐标'),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text('删除'),
                                    ),
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
      ),
    );
  }
}

/// 精调面板：用方向键按米微调目标点，避免地图点击误差。
class NudgeSheet extends StatefulWidget {
  const NudgeSheet({super.key, required this.target, required this.onChanged});

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
        child: SizedBox(width: 56, height: 56, child: Icon(icon, size: 28)),
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
  late final TextEditingController _keyController = TextEditingController(
    text: widget.config.amapKey,
  );
  late AppConfig _config = widget.config.copy();
  bool _importing = false;

  Future<void> _apply() async {
    try {
      await widget.onConfigChanged(_config);
    } catch (error) {
      if (!mounted) return;
      setState(() => _config = widget.config.copy());
      _keyController.text = _config.amapKey;
      _toast(userMessage(error, fallback: '设置保存失败，请重试'));
    }
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

  /// 更新失败只显示中文说明，不暴露底层异常或系统堆栈。
  String _updateMessage(Object error) =>
      userMessage(error, fallback: '更新失败，请稍后重试');

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 把常用地点、路线和设置导出成一段 JSON 文本，放进剪贴板。
  Future<void> _exportData() async {
    try {
      final data = <String, Object?>{
        'app': 'fake_location',
        'version': 1,
        'favorites': widget.storage
            .readFavorites()
            .map((e) => e.toJson())
            .toList(),
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
    } catch (error) {
      _toast(userMessage(error, fallback: '导出失败，无法写入剪贴板'));
    }
  }

  /// 整份预检通过后才写入；保存失败时尽量恢复导入前快照，避免部分覆盖。
  Future<void> _importData() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final raw = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (raw == null || raw.trim().isEmpty) {
        _toast('剪贴板里没有内容');
        return;
      }
      final backup = BackupData.parse(raw, baseline: _config);
      final oldFavorites = widget.storage.readFavorites();
      final oldRoutes = widget.storage.readRoutes();
      final oldStoredConfig = widget.storage.readConfig();
      final oldConfig = _config.copy();
      try {
        await widget.storage.writeFavorites(backup.favorites);
        await widget.storage.writeRoutes(backup.routes);
        await widget.storage.writeConfig(backup.config);
        await widget.onConfigChanged(backup.config);
      } catch (_) {
        // 不把半份备份当作成功；每项独立恢复，某项失败也继续恢复其余数据。
        var restored = true;
        for (final restore in <Future<void> Function()>[
          () => widget.storage.writeFavorites(oldFavorites),
          () => widget.storage.writeRoutes(oldRoutes),
          () => widget.onConfigChanged(oldConfig),
          () => widget.storage.writeConfig(oldStoredConfig),
        ]) {
          try {
            await restore();
          } catch (_) {
            restored = false;
          }
        }
        _config = oldConfig;
        if (mounted) _keyController.text = oldConfig.amapKey;
        throw FormatException(
          restored ? '导入失败，已恢复原有数据' : '导入失败，部分原有数据未能恢复，请检查本地数据',
        );
      }
      _config = backup.config;
      if (!mounted) return;
      _keyController.text = _config.amapKey;
      setState(() {});
      _toast('导入完成');
    } catch (error) {
      _toast(userMessage(error, fallback: '导入失败，无法读取或保存备份'));
    } finally {
      if (mounted) setState(() => _importing = false);
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
            subtitle: Text(
              '以目标点为圆心画 ${_config.radiusMeters.round()} 米圆，便于判断是否在范围内',
            ),
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
              Expanded(child: Text('模拟精度', style: theme.textTheme.bodyMedium)),
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
              '精度越小，其它应用越相信这是卫星定位；设得太大时会退化成“大致位置”。',
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
                onPressed: () =>
                    widget.onOpenUrl('https://console.amap.com/dev/key/app'),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('获取密钥'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _keyController,
            decoration: const InputDecoration(
              hintText: '粘贴高德网络服务密钥（可选）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => _config.amapKey = v.trim(),
            onSubmitted: (_) => _apply(),
          ),
          const SizedBox(height: 8),
          Text(
            '填写后搜索将直接使用高德数据（地点更全、坐标与高德地图完全一致），'
            '并支持高德逆地理。留空时自动使用百度地图网页数据，再由开放地图兜底。',
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
                child: const Text('清除密钥'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () async {
                  await _apply();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('设置已保存')));
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
                onPressed: _importing ? null : _exportData,
                icon: const Icon(Icons.upload_file_outlined, size: 16),
                label: const Text('导出到剪贴板'),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _importing ? null : _importData,
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
          Text('需要系统提权的功能', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Text(
            '无线网络 模拟、基站模拟、独立模拟（只对某个应用生效）、反检测和 系统提权隐藏，'
            '都需要系统级权限（系统提权或系统扩展框架）才能实现。本应用走免系统提权方案，'
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
              widget.versionName.isEmpty
                  ? '虚拟定位'
                  : '虚拟定位 ${widget.versionName}',
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
    this.onOpenAppSettings,
  });

  final Future<MockReport?> Function() loadReport;
  final LatLng targetWgs;
  final Future<void> Function() onRetryPush;
  final Future<void> Function(String package) onOpenExternalApp;
  final Future<void> Function()? onOpenAppSettings;

  @override
  State<MockCheckSheet> createState() => _MockCheckSheetState();
}

class _MockCheckSheetState extends State<MockCheckSheet> {
  MockReport? _report;
  bool _loading = true;
  bool _retrying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await widget.loadReport();
      if (!mounted) return;
      setState(() {
        _report = report;
        _error = report == null ? '未取得服务状态，请重试' : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userMessage(e, fallback: '未能读取定位状态，请重试');
        _loading = false;
      });
    }
  }

  /// 等待推送完成后再读取，避免重复点击及关闭面板后异步刷新。
  Future<void> _retryPush() async {
    setState(() => _retrying = true);
    try {
      await widget.onRetryPush();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (mounted) await _refresh();
    } catch (e) {
      if (mounted) {
        setState(() => _error = userMessage(e, fallback: '重新推送失败，请重试'));
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = _report;
    final target = report == null ? widget.targetWgs : _checkedTarget(report);
    final distance = report?.distanceTo(target);

    return SingleChildScrollView(
      child: Padding(
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
              _verdict(theme, report),
              const SizedBox(height: 12),
              if (report.serviceRunning && report.pushedWgs != null)
                _row(
                  theme,
                  '正在模拟的坐标',
                  formatLatLng(report.pushedWgs!, digits: 6),
                  ok: true,
                ),
              _row(
                theme,
                '模拟服务',
                report.serviceRunning ? '运行中' : '未运行',
                ok: report.serviceRunning,
              ),
              _row(
                theme,
                '坐标推送',
                report.pushCount == 0
                    ? '尚未推送'
                    : '已推送 ${report.pushCount} 次'
                          '${report.elapsedMs >= 0 ? '，${(report.elapsedMs / 1000).toStringAsFixed(1)} 秒前' : ''}',
                ok:
                    report.pushCount > 0 &&
                    report.elapsedMs >= 0 &&
                    report.elapsedMs < 5000,
              ),
              _row(
                theme,
                '接管的定位源',
                report.providers.isEmpty
                    ? '无（可能未获授权）'
                    : report.providers.map(_providerName).join(' / '),
                ok: report.hasFullCoverage,
              ),
              for (final provider in report.providerLocations)
                _row(
                  theme,
                  '${_providerName(provider.provider)}读回',
                  (provider.error == null
                          ? null
                          : userMessage(
                              Exception(provider.error),
                              fallback: '暂时无法读取此定位源',
                            )) ??
                      (provider.point == null
                          ? '暂无缓存，尚未确认'
                          : '${provider.isMock ? '模拟' : '真实'} · '
                                '${formatDistance(Coord.distanceMeters(target, provider.point!))} 偏差 · '
                                '${(provider.ageMs / 1000).toStringAsFixed(1)} 秒前'),
                  ok: provider.matchesTarget(target),
                ),
              for (final error in report.providerErrors.entries)
                _row(
                  theme,
                  '${_providerName(error.key)}推送',
                  userMessage(Exception(error.value), fallback: '定位源推送失败，请重试'),
                  ok: false,
                ),
              _row(
                theme,
                '无线网络与扫描',
                '${report.wifiEnabled ? '无线网络已开启' : '无线网络已关闭'} · '
                    '${report.wifiScanEnabled ? '后台扫描已开启' : '后台扫描已关闭'}',
                ok: true,
              ),
              _row(
                theme,
                '电池优化',
                report.ignoringBatteryOptimizations == null
                    ? '暂时无法读取'
                    : report.ignoringBatteryOptimizations!
                    ? '已允许不受电池优化限制'
                    : '仍受系统电池优化限制',
                ok: report.ignoringBatteryOptimizations,
              ),
              _row(
                theme,
                '省电模式',
                report.powerSaveMode == null
                    ? '暂时无法读取'
                    : report.powerSaveMode!
                    ? '已开启，可能降低后台更新频率'
                    : '未开启',
                ok: report.powerSaveMode == null
                    ? null
                    : !report.powerSaveMode!,
              ),
              _row(
                theme,
                '后台运行限制',
                report.backgroundRestricted == null
                    ? '当前系统未提供此状态'
                    : report.backgroundRestricted!
                    ? '系统已限制本应用后台运行'
                    : '系统未限制本应用后台运行',
                ok: report.backgroundRestricted == null
                    ? null
                    : !report.backgroundRestricted!,
              ),
              for (final error in report.powerErrors.values)
                _row(
                  theme,
                  '后台状态读取',
                  userMessage(Exception(error), fallback: '暂时无法读取后台限制'),
                  ok: null,
                ),
              if (widget.onOpenAppSettings != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: widget.onOpenAppSettings,
                    icon: const Icon(Icons.battery_saver_outlined, size: 18),
                    label: const Text('检查后台运行设置'),
                  ),
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
                report.systemIsMock ? '模拟定位' : '普通真实定位',
                ok: report.systemIsMock && report.serviceRunning,
              ),
              if (distance != null)
                _row(
                  theme,
                  '与目标偏差',
                  formatDistance(distance),
                  ok: distance < 50,
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _retrying || _loading ? null : _retryPush,
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
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => widget.onOpenExternalApp('com.tencent.mm'),
                  icon: const Icon(Icons.chat_outlined, size: 18),
                  label: const Text('打开微信'),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '逐个定位源显示近期模拟坐标且偏差在 50 米内，才表示系统位置校验通过。\n'
                '微信、高德可能结合无线网络、基站或自己的缓存计算位置；系统校验通过不等于每个应用都会采用。\n'
                '若目标应用仍显示原位，可先点击其定位按钮刷新、检查精确位置权限，'
                '再分别关闭无线网络与系统“无线网络扫描”对比。免系统提权方案无法改写热点或基站数据。',
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
                          '应用兼容性说明',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: const Color(0xFFE8710A),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '系统会为模拟位置添加标记，具有定位权限的应用可以识别。'
                      '不同应用可能使用各自的定位和风险判断方式，无法保证都会采用模拟位置。'
                      '免系统提权方案不能去除系统模拟标记。',
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
      ),
    );
  }

  /// 对比服务实际执行的点；地图上新选但未应用的点不能让正常服务被误报为失效。
  LatLng _checkedTarget(MockReport report) => report.serviceRunning
      ? report.pushedWgs ?? widget.targetWgs
      : widget.targetWgs;

  Widget _verdict(ThemeData theme, MockReport report) {
    final Color color;
    final IconData icon;
    final String title;
    final String detail;

    if (!report.mockAppSelected) {
      color = const Color(0xFFD93025);
      icon = Icons.error_outline;
      title = '未设为模拟位置应用';
      detail = '开发者选项 →“选择模拟位置信息应用”→ 选择“虚拟定位”，再点开始模拟。';
    } else if (!report.isPushing) {
      color = const Color(0xFFD93025);
      icon = Icons.error_outline;
      title = '模拟服务没有在推送';
      detail = '可能被系统清理了，点下面“重新推送”，并在电池设置里允许后台运行。';
    } else if (!report.hasFullCoverage) {
      color = const Color(0xFFE8710A);
      icon = Icons.warning_amber_rounded;
      title = '部分定位源尚未接管';
      detail = '不同应用可能使用不同定位源，请检查下方失败原因；服务会自动重试恢复。';
    } else if (!report.isEffective) {
      color = const Color(0xFFE8710A);
      icon = Icons.warning_amber_rounded;
      title = '部分定位源尚未确认';
      detail = '有定位源未读回近期模拟坐标，请重新检测并查看逐源结果。';
    } else if (!report.systemIsMock) {
      color = const Color(0xFFE8710A);
      icon = Icons.warning_amber_rounded;
      title = '系统仍返回真实定位';
      detail = '测试源可能被 系统固件拦截；请确认开发者选项里的模拟位置应用，并尝试重启手机后再开始。';
    } else if (!report.matchesTarget(_checkedTarget(report))) {
      color = const Color(0xFFE8710A);
      icon = Icons.warning_amber_rounded;
      title = '系统位置与目标不一致';
      detail = '至少一个定位源与目标偏差超过 50 米，请点“重新推送”再检测。';
    } else {
      color = const Color(0xFF17B978);
      icon = Icons.check_circle_outline;
      title = '系统定位源校验通过';
      detail = '各系统源均返回目标附近的模拟坐标；目标应用使用独立定位时，请按下方方法对比。';
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

  /// 原生定位源名称只用作内部标识，界面统一显示中文。
  String _providerName(String name) => switch (name) {
    'gps' => '卫星',
    'network' => '网络',
    'fused' => '融合',
    'passive' => '被动',
    _ => '未知来源',
  };

  Widget _row(
    ThemeData theme,
    String label,
    String value, {
    required bool? ok,
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
                color: ok == null
                    ? theme.colorScheme.onSurfaceVariant
                    : ok
                    ? theme.colorScheme.onSurface
                    : const Color(0xFFD93025),
                fontWeight: ok == false ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
