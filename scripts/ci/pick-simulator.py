#!/usr/bin/env python3
"""En yeni iOS sürümündeki bir iPhone simülatörünün UDID'sini yazdırır.

Tercih sırası: iPhone 17 Pro, iPhone 16 Pro, sonra herhangi bir iPhone.
"""
import json
import re
import subprocess
import sys

PREFERRED = ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 17", "iPhone 16"]


def runtime_version(identifier):
    match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?", identifier)
    if not match:
        return None
    return tuple(int(part or 0) for part in match.groups())


def main():
    data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    candidates = []
    for runtime, devices in data["devices"].items():
        version = runtime_version(runtime)
        if version is None:
            continue
        for device in devices:
            name = device["name"]
            if not name.startswith("iPhone"):
                continue
            rank = PREFERRED.index(name) if name in PREFERRED else len(PREFERRED)
            candidates.append((version, -rank, name, device["udid"]))
    if not candidates:
        sys.exit("iPhone simülatörü bulunamadı")
    candidates.sort()
    version, _, name, udid = candidates[-1]
    print(f"{name} (iOS {'.'.join(map(str, version))}) seçildi", file=sys.stderr)
    print(udid)


if __name__ == "__main__":
    main()
