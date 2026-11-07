/**
 * 从 pubspec.yaml 提取 Flutter 版本名和 Android versionCode。
 * @param {string} source pubspec 文本。
 * @returns {{versionName: string, versionCode: number}} 版本信息。
 */
export function parsePubspecVersion(source) {
  const match = source.match(/^version:\s*([0-9]+(?:\.[0-9]+){2})\+([1-9][0-9]*)\s*$/m)
  if (!match) throw new Error('pubspec.yaml 的 version 必须写成 1.2.3+4')
  return { versionName: match[1], versionCode: Number(match[2]) }
}

/**
 * 生成应用内更新清单。
 * @param {{versionName: string, versionCode: number, sha256: string, bytes: number, publishedAt: string}} input 发布信息。
 * @returns {object} 更新清单。
 */
export function buildManifest(input) {
  if (!/^[0-9a-f]{64}$/.test(input.sha256)) throw new Error('APK SHA-256 非法')
  if (!Number.isInteger(input.versionCode) || input.versionCode < 1) throw new Error('versionCode 非法')
  return {
    appId: 'com.rz.fake_location',
    versionName: input.versionName,
    versionCode: input.versionCode,
    publishedAt: input.publishedAt,
    android: {
      versionName: input.versionName,
      versionCode: input.versionCode,
      minSdk: 24,
      apkBytes: input.bytes,
      sha256: input.sha256,
      apkUrl:
        `https://yuetongdai0-glitch.github.io/fake-location-releases/` +
        `releases/android/latest.apk?v=${input.versionCode}`,
    },
  }
}

/**
 * 渲染发布仓库下载页。
 * @param {{versionName: string, versionCode: number, sha256: string, bytes: number}} input 版本信息。
 * @returns {string} HTML 页面。
 */
export function renderReleasePage(input) {
  const size = `${(input.bytes / 1024 / 1024).toFixed(2)} MiB`
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>虚拟定位 Android v${input.versionName}</title>
  <style>
    :root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f5f7f5;color:#172018}
    main{width:min(560px,calc(100% - 40px));padding:32px;border-radius:20px;background:#fff;box-shadow:0 18px 60px #19321a1a}
    h1{margin:0 0 8px;font-size:30px} p{color:#5a665b;line-height:1.7}
    .download{display:block;margin:26px 0 18px;padding:15px 20px;border-radius:12px;background:#1f7a44;color:#fff;text-align:center;font-weight:700;text-decoration:none}
    dl{display:grid;grid-template-columns:auto 1fr;gap:8px 16px;margin:0;font-size:14px}dt{color:#6b776c}dd{margin:0;word-break:break-all}
    @media(prefers-color-scheme:dark){body{background:#111712;color:#eef5ef}main{background:#19211b}dd{color:#d7e3d8}}
  </style>
</head>
<body><main>
  <h1>虚拟定位</h1>
  <p>Android 最新安装包。应用内也会自动检查此版本，并在校验后直接调起系统安装器。</p>
  <a class="download" href="./releases/android/latest.apk" download>下载 Android APK</a>
  <dl>
    <dt>版本</dt><dd>v${input.versionName} (${input.versionCode})</dd>
    <dt>体积</dt><dd>${size}</dd>
    <dt>SHA-256</dt><dd>${input.sha256}</dd>
  </dl>
</main></body>
</html>
`
}
