# 虚拟定位（Android）

一个仅面向 Android 的 Flutter 虚拟定位应用。地图使用 GCJ-02 坐标，向系统 GPS 写入 WGS-84 坐标；应用可以直接从 GitHub 发布仓库检查、下载并安装最新版。

## 使用方式

1. 在手机“开发者选项”中把“选择模拟位置信息应用”设为“虚拟定位”。
2. 打开应用，搜索地点、输入坐标或点击地图选择目标位置。
3. 点击“开始模拟”；需要停止时点击“停止”即可恢复真实定位。
4. 应用底部会显示当前版本。发现新版本后点击“更新到 …”，安装包下载完成后会进入系统安装器。

应用内更新只接受 GitHub HTTPS 地址，并在安装前校验 SHA-256、包名、版本号和签名。首次更新如果提示安装权限，请允许“虚拟定位”安装未知来源应用，然后返回应用再次点击更新。

## 安装构建包

发布版使用 Flutter 默认 Android 调试签名，以便与最初交付的安装包保持相同签名、支持覆盖更新。这个签名适合个人直装分发；如需上架应用商店或公开大规模分发，应先配置独立的正式签名，并让所有已有用户卸载旧版后重新安装。

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

产物位于 `build/app/outputs/flutter-apk/app-release.apk`。该目录已加入 Git 忽略规则。

## 发布

先在 `pubspec.yaml` 提高 `version` 和 `+` 后面的整数构建号，再运行：

```bash
node tool/release.mjs
```

脚本会执行分析、测试、安卓打包，把最新 APK 以固定文件名发布到同账号的 `fake-location-releases` 公共仓库，更新 `update.json` 和下载页，删除发布仓库中的旧 APK，最后清理本项目 `build/` 和 Gradle 输出目录。应用内下载使用 GitHub Pages 地址，获得更稳定的下载速度。

可用参数：

- `--dry-run`：完整构建并生成发布文件，但不提交、不推送，也不清理。
- `--no-push`：只提交发布仓库，不推送。
- `--skip-tests`：跳过 `flutter test`，其余检查和打包照常执行。

可通过 `RELEASE_REPO_DIR` 指定已克隆的发布仓库目录：

```bash
RELEASE_REPO_DIR=/path/to/fake-location-releases node tool/release.mjs
```

## 下载页

<https://yuetongdai0-glitch.github.io/fake-location-releases/>

更新清单：

<https://yuetongdai0-glitch.github.io/fake-location-releases/update.json>
