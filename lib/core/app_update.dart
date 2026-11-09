import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const updateManifestUrl =
    'https://yuetongdai0-glitch.github.io/fake-location-releases/update.json';

/// 只从同一发行仓库读取清单，避免单个缓存节点把旧版本误报为最新。
final updateManifestSources = List<Uri>.unmodifiable([
  Uri.parse(updateManifestUrl),
  Uri.parse(
    'https://raw.githubusercontent.com/yuetongdai0-glitch/fake-location-releases/main/update.json',
  ),
  Uri.parse(
    'https://api.github.com/repos/yuetongdai0-glitch/fake-location-releases/contents/update.json?ref=main',
  ),
]);

/// 检查下载地址的发行仓库边界，不能只凭 GitHub 域名接受其他人的文件。
bool isTrustedUpdateApk(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return false;
  }
  return switch (uri.host.toLowerCase()) {
    'yuetongdai0-glitch.github.io' =>
      uri.path == '/fake-location-releases/releases/android/latest.apk',
    'raw.githubusercontent.com' =>
      uri.path ==
              '/yuetongdai0-glitch/fake-location-releases/main/releases/android/latest.apk' ||
          uri.path == '/yuetongdai0-glitch/fake-location-releases/refs/heads/main/releases/android/latest.apk',
    'api.github.com' =>
      uri.path ==
              '/repos/yuetongdai0-glitch/fake-location-releases/contents/releases/android/latest.apk' &&
          uri.queryParametersAll['ref']?.length == 1 &&
          uri.queryParameters['ref'] == 'main' &&
          uri.queryParametersAll.keys.every(
            (key) => key == 'ref' || key == '_',
          ) &&
          (uri.queryParametersAll['_']?.length ?? 0) <= 1,
    'github.com' =>
      _isReleaseApk(uri) ||
          uri.path ==
              '/yuetongdai0-glitch/fake-location-releases/raw/refs/heads/main/releases/android/latest.apk' ||
          uri.path == '/yuetongdai0-glitch/fake-location-releases/raw/main/releases/android/latest.apk',
    _ => false,
  };
}

/// 发行附件也必须属于本仓库，标签和文件名各占一段，拒绝编码分隔符与目录穿越。
bool _isReleaseApk(Uri uri) {
  final parts = uri.pathSegments;
  return parts.length == 6 &&
      parts[0] == 'yuetongdai0-glitch' &&
      parts[1] == 'fake-location-releases' &&
      parts[2] == 'releases' &&
      parts[3] == 'download' &&
      parts[4].isNotEmpty &&
      parts[5].endsWith('.apk') &&
      parts.every(
        (part) =>
            part != '.' &&
            part != '..' &&
            !part.contains('/') &&
            !part.contains('\\'),
      );
}

/// 安卓发行清单；包身份、长度和摘要在交给原生下载前完成边界检查。
class AppUpdate {
  const AppUpdate({
    required this.appId,
    required this.versionName,
    required this.versionCode,
    required this.apkUrl,
    required this.sha256,
    required this.minSdk,
    this.apkBytes,
  });

  final String appId;
  final String versionName;
  final int versionCode;
  final Uri apkUrl;
  final String sha256;
  final int minSdk;
  final int? apkBytes;

