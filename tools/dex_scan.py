#!/usr/bin/env python3
"""扫描 APK 内所有 dex，统计「模拟定位检测 / 风控 SDK」相关符号出现情况。

用法: python3 dex_scan.py <apk> [<apk> ...]
只做静态字符串/符号统计，不执行目标程序。
"""
import re
import sys
import zipfile

# 检测能力相关符号（dex 里以方法名 / 字段名 / 权限名常量存在）
PROBES = {
    "isFromMockProvider": b"isFromMockProvider",
    "isMock(API31+)": b"isMock",
    "addTestProvider": b"addTestProvider",
    "setTestProviderLocation": b"setTestProviderLocation",
    "mock_location(appop)": b"mock_location",
    "ALLOW_MOCK_LOCATION": b"ALLOW_MOCK_LOCATION",
    "FLAG_MOCK": b"FLAG_MOCK",
    "setMock": b"setMock",
    "isLocationEnabled": b"isLocationEnabled",
    "getLastKnownLocation": b"getLastKnownLocation",
    "requestLocationUpdates": b"requestLocationUpdates",
    "getCurrentLocation": b"getCurrentLocation",
}

# 风控 / 安全 SDK 的类路径特征
SDK_MARKERS = {
    "阿里聚安全(wireless.security)": b"com/alibaba/wireless/security",
    "阿里 SecurityGuard": b"com/aliyun/security",
    "腾讯御安全(turingfd)": b"com/tencent/turingfd",
    "腾讯 Beacon/终端": b"com/tencent/beacon",
    "字节 安全(jumio/soter)": b"com/bytedance/jumio",
    "字节 AppLog/监控": b"com/bytedance/applog",
    "字节 安全 SDK": b"com/ss/android/ugc",
    "Google Play 完整性": b"com/google/android/play/core/appupdate",
    "Xposed 痕迹检测": b"XposedBridge",
    "Magisk 痕迹检测": b"magisk",
    "Su 路径检测": b"/system/xbin/su",
    "模拟器检测(genymotion)": b"genymotion",
    "模拟器检测(goldfish)": b"goldfish",
    "多开/虚拟化检测": b"io/virtualapp",
}


def scan(apk_path):
    print(f"\n=== {apk_path} ===")
    with zipfile.ZipFile(apk_path) as z:
        dexes = sorted(
            (n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n)),
            key=lambda n: int(re.sub(r"\D", "", n) or 0),
        )
        print(f"dex 文件数: {len(dexes)}")
        hits = {k: [] for k in PROBES}
        sdk_hits = {k: [] for k in SDK_MARKERS}
        for i, name in enumerate(dexes, 1):
            data = z.read(name)
            for label, needle in PROBES.items():
                c = data.count(needle)
                if c:
                    hits[label].append((name, c))
            for label, needle in SDK_MARKERS.items():
                c = data.count(needle)
                if c:
                    sdk_hits[label].append((name, c))
            print(f"  [{i}/{len(dexes)}] {name} {len(data)/1e6:.1f}MB", end="\r")
        print(" " * 40, end="\r")

    print("\n-- 检测 API 引用 --")
    for label in PROBES:
        rows = hits[label]
        if not rows:
            print(f"  {label:<24} 未出现")
        else:
            total = sum(c for _, c in rows)
            where = ", ".join(f"{n}×{c}" for n, c in rows[:4])
            print(f"  {label:<24} {total:>5} 次  ({where}{' ...' if len(rows) > 4 else ''})")

    print("\n-- 风控 / 安全 SDK 特征 --")
    for label in SDK_MARKERS:
        rows = sdk_hits[label]
        if not rows:
            continue
        total = sum(c for _, c in rows)
        where = ", ".join(f"{n}×{c}" for n, c in rows[:4])
        print(f"  {label:<24} {total:>5} 次  ({where}{' ...' if len(rows) > 4 else ''})")


if __name__ == "__main__":
    for path in sys.argv[1:]:
        scan(path)
