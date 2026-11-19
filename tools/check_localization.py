#!/usr/bin/env python3
"""Localization checks:
- no duplicate keys in App/Core/Localization.swift (a duplicate key crashes Swift at launch);
- every L("...") key used in the app has a Russian translation."""
import re, sys, glob, collections
s = open("App/Core/Localization.swift").read()
keys = re.findall(r'^        "((?:[^"\\]|\\.)*)": "', s, re.M)
dups = [k for k, c in collections.Counter(keys).items() if c > 1]
used = set()
for f in glob.glob("App/**/*.swift", recursive=True):
    if f.endswith("Localization.swift"):
        continue
    used.update(m.group(1) for m in re.finditer(r'\bL\("((?:[^"\\]|\\.)*)"', open(f).read()))
missing = sorted(used - set(keys))
if dups:
    print("Duplicate localization keys:", dups)
if missing:
    print("Missing Russian translations:", missing)
if dups or missing:
    sys.exit(1)
print(f"{len(keys)} localization keys, no duplicates, all {len(used)} used keys translated")
