import 'package:flutter/material.dart';

import '../core/models.dart';

/// 路线参数编辑副本：取消或下滑关闭不影响页面，完成才返回新参数。
class RouteSettingsSheet extends StatefulWidget {
  const RouteSettingsSheet({super.key, required this.initial});

  final RoutePlan initial;

  @override
  State<RouteSettingsSheet> createState() => _RouteSettingsSheetState();
}

class _RouteSettingsSheetState extends State<RouteSettingsSheet> {
  late MotionMode _motion = widget.initial.motion;
  late PlayMode _playMode = widget.initial.playMode;
  late double _speed = widget.initial.speed;
  late double _stepFreq = widget.initial.stepFreq;
  late double _stepLength = widget.initial.stepLength;

  double get _effectiveSpeed =>
      _motion.usesSteps ? _stepFreq / 60 * _stepLength : _speed;

  void _complete() => Navigator.pop(
    context,
    RoutePlan(
      points: List.of(widget.initial.points),
      motion: _motion,
      playMode: _playMode,
      speed: _speed,
      stepFreq: _stepFreq,
      stepLength: _stepLength,
      name: widget.initial.name,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('路线设置', style: theme.textTheme.titleLarge),
              const SizedBox(height: 20),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('运动方式', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final mode in MotionMode.values)
                            ChoiceChip(
                              label: Text(mode.label),
                              selected: mode == _motion,
                              showCheckmark: false,
                              onSelected: (_) => setState(() {
                                _motion = mode;
                                if (mode != MotionMode.custom) {
                                  _speed = mode.defaultSpeed;
                                }
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 12,
                        children: [
                          Text('速度', style: theme.textTheme.titleSmall),
                          Text(
                            '${(_effectiveSpeed * 3.6).toStringAsFixed(1)} 公里/小时',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                      if (_motion.usesSteps) ...[
                        const SizedBox(height: 8),
                        _parameter(
                          label: '步频',
                          value: '${_stepFreq.round()} 步/分',
                          current: _stepFreq,
                          min: 40,
                          max: 220,
                          divisions: 36,
                          onChanged: (value) =>
                              setState(() => _stepFreq = value),
                        ),
                        _parameter(
                          label: '步幅',
                          value: '${_stepLength.toStringAsFixed(2)} 米',
                          current: _stepLength,
                          min: 0.3,
                          max: 1.2,
                          divisions: 18,
                          onChanged: (value) => setState(
                            () => _stepLength = double.parse(
                              value.toStringAsFixed(2),
                            ),
                          ),
                        ),
                      ] else
                        Slider(
                          value: _speed.clamp(0.5, 60),
                          min: 0.5,
                          max: 60,
                          divisions: 119,
                          semanticFormatterCallback: (value) =>
                              '${(value * 3.6).toStringAsFixed(1)} 公里/小时',
                          onChanged: (value) => setState(() {
                            _motion = MotionMode.custom;
                            _speed = value;
                          }),
                        ),
                      const SizedBox(height: 16),
                      Text('播放方式', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final mode in PlayMode.values)
                            ChoiceChip(
                              label: Text(mode.label),
                              selected: mode == _playMode,
                              showCheckmark: false,
                              onSelected: (_) =>
                                  setState(() => _playMode = mode),
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _complete,
                      child: const Text('完成'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _parameter({
    required String label,
    required String value,
    required double current,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 12,
        children: [Text(label), Text(value)],
      ),
      Slider(
        value: current.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: value,
        semanticFormatterCallback: (_) => value,
        onChanged: onChanged,
      ),
    ],
  );
}
