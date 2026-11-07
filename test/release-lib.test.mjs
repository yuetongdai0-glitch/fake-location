import assert from 'node:assert/strict'
import test from 'node:test'
import { buildManifest, parsePubspecVersion, renderReleasePage } from '../tool/release-lib.mjs'

test('解析 Flutter 版本和构建号', () => {
  assert.deepEqual(parsePubspecVersion('name: app\nversion: 1.2.3+42\n'), {
    versionName: '1.2.3',
    versionCode: 42,
  })
  assert.throws(() => parsePubspecVersion('version: 1.2.3'), /1\.2\.3\+4/)
})

test('更新清单使用固定 APK 路径和完整摘要', () => {
  const digest = 'a'.repeat(64)
  const manifest = buildManifest({
    versionName: '1.2.3',
    versionCode: 42,
    sha256: digest,
    bytes: 1024,
    publishedAt: '2026-11-07T00:00:00.000Z',
  })
  assert.equal(manifest.appId, 'com.rz.fake_location')
  assert.equal(manifest.android.versionCode, 42)
  assert.equal(manifest.android.sha256, digest)
  assert.match(manifest.android.apkUrl, /latest\.apk\?v=42$/)
})

test('下载页不会漏掉安装包链接和摘要', () => {
  const page = renderReleasePage({
    versionName: '1.2.3',
    versionCode: 42,
    sha256: 'b'.repeat(64),
    bytes: 1024 * 1024,
  })
  assert.match(page, /releases\/android\/latest\.apk/)
  assert.match(page, /v1\.2\.3 \(42\)/)
  assert.match(page, new RegExp('b'.repeat(64)))
})
