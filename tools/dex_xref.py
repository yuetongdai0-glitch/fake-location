#!/usr/bin/env python3
"""在 dexdump -d 输出里定位「谁引用了某个方法」，打印所在类与方法。

用法: python3 dex_xref.py <dexdump.txt> <方法名子串> [<方法名子串> ...]
"""
import re
import sys

CLASS_RE = re.compile(r"Class descriptor\s*:\s*'(L[^']+;)'")
METHOD_RE = re.compile(r"^\s{4}name\s*:\s*'([^']*)'")


def main():
    path, needles = sys.argv[1], sys.argv[2:]
    current_class = "?"
    current_method = "?"
    seen = set()
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            m = CLASS_RE.search(line)
            if m:
                current_class = m.group(1)
                current_method = "?"
                continue
            m = METHOD_RE.match(line)
            if m:
                current_method = m.group(1)
                continue
            for needle in needles:
                if needle in line and ("invoke" in line or "call" in line or "sget" in line or "const-string" in line):
                    key = (needle, current_class, current_method)
                    if key in seen:
                        continue
                    seen.add(key)
                    print(f"[{needle}]")
                    print(f"  class : {current_class}")
                    print(f"  method: {current_method}")
                    print(f"  insn  : {line.strip()[:180]}")
                    print()


if __name__ == "__main__":
    main()
