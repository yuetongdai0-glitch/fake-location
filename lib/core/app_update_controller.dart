import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_update.dart';
import 'user_message.dart';

/// 更新界面使用同一个状态源，避免设置弹层显示过期的“最新版本”。
enum AppUpdatePhase {
  idle,
  checking,
  current,
  available,
  downloading,
  verifying,
  ready,
  permission,
  installing,
  cancelled,
  error,
}

/// 可恢复的更新快照；系统安装器打开只表示交给系统，不表示安装完成。
class AppUpdateState {
  const AppUpdateState({
    this.phase = AppUpdatePhase.idle,
    this.installedVersionName = '',
    this.installedVersionCode = 0,
    this.update,
    this.receivedBytes = 0,
    this.totalBytes = -1,
    this.progress = -1,
    this.error = '',
    this.canInstall = false,
    this.nativeVersionName = '',
    this.nativeVersionCode = 0,
  });

  final AppUpdatePhase phase;
  final String installedVersionName;
  final int installedVersionCode;
  final AppUpdate? update;
  final int receivedBytes;
  final int totalBytes;
  final int progress;
  final String error;
  final bool canInstall;
  final String nativeVersionName;
  final int nativeVersionCode;

  String get availableVersionName => update?.versionName ?? nativeVersionName;

  bool get busy =>
      phase == AppUpdatePhase.checking ||
      phase == AppUpdatePhase.downloading ||
      phase == AppUpdatePhase.verifying;
  bool get canCancel =>
      phase == AppUpdatePhase.downloading || phase == AppUpdatePhase.verifying;
  bool get hasUpdate =>
      (update?.versionCode ?? nativeVersionCode) > installedVersionCode;

  AppUpdateState copyWith({
    AppUpdatePhase? phase,
    String? installedVersionName,
    int? installedVersionCode,
    AppUpdate? update,
    int? receivedBytes,
    int? totalBytes,
    int? progress,
    String? error,
    bool? canInstall,
    String? nativeVersionName,
    int? nativeVersionCode,
  }) => AppUpdateState(
    phase: phase ?? this.phase,
    installedVersionName: installedVersionName ?? this.installedVersionName,
    installedVersionCode: installedVersionCode ?? this.installedVersionCode,
    update: update ?? this.update,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    progress: progress ?? this.progress,
    error: error ?? this.error,
    canInstall: canInstall ?? this.canInstall,
    nativeVersionName: nativeVersionName ?? this.nativeVersionName,
    nativeVersionCode: nativeVersionCode ?? this.nativeVersionCode,
  );
}

