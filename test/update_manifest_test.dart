import 'package:fake_location/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('仅接受包名、摘要和 GitHub 地址均正确的更新清单', () {
    final update = AppUpdate.fromJson({
      'appId': 'com.rz.fake_location',
      'android': {
        'versionName': '1.0.2',
        'versionCode': 3,
        'minSdk': 24,
        'sha256': 'a' * 64,
        'apkUrl': 'https://raw.githubusercontent.com/yuetongdai0-glitch/fake-location-releases/main/releases/android/latest.apk',
      },
    });

    expect(update.isNewerThan(2), isTrue);
    expect(update.isNewerThan(3), isFalse);
  });

  test('拒绝非 GitHub 域名和摘要不足的清单', () {
    expect(
      () => AppUpdate.fromJson({
        'appId': 'com.rz.fake_location',
        'android': {
          'versionName': '9.9.9',
          'versionCode': 99,
          'minSdk': 24,
          'sha256': 'abc',
          'apkUrl': 'https://example.com/app.apk',
        },
      }),
      throwsFormatException,
    );
  });
}
