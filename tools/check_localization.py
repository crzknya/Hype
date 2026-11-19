#!/usr/bin/env python3
"""Fails if App/Core/Localization.swift has duplicate keys (a runtime crash in Swift)."""
import re, sys, collections
s = open("App/Core/Localization.swift").read()
keys = re.findall(r'^        "((?:[^"\\]|\\.)*)": "', s, re.M)
dups = [k for k, c in collections.Counter(keys).items() if c > 1]
if dups:
    print("Duplicate localization keys:", dups)
    sys.exit(1)
print(f"{len(keys)} localization keys, no duplicates")