/// 版本检查与定位独立；并发检查共用同一请求，原生下载状态可在界面重开时恢复。
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    MethodChannel? channel,
    Future<AppUpdate> Function()? loadLatest,
  }) : _channel = channel ?? const MethodChannel('fake_location/update'),
       _loadLatest = loadLatest ?? fetchLatestUpdate {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  final MethodChannel _channel;
  final Future<AppUpdate> Function() _loadLatest;
  AppUpdateState _state = const AppUpdateState();
  Future<AppUpdate?>? _checkTask;
  Future<void>? _versionTask;
  bool _disposed = false;
  int _eventRevision = 0;
  int _operationId = -1;
  int _nativeRevision = -1;
  bool _installPending = false;
  int _sdkInt = 0;

  AppUpdateState get state => _state;
  bool get busy => _state.busy;
  bool get canCancel => _state.canCancel;
  bool get hasUpdate => _state.hasUpdate;

  /// 启动只读版本和状态，不下载；检查失败留在状态中，由用户决定重试。
  Future<void> initialize() async {
    try {
      await _readInstalledVersion();
      await syncNativeStatus();
      if (!_state.canCancel && _state.phase != AppUpdatePhase.permission) {
        try {
          await check();
        } finally {
          await syncNativeStatus();
        }
      }
    } catch (_) {
      // check / 版本读取已记录受控错误，自动检查不弹出重复通知。
    }
  }

  /// 版本未知时不能宣称最新；失败后下一次检查仍可重新读取。
  Future<void> _readInstalledVersion() {
    if (_state.installedVersionCode > 0) return Future<void>.value();
    final pending = _versionTask;
    if (pending != null) return pending;
    late final Future<void> task;
    task = () async {
      try {
        final version = await _channel.invokeMapMethod<String, dynamic>(
          'version',
        );
        final name = version?['versionName'];
        final code = version?['versionCode'];
        if (name is! String ||
            name.trim().isEmpty ||
            code is! num ||
            code <= 0) {
          throw const FormatException('无法读取当前版本，请重试');
        }
        final sdk = version?['sdkInt'];
        _sdkInt = sdk is num ? sdk.toInt() : 0;
        _set(
          _state.copyWith(
            installedVersionName: name.trim(),
            installedVersionCode: code.toInt(),
          ),
        );
      } catch (error) {
        _fail(error, fallback: '无法读取当前版本，请重试');
        rethrow;
      } finally {
        _versionTask = null;
      }
    }();
    _versionTask = task;
    return task;
  }

  /// 多个入口共享同一次检查，不能把“正在检查”当成“没有更新”。
  Future<AppUpdate?> check({bool manual = false}) {
    final pending = _checkTask;
    if (pending != null) return pending;
    if (_state.canCancel) {
      return Future<AppUpdate?>.value(_state.update);
    }
    late final Future<AppUpdate?> task;
    task = () async {
      _set(_state.copyWith(phase: AppUpdatePhase.checking, error: ''));
      try {
        await _readInstalledVersion();
        var latest = await _loadLatest();
        if (_disposed) return null;
        // 已验证的本机缓存也是已知发行证据，不能被某个旧缓存清单降成“最新”。
        final known = _state.update;
        if (known != null &&
            known.isNewerThan(_state.installedVersionCode) &&
            known.versionCode > latest.versionCode) {
          latest = known;
        }
        if (_state.nativeVersionCode > latest.versionCode &&
            _state.nativeVersionCode > _state.installedVersionCode) {
          if (!_state.canInstall) {
            throw const FormatException('版本信息尚未同步，请稍后重试');
          }
          _set(_state.copyWith(phase: AppUpdatePhase.ready, error: ''));
          return known?.versionCode == _state.nativeVersionCode ? known : null;
        }
        if (_sdkInt > 0 && latest.minSdk > _sdkInt) {
          throw const FormatException('新版暂不支持当前系统');
        }
        final available = latest.isNewerThan(_state.installedVersionCode);
        // 清单刷新不能丢掉已校验的同版本缓存和安装权限恢复入口。
        final cached =
            available &&
            _state.canInstall &&
            _state.update?.versionCode == latest.versionCode &&
            _state.update?.sha256 == latest.sha256;
        _set(
          _state.copyWith(
            phase: cached
                ? AppUpdatePhase.ready
                : available
                ? AppUpdatePhase.available
                : AppUpdatePhase.current,
            update: latest,
            error: '',
            canInstall: cached,
          ),
        );
        return available ? latest : null;
      } catch (error) {
        _fail(error, fallback: '检查失败，请重试');
        rethrow;
      } finally {
        _checkTask = null;
      }
    }();
    _checkTask = task;
    return task;
  }

  /// 下载和安装分开：完成校验后显示安装按钮，关闭面板不丢下载进度。
  Future<void> download() async {
    if (_state.busy) return;
    var update = _state.update;
    // 原生恢复只提供版本摘要；缓存失效后先取完整清单，重试按钮不能悄悄空操作。
    if (update == null && _state.hasUpdate) {
      try {
        update = await check(manual: true);
      } catch (_) {
        return;
      }
    }
    if (update == null || !_state.hasUpdate || _state.busy) return;
    _set(
      _state.copyWith(
        phase: AppUpdatePhase.downloading,
        receivedBytes: 0,
        totalBytes: update.apkBytes ?? -1,
        progress: 0,
        error: '',
        canInstall: false,
      ),
    );
    await _command('download', arguments: update.toNativeArguments());
  }

  /// 复用已校验安装包；授权返回和安装器取消都能再次安装，不重复下载。
  Future<void> install() async {
    if (!_state.canInstall || _state.busy || _installPending) return;
    _installPending = true;
    try {
      await _command('install');
    } finally {
      _installPending = false;
    }
  }

  Future<void> cancel() async {
    if (!_state.canCancel) return;
    await _command('cancelDownload');
  }

  /// 页面重新打开或应用恢复前台时读取后台状态，补齐遗漏的进度事件。
  Future<void> syncNativeStatus() async {
    await _command('status', quiet: true);
  }

  Future<void> _command(
    String method, {
    Map<String, Object>? arguments,
    bool quiet = false,
  }) async {
    final before = _eventRevision;
    try {
      final snapshot = await _channel.invokeMapMethod<String, dynamic>(
        method,
        arguments,
      );
      // 原生已发布更晚事件时，不能用方法刚开始时截取的旧响应倒退状态。
      if (!_disposed && snapshot != null && before == _eventRevision) {
        _applyNative(snapshot);
      }
    } catch (error) {
      if (!quiet) {
        // 安装异常可能意味着缓存已被清理，不能沿用上次“可安装”的按钮状态。
        if (method == 'install') {
          _set(_state.copyWith(canInstall: false));
        }
        _fail(error, fallback: '更新失败，请重试');
        if (method == 'install') await syncNativeStatus();
      }
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'updateStatus' || call.arguments is! Map || _disposed) {
      return;
    }
    _eventRevision++;
    _applyNative(Map<String, dynamic>.from(call.arguments as Map));
  }

  void _applyNative(Map<String, dynamic> snapshot) {
    final codeValue = snapshot['versionCode'];
    final code = codeValue is num ? codeValue.toInt() : 0;
    if (code > 0 && code <= _state.installedVersionCode) return;
    if (_state.update != null &&
        code > 0 &&
        code != _state.update!.versionCode) {
      return;
    }
    final operation = snapshot['operationId'];
    if (operation is num) {
      if (operation.toInt() < _operationId) return;
      _operationId = operation.toInt();
    }
    final revision = snapshot['revision'];
    if (revision is num) {
      if (revision.toInt() < _nativeRevision) return;
      _nativeRevision = revision.toInt();
    }
    final phase = switch (snapshot['state']) {
      'downloading' => AppUpdatePhase.downloading,
      'verifying' => AppUpdatePhase.verifying,
      'ready' => AppUpdatePhase.ready,
      'permission' => AppUpdatePhase.permission,
      'installing' => AppUpdatePhase.installing,
      'error' => AppUpdatePhase.error,
      'cancelled' => AppUpdatePhase.cancelled,
      _ => null,
    };
    if (phase == null) return;
    int number(String key, int fallback) =>
        snapshot[key] is num ? (snapshot[key] as num).toInt() : fallback;
    final error = snapshot['error'];
    _set(
      _state.copyWith(
        phase: phase,
        receivedBytes: number(
          'receivedBytes',
          _state.receivedBytes,
        ).clamp(0, 1 << 53),
        totalBytes: number('totalBytes', _state.totalBytes),
        progress: number('progress', -1).clamp(-1, 100),
        error: error is String && error.isNotEmpty
            ? userMessage(Exception(error), fallback: '更新失败，请重试')
            : '',
        nativeVersionName: snapshot['versionName'] is String
            ? snapshot['versionName'] as String
            : _state.nativeVersionName,
        nativeVersionCode: code > 0 ? code : _state.nativeVersionCode,
        canInstall: snapshot['canInstall'] is bool
            ? snapshot['canInstall'] as bool
            : phase == AppUpdatePhase.ready ||
                  phase == AppUpdatePhase.permission ||
                  phase == AppUpdatePhase.installing,
      ),
    );
  }

  void _fail(Object error, {required String fallback}) => _set(
    _state.copyWith(
      phase: AppUpdatePhase.error,
      error: userMessage(error, fallback: fallback),
    ),
  );

  void _set(AppUpdateState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
