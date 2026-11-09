# 高德仍显示原位：1.4.1排查与修复

用户设备为小米14。截图确认悬浮窗显示的就是所选目标；这不证明高德实际采纳。当前工作环境仅连接Android16模拟器，未连接用户手机，不能从机型推定其已安装的系统版本。

## 已复现并修复

1. 首次启动未保存选点时，初始真实定位可能等待20秒。用户已经选点、甚至启动模拟后，迟到结果仍覆盖地图目标；再次更新会将原位发送到系统。新增目标版本和模拟指令版本检查，旧定位只更新读回信息，不改目标或镜头。回归覆盖无操作正常采用、手选、已启动、权限等待和卸载。
2. 推送瞬时失败后原逻辑忘记已注册源，旧系统重注册可能持续失败。保留原源重推，明确缺源才重新注册；重复注册遭拒时实际验证原源，不先删除源。
3. 系统模拟授权失效可能静默忽略测试源写入。每批检查授权，失效不累计成功，服务继续保留停止与恢复入口。
4. 悬浮窗以前只显示待写目标和任一源调用成功。现将坐标标为“目标”，分别读回预期源，按近期模拟标记、坐标偏差和推送错误显示确认数量，不把高德未确认显示为已生效。

## 真机证据收集

检测页新增“复制检测结果”，自动包含厂商、机型、Android版本、系统构建标识、应用版本，以及逐源坐标、模拟标记、年龄、授权与错误。仅在用户点击后写入本机剪贴板，不上传，不带地图密钥、收藏、最近记录、SSID、账号或设备唯一标识。这样无需用户手抄系统版本与多页状态。

## 已观察的外部应用行为

本机模拟器安装高德17.02.0.2010。将目标从北京切到上海、为该测试安装授予精确定位后，直接点击高德定位按钮，蓝点移至上海人民广场附近；系统三源均读回上海模拟坐标。这是该模拟器与该版本的观察，不能代替小米14实机验证。参考截图和位置转储位于工作区outputs/fake-location-reference/evidence/device-amap-shanghai-140和real-failure-amap-fine-location.txt。

## 来源与界限

- Android10已存在测试源的重复注册约束：[AOSP LocationManagerService](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android10-c2f2-s2-release/services/core/java/com/android/server/LocationManagerService.java)。
- 当前测试源操作的授权处理：[AOSP LocationManagerService](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/location/LocationManagerService.java)。
- 高德公开SDK允许配置是否采用模拟GPS，错误码15表示模拟导致失败：[定位配置](https://developer.amap.com/api/android-location-sdk/guide/android-location/getlocation)、[错误码](https://developer.amap.com/api/android-location-sdk/guide/utilities/errorcode)。公开SDK默认值不等于高德客户端当前实际策略，不能据此断言用户故障由拒绝模拟造成。
- 小米官方说明小米14初始为基于Android14的HyperOS：[小米支持](https://www.mi.com/ph/support/faq/details/KA-484750/)。该资料不代表用户目前安装的版本，新检测结果从设备本身读取版本标识。

这些修复针对已证实的本项目缺陷。用户手机上究竟是系统源未接管、后台停推，还是高德未采用，需要故障时的设备快照确认；本轮不宣称免系统提权可强制第三方应用接受模拟位置。

## 验证结果

Flutter162项、Android原生36项、发布脚本3项测试通过，静态分析无问题。1.4.1已在模拟器覆盖安装并直接打开高德，蓝点为上海目标，悬浮窗显示“系统源已读回3/3”；检测页分别显示三个源0米偏差，并提供复制快照。源码中的系统增量版本用于补充厂商构建标识；不会假定机型等于某个固定系统版本。
