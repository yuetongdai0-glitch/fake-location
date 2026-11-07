/**
 * 安卓发布：检查版本 → 分析测试 → 打包 → 只保留最新 APK → 推送发布仓库 → 清理本地构建产物。
 *
 * 用法：
 *   node tool/release.mjs
 *   node tool/release.mjs --dry-run
 *   node tool/release.mjs --no-push
 *   node tool/release.mjs --skip-tests
 */
import { copyFile, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildManifest, parsePubspecVersion, renderReleasePage } from './release-lib.mjs'

const sourceRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const releaseRoot = resolve(
  process.env.RELEASE_REPO_DIR ?? join(sourceRoot, '..', 'fake-location-releases'),
)
const options = new Set(process.argv.slice(2))
const dryRun = options.has('--dry-run')
const noPush = options.has('--no-push')
const skipTests = options.has('--skip-tests')
const apkSource = join(sourceRoot, 'build/app/outputs/flutter-apk/app-release.apk')
const apkTarget = join(releaseRoot, 'releases/android/latest.apk')

/**
 * 同步执行命令，失败时直接终止发布。
 * @param {string} command 命令。
 * @param {string[]} args 参数。
 * @param {string} cwd 工作目录。
 * @param {object} [env] 环境变量。
 * @returns {string} 标准输出。
 */
function run(command, args, cwd, env = {}) {
  return execFileSync(command, args, {
    cwd,
    env: { ...process.env, ...env },
    encoding: 'utf8',
    stdio: ['inherit', 'pipe', 'pipe'],
  })
}

/**
 * 流式计算文件 SHA-256，避免把几十兆安装包一次性读入内存。
 * @param {string} path 文件路径。
 * @returns {Promise<string>} 小写摘要。
 */
async function sha256File(path) {
  const file = await import('node:fs')
  const digest = createHash('sha256')
  await new Promise((ok, fail) => {
    file.createReadStream(path)
      .on('data', chunk => digest.update(chunk))
      .on('error', fail)
      .on('end', ok)
  })
  return digest.digest('hex')
}

/**
 * 删除 build/ 下所有本地产物，源码与依赖缓存不受影响。
 * @returns {Promise<void>}
 */
async function cleanBuildOutput() {
  await rm(join(sourceRoot, 'build'), { recursive: true, force: true })
  await rm(join(sourceRoot, 'android/app/build'), { recursive: true, force: true })
  await rm(join(sourceRoot, 'android/build'), { recursive: true, force: true })
  await rm(join(sourceRoot, 'android/.gradle'), { recursive: true, force: true })
}

if (!(await stat(join(releaseRoot, '.git')).catch(() => null))) {
  throw new Error(`发布仓库不存在或尚未初始化：${releaseRoot}`)
}

const pubspec = await readFile(join(sourceRoot, 'pubspec.yaml'), 'utf8')
const version = parsePubspecVersion(pubspec)
console.log(`① 发布 Android v${version.versionName} (${version.versionCode})`)

try {
  console.log('② 静态分析')
  run('flutter', ['analyze'], sourceRoot)
  if (!skipTests) {
    console.log('③ 运行测试')
    run('flutter', ['test'], sourceRoot)
  } else {
    console.log('③ 已跳过测试')
  }

  console.log('④ 打包 Android release')
  run('flutter', ['build', 'apk', '--release'], sourceRoot)

  const apkInfo = await stat(apkSource)
  const sha256 = await sha256File(apkSource)
  await mkdir(dirname(apkTarget), { recursive: true })
  await copyFile(apkSource, apkTarget)

  let removed = 0
  for (const name of await readdir(dirname(apkTarget))) {
    if (!name.toLowerCase().endsWith('.apk') || name === 'latest.apk') continue
    await rm(join(dirname(apkTarget), name), { recursive: true, force: true })
    removed += 1
  }

  const publishedAt = new Date().toISOString()
  const manifest = buildManifest({
    versionName: version.versionName,
    versionCode: version.versionCode,
    sha256,
    bytes: apkInfo.size,
    publishedAt,
  })
  await writeFile(join(releaseRoot, 'update.json'), `${JSON.stringify(manifest, null, 2)}\n`)
  const pageInput = {
    versionName: version.versionName,
    versionCode: version.versionCode,
    sha256,
    bytes: apkInfo.size,
  }
  await writeFile(join(releaseRoot, 'index.html'), renderReleasePage(pageInput))
  await writeFile(
    join(releaseRoot, 'README.md'),
    `# 虚拟定位 Android 发布仓库\n\n` +
      `应用内更新入口：[update.json](./update.json)\n\n` +
      `下载页：https://yuetongdai0-glitch.github.io/fake-location-releases/\n\n` +
      `发布仓库只保留最新安卓安装包：\`releases/android/latest.apk\`。\n`,
  )
  console.log(`⑤ APK ${(apkInfo.size / 1048576).toFixed(2)} MiB · SHA-256 ${sha256.slice(0, 16)}…`)
  if (removed) console.log(`   已删除发布仓库中的旧 APK ${removed} 个`)

  run('git', ['add', '-A'], releaseRoot)
  const dirty = run('git', ['status', '--porcelain'], releaseRoot).trim()
  if (dryRun) {
    console.log('⑥ --dry-run：跳过提交、推送与本地清理')
  } else {
    if (dirty) {
      console.log('⑥ 提交并推送发布仓库')
      run('git', ['commit', '-m', `release: 发布安卓版 ${version.versionName}`], releaseRoot)
      if (!noPush) {
        run(
          'git',
          ['-c', 'credential.helper=osxkeychain', 'push', 'origin', 'main'],
          releaseRoot,
          { GIT_TERMINAL_PROMPT: '0' },
        )
      }
    } else {
      console.log('⑥ 发布仓库没有变化')
    }
    console.log('⑦ 清理本地构建产物')
  }
  console.log(`\n下载页：https://yuetongdai0-glitch.github.io/fake-location-releases/`)
  console.log(`更新清单：https://yuetongdai0-glitch.github.io/fake-location-releases/update.json`)
} finally {
  // 构建失败或中止时也删除本地产物，避免留下可被误传的大 APK。
  if (!dryRun) await cleanBuildOutput()
}
