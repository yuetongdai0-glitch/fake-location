import 'dart:convert';

import 'package:http/http.dart' as http;

const updateManifestUrl =
    'https://yuetongdai0-glitch.github.io/fake-location-releases/update.json';

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
    if (androidValue is! Map) throw const FormatException('更新清单缺少安卓版本信息');
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
      throw const FormatException('安装包地址必须使用受信任发布站点的加密链接');
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
        Uri.parse('$updateManifestUrl?_=$requestId'),
        headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
      )
      .timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) {
    throw Exception('检查更新失败：服务器返回状态码 ${response.statusCode}');
  }
  final decoded = jsonDecode(utf8.decode(response.bodyBytes));
  if (decoded is! Map) throw const FormatException('更新清单格式无效');
  return AppUpdate.fromJson(Map<String, dynamic>.from(decoded));
}
