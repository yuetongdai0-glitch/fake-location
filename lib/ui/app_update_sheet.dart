import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_update_controller.dart';

/// 更新面板只显示当前阶段和下一步操作，关闭后下载状态仍由控制器保留。
class AppUpdateSheet extends StatefulWidget {
  const AppUpdateSheet({super.key, required this.controller});

  final AppUpdateController controller;

  @override
  State<AppUpdateSheet> createState() => _AppUpdateSheetState();
}

class _AppUpdateSheetState extends State<AppUpdateSheet>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.controller.syncNativeStatus());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.controller.syncNativeStatus());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _check() async {
    try {
      await widget.controller.check(manual: true);
    } catch (_) {
      // 错误已保留在控制器，面板显示一次并保留重试入口。
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final state = widget.controller.state;
      final theme = Theme.of(context);
      final downloading = state.phase == AppUpdatePhase.downloading;
      final verifying = state.phase == AppUpdatePhase.verifying;
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.86,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('应用更新', style: theme.textTheme.titleLarge),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    state.installedVersionName.isEmpty
                        ? state.phase == AppUpdatePhase.error
                              ? '当前版本未知'
                              : '当前版本读取中'
                        : '当前版本 ${state.installedVersionName}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (state.hasUpdate &&
                      state.availableVersionName.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      '新版本 ${state.availableVersionName}',
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (state.phase == AppUpdatePhase.checking || verifying)
                    const LinearProgressIndicator(),
                  if (downloading) ...[
                    Semantics(
                      label: '下载进度',
                      value: state.progress < 0 ? '下载中' : '${state.progress}%',
                      child: LinearProgressIndicator(
                        value: state.progress < 0 ? null : state.progress / 100,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      state.totalBytes > 0
                          ? '${_bytes(state.receivedBytes)} / ${_bytes(state.totalBytes)}'
                                '${state.progress < 0 ? '' : ' · ${state.progress}%'}'
                          : '已下载 ${_bytes(state.receivedBytes)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ] else ...[
                    if (state.phase == AppUpdatePhase.checking || verifying)
                      const SizedBox(height: 10),
                    Text(
                      _phaseLabel(state),
                      key: const ValueKey('app-update-status'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: state.phase == AppUpdatePhase.error
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      TextButton(
                        key: const ValueKey('app-update-check'),
                        onPressed: state.busy ? null : _check,
                        child: const Text('检查更新'),
                      ),
                      if (state.canCancel)
                        OutlinedButton(
                          key: const ValueKey('app-update-cancel'),
                          onPressed: widget.controller.cancel,
                          child: const Text('取消下载'),
                        )
                      else if (state.canInstall)
                        FilledButton(
                          key: const ValueKey('app-update-install'),
                          onPressed: widget.controller.install,
                          child: Text(
                            state.phase == AppUpdatePhase.permission
                                ? '授权并安装'
                                : state.phase == AppUpdatePhase.installing
                                ? '再次安装'
                                : '安装更新',
                          ),
                        )
                      else if (state.hasUpdate && !state.busy)
                        FilledButton(
                          key: const ValueKey('app-update-download'),
                          onPressed: widget.controller.download,
                          child: Text(
                            state.phase == AppUpdatePhase.error ||
                                    state.phase == AppUpdatePhase.cancelled
                                ? '重新下载'
                                : '下载更新',
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
    },
  );
}

String _phaseLabel(AppUpdateState state) => state.error.isNotEmpty
    ? state.error
    : switch (state.phase) {
        AppUpdatePhase.idle => '点击检查更新',
        AppUpdatePhase.checking => '正在检查',
        AppUpdatePhase.current => '已是最新版',
        AppUpdatePhase.available => '可下载更新',
        AppUpdatePhase.downloading => '下载中',
        AppUpdatePhase.verifying => '正在校验',
        AppUpdatePhase.ready => '安装包已就绪',
        AppUpdatePhase.permission => '允许安装后返回',
        AppUpdatePhase.installing => '等待系统安装',
        AppUpdatePhase.cancelled => '下载已取消',
        AppUpdatePhase.error => state.error.isEmpty ? '更新失败，请重试' : state.error,
      };

String _bytes(int value) => value < 1024 * 1024
    ? '${(value / 1024).toStringAsFixed(0)} KB'
    : '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
