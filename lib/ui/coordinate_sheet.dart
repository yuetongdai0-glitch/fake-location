import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../core/coord.dart';
import '../core/coordinate_input.dart';

/// 坐标输入面板：有些地点搜不到时，直接填经纬度最稳。
///
/// 支持十进制、度分秒、带 N/S/E/W 的写法，也支持整串粘贴和 geo: 链接。
class CoordinateSheet extends StatefulWidget {
  const CoordinateSheet({
    super.key,
    required this.initial,
    required this.onPick,
    this.resolveAddress,
  });

  /// 打开面板时的目标点（GCJ-02），用于「用当前中心填入」。
  final LatLng initial;

  /// 确认后回调，参数是换算好的 GCJ-02 坐标。
  final void Function(LatLng gcj) onPick;

  /// 可选：解析地址，传入 GCJ 坐标返回文字。
  final Future<String?> Function(LatLng gcj)? resolveAddress;

  @override
  State<CoordinateSheet> createState() => _CoordinateSheetState();
}

class _CoordinateSheetState extends State<CoordinateSheet> {
  final TextEditingController _latCtrl = TextEditingController();
  final TextEditingController _lngCtrl = TextEditingController();
  final FocusNode _latFocus = FocusNode();

  CoordSystem _system = CoordSystem.gcj;
  CoordinateReading? _reading;
  String? _error;
  String? _address;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    // 预填当前目标点，方便在此基础上微调
    final display = _system.fromGcj(widget.initial);
    _latCtrl.text = display.latitude.toStringAsFixed(6);
    _lngCtrl.text = display.longitude.toStringAsFixed(6);
    _reparse();
  }

  @override
  void dispose() {
    _latCtrl.dispose();
    _lngCtrl.dispose();
    _latFocus.dispose();
    super.dispose();
  }

  /// 把两个输入框拼起来解析；某个框里粘了整串坐标时自动拆成两半。
  void _reparse() {
    final latText = _latCtrl.text.trim();
    final lngText = _lngCtrl.text.trim();
    if (latText.isEmpty && lngText.isEmpty) {
      setState(() {
        _reading = null;
        _error = null;
      });
      return;
    }
    // 单个框里带逗号或度分秒符号，说明用户粘的是整串
    final combined = (lngText.isEmpty || latText.contains(RegExp(r'[,;°]')))
        ? (lngText.isEmpty ? latText : '$latText,$lngText')
        : '$latText,$lngText';
    final withSystem = '${_system.name == 'bd09' ? 'bd' : _system.name}: $combined';
    final reading = CoordinateInput.parse(withSystem);
    setState(() {
      _reading = reading;
      _error = reading == null ? '格式无法识别，试试 39.908722, 116.397499' : null;
      _address = null;
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    final reading = CoordinateInput.parse(text);
    if (reading == null) {
      setState(() => _error = '剪贴板里的内容不是坐标');
      return;
    }
    setState(() {
      _system = reading.source;
      _latCtrl.text = reading.latitude.toStringAsFixed(6);
      _lngCtrl.text = reading.longitude.toStringAsFixed(6);
    });
    _reparse();
  }

  void _useCurrent() {
    final display = _system.fromGcj(widget.initial);
    setState(() {
      _latCtrl.text = display.latitude.toStringAsFixed(6);
      _lngCtrl.text = display.longitude.toStringAsFixed(6);
    });
    _reparse();
  }

  Future<void> _resolve() async {
    final reading = _reading;
    final resolver = widget.resolveAddress;
    if (reading == null || resolver == null) return;
    setState(() => _resolving = true);
    final address = await resolver(reading.gcj);
    if (!mounted) return;
    setState(() {
      _address = address;
      _resolving = false;
    });
  }

  void _submit() {
    final reading = _reading;
    if (reading == null) return;
    widget.onPick(reading.gcj);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reading = _reading;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pin_drop_outlined, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text('输入坐标', style: theme.textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                onPressed: _paste,
                icon: const Icon(Icons.content_paste, size: 16),
                label: const Text('粘贴'),
              ),
            ],
          ),
          Text(
            '搜不到的地方直接填经纬度。支持十进制（39.908722, 116.397499）、'
            '度分秒（39°54′31″N 116°23′51″E）、geo: 链接，'
            '也可以用 wgs / gcj / bd 前缀指定坐标系。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _latCtrl,
                  focusNode: _latFocus,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '纬度',
                    hintText: '39.908722',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => _reparse(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _lngCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '经度',
                    hintText: '116.397499',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => _reparse(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '坐标系',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SegmentedButton<CoordSystem>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: CoordSystem.values
                      .map(
                        (e) => ButtonSegment(
                          value: e,
                          label: Text(
                            e.label,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                      .toList(),
                  selected: {_system},
                  onSelectionChanged: (v) {
                    final next = v.first;
                    // 切换坐标系时把当前数值按新坐标系重新表示
                    final reading = _reading;
                    setState(() => _system = next);
                    if (reading != null) {
                      final display = next.fromGcj(reading.gcj);
                      _latCtrl.text = display.latitude.toStringAsFixed(6);
                      _lngCtrl.text = display.longitude.toStringAsFixed(6);
                      _reparse();
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_error != null)
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFFD93025),
              ),
            )
          else if (reading != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.primary.withValues(alpha: 0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.check_circle_outline, size: 16, color: scheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        '已识别（按 ${reading.sourceLabel} 解释）',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _row(theme, 'GCJ-02 地图', formatLatLng(reading.gcj)),
                  _row(
                    theme,
                    'WGS-84 系统',
                    formatLatLng(Coord.gcjToWgs(reading.gcj)),
                  ),
                  _row(
                    theme,
                    'BD-09 百度',
                    formatLatLng(Coord.gcjToBd09(reading.gcj)),
                  ),
                  if (_address != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _address!,
                      style: theme.textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                onPressed: _useCurrent,
                icon: const Icon(Icons.my_location, size: 16),
                label: const Text('用当前目标'),
              ),
              TextButton.icon(
                onPressed: _resolving || reading == null ? null : _resolve,
                icon: _resolving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.place_outlined, size: 16),
                label: const Text('查地址'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: reading == null ? null : _submit,
                icon: const Icon(Icons.near_me, size: 18),
                label: const Text('定位到这里'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
