# 模拟定位「被识破」问题：技术分析与实测

> 分析对象：微信 8.0.34（`com.tencent.mm`，238 MB / 12 个 dex）、飞书 8.5.4（`com.ss.android.lark`，369 MB / 62 个 dex）
> 方法：dex 符号扫描 + `dexdump -d` 反汇编定位引用点；只做静态证据，不运行目标程序
> 时间：2026-11-07

## 一、先回答核心问题：能不能用"更底层"的免 root 方式

**不能。** 这不是实现难度问题，是 Android 的权限模型决定的。

一条位置从产生到被应用读到，只有三条路：

| 路径 | 谁能用 | 带 mock 标记吗 |
|---|---|---|
| `LocationManager.addTestProvider` + `setTestProviderLocation` | 被选为"模拟位置应用"的普通应用（本应用现在用的） | **带**（系统投递时置 `FLAG_MOCK`） |
| `LocationManager.injectLocation` | 只有 `INSTALL_LOCATION_PROVIDER`（signature\|privileged），普通应用、adb shell 都没有 | 不带 |
| GNSS HAL / 驱动层 | 厂商签名 | 不带 |

也就是说，**唯一不带标记的入口在 HAL 层**，普通应用和 shell 都够不到。

用 adb 实测过：Android 13 的 `cmd location` 只提供 test provider 一组子命令，没有任何注入通道。

```
$ adb shell cmd location
  providers
    add-test-provider <PROVIDER> ...      ← 还是 test provider
    remove-test-provider <PROVIDER>
    set-test-provider-enabled <PROVIDER> true|false
    set-test-provider-location <PROVIDER> --location <LAT>,<LON>
    send-extra-command <PROVIDER> <COMMAND>
```

连 `cmd location` 的帮助里都写着：
> Requires MOCK_LOCATION permissions which can be enabled by running
> `adb shell appops set <uid> android:mock_location allow`

所以 Shizuku / adb 提权也一样绕不过去——它们只是让"设成模拟位置应用"这一步自动化，产出的位置仍然带标记。

**能真正去掉标记的只有两条路，都要求 root**：LSPosed/Shamiko 类模块（在目标进程内改 `Location` 对象），或把目标应用装进容器里运行（容器在进程内直接构造 `Location`）。

## 二、那两个应用到底会不会识破

静态分析结论：**两家用的根本不是同一套检测，命中情况不一样。**

### 微信：走的是 Android 6 以前的旧开关，现代系统上基本读不到

`classes9.dex` 里 `Lcom/tencent/mm/plugin/normsg/f;` 有明确的方法，日志串是：

```
MicroMsg.NormsgSourceImpl
Failed checking mock location: application context not initialized.
```

它查的是：

```smali
const-string/jumbo v13, "mock_location"
invoke-static {v9, v13, v12}, Landroid/provider/Settings$Secure;.getInt:(...)
invoke-static {}, Landroid/os/Debug;.isDebuggerConnected:()Z
```

- 读 `Settings.Secure["mock_location"]` —— 这是 **Android 6 之前**的全局开关，6.0 起系统改用 `appops` 管理、这个 key 不再由系统维护，读到的恒为默认值。
- 另外查 `Debug.isDebuggerConnected()`（是否被调试）。
- 全 APK 里 `isFromMockProvider` 出现 **0 次**，`Location.isMock()` 指令引用 **0 处**。

**结论**：微信不会因为"你把本应用设成模拟位置应用"而告警——它读的那个开关早就不生效了。但微信另有 root / Xposed / 模拟器检测（`/system/xbin/su`、`XposedBridge`、`goldfish`），**root 机反而更容易被别的检测命中**。

### 飞书：内置高德定位 SDK，直接调 `isFromMockProvider()`

`classes33.dex` 里命中 3 处，全部在 `com.loc.*`（高德定位 SDK 的混淆包名）：

```
Lcom/loc/o3$c;   invoke-virtual {v5}, Landroid/location/Location;.isFromMockProvider:()Z
Lcom/loc/u4;     invoke-virtual {v7}, Landroid/location/Location;.isFromMockProvider:()Z
Lcom/loc/w4;     const-string v4, "isFromMockProvider"   ← 反射兜底
```

**结论**：飞书这边一定会拿到 `true`。位置能不能用，取决于高德 SDK 把结果上报给谁、飞书风控怎么处理——这一点静态分析看不到，属于**未确认**。

### 汇总

| 应用 | 检测手段 | 我们的模拟会被识别吗 |
|---|---|---|
| 微信 8.0.34 | `Settings.Secure["mock_location"]`（已废弃）+ Debugger + root/Xposed/模拟器 | 基本不会（旧开关失效） |
| 飞书 8.5.4 | 高德 SDK `Location.isFromMockProvider()` | **会**，恒为 true |
| 钉钉 | 未分析 | 未知，强风控应用通常另有策略 |

## 三、所以这个应用做了什么改进

既然去掉标记在免 root 下做不到，能做的只有"减少自己暴露的信息"和"如实告知"：

1. **删掉了 `Location.extras` 里的 `mock=true`**。这是本项目自己写进去的，纯属主动暴露——系统本来就会打标记，应用没必要再自报一次。
2. **把 extras 做得更像真实 GNSS**：补上 `maxCn0`、`usedInFix`，卫星数与载噪比按区间随机。
3. **检测面板新增「其它应用能不能识破」**：直接展示上面的结论，不让用户误以为"模拟中 = 一切正常"。

## 四、复现方式

仓库里留了两个脚本，可以对任意 APK 重跑：

```bash
# 1. 扫符号：检测 API 与风控 SDK 特征
python3 tools/dex_scan.py /path/to/app.apk

# 2. 定位到具体类：先把 dex 反汇编
~/Library/Android/sdk/build-tools/36.0.0/dexdump -d classes33.dex > out.txt
python3 tools/dex_xref.py out.txt "isFromMockProvider" "Location;->isMock"
```

`dex_xref.py` 会连类名和方法名一起打出来，不用在几百万行反汇编里人工找。

## 五、合规说明

以上只做静态分析，目的是判断"本应用产出的位置能否被正常读取"，属于兼容性研究；
没有修改、破解、绕过任何目标应用的功能或授权，也没有提取其业务数据。