  factory AppUpdate.fromJson(Map<String, dynamic> json) {
    final value = json['android'];
    if (value is! Map) throw const FormatException('版本信息不完整');
    final android = Map<String, dynamic>.from(value);
    final appId = json['appId'];
    final versionName = android['versionName'];
    final versionCode = android['versionCode'];
    final apkUrlValue = android['apkUrl'];
    final sha256 = android['sha256'];
    final minSdk = android['minSdk'] ?? 1;
    final apkBytes = android['apkBytes'];
    if (appId != 'com.rz.fake_location' ||
        versionName is! String ||
        versionName.trim().isEmpty ||
        versionCode is! int ||
        versionCode < 1 ||
        apkUrlValue is! String ||
        sha256 is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256) ||
        minSdk is! int ||
        minSdk < 1 ||
        (apkBytes != null &&
            (apkBytes is! int ||
                apkBytes <= 0 ||
                apkBytes > 250 * 1024 * 1024))) {
      throw const FormatException('版本信息无效');
    }
    final apkUrl = Uri.tryParse(apkUrlValue);
    if (apkUrl == null || !isTrustedUpdateApk(apkUrl)) {
      throw const FormatException('安装包来源无效');
    }
    return AppUpdate(
      appId: appId as String,
      versionName: versionName.trim(),
      versionCode: versionCode,
      apkUrl: apkUrl,
      sha256: sha256.toLowerCase(),
      minSdk: minSdk,
      apkBytes: apkBytes as int?,
    );
  }

  bool isNewerThan(int installedVersionCode) =>
      versionCode > installedVersionCode;

  /// 传给原生的安装包身份；地址不会作为任意下载入口暴露。
  Map<String, Object> toNativeArguments() => {
    'packageId': appId,
    'versionName': versionName,
    'versionCode': versionCode,
    'apkUrl': apkUrl.toString(),
    'sha256': sha256,
    'minSdk': minSdk,
    'apkBytes': ?apkBytes,
  };
}

/// 三个固定入口并发读取，在统一时限内采用最高构建号，失败不等于没有更新。
Future<AppUpdate> fetchLatestUpdate({
  http.Client? client,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final actualClient = client ?? http.Client();
  final requestId = DateTime.now().microsecondsSinceEpoch.toString();
  try {
    final results = await Future.wait(
      updateManifestSources.map((source) async {
        try {
          return await _readManifest(
            actualClient,
            source.replace(
              queryParameters: {...source.queryParameters, '_': requestId},
            ),
          ).timeout(timeout);
        } catch (_) {
          return null;
        }
      }),
    );
    final updates = results.whereType<AppUpdate>().toList()
      ..sort((left, right) => right.versionCode.compareTo(left.versionCode));
    if (updates.isEmpty) throw const FormatException('检查失败，请重试');
    final newest = updates.first;
    if (updates.any(
      (update) =>
          update.versionCode == newest.versionCode &&
          (update.sha256 != newest.sha256 ||
              update.versionName != newest.versionName ||
              update.minSdk != newest.minSdk ||
              (update.apkBytes != null &&
                  newest.apkBytes != null &&
                  update.apkBytes != newest.apkBytes)),
    )) {
      throw const FormatException('版本信息不一致，请重试');
    }
    return newest;
  } finally {
    if (client == null) actualClient.close();
  }
}

/// 清单限制长度并拒绝跨来源跳转，避免把错误页、代理响应或超大数据当作版本信息。
Future<AppUpdate> _readManifest(http.Client client, Uri uri) async {
  final request = http.Request('GET', uri)
    ..followRedirects = false
    ..headers.addAll({
      'Cache-Control': 'no-cache, no-store',
      'Pragma': 'no-cache',
      'Accept': 'application/vnd.github.raw+json, application/json',
    });
  final response = await client.send(request);
  if (response.statusCode != 200 || (response.contentLength ?? 0) > 64 * 1024) {
    throw const FormatException('版本信息读取失败');
  }
  final bytes = <int>[];
  await for (final chunk in response.stream) {
    bytes.addAll(chunk);
    if (bytes.length > 64 * 1024) {
      throw const FormatException('版本信息过大');
    }
  }
  Object? decoded = jsonDecode(utf8.decode(bytes));
  // GitHub API 的旧响应形态可能返回内容包装，仍仅解析固定清单文件。
  if (decoded is Map && decoded['encoding'] == 'base64') {
    final content = decoded['content'];
    if (content is! String) throw const FormatException('版本信息无效');
    decoded = jsonDecode(
      utf8.decode(base64Decode(content.replaceAll(RegExp(r'\s'), ''))),
    );
  }
  if (decoded is! Map) throw const FormatException('版本信息无效');
  return AppUpdate.fromJson(Map<String, dynamic>.from(decoded));
}
