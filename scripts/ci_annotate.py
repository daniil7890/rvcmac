#!/usr/bin/env python3
"""Turns compiler / test output into GitHub annotations (readable from the API without log downloads).

usage: ci_annotate.py LOG KIND PATTERN [TITLE]
"""
import re
import sys

log, kind, pattern = sys.argv[1], sys.argv[2], sys.argv[3]
title = sys.argv[4] if len(sys.argv) > 4 else kind
try:
    lines = open(log, errors="replace").read().splitlines()
except FileNotFoundError:
    sys.exit(0)
seen = []
for line in lines:
    if re.search(pattern, line):
        line = re.sub(r"^.*/(Sources|Tests)/", "", line).strip()
        if line not in seen:
            seen.append(line)
if seen:
    msg = "\n".join(seen[:80]).replace("%", "%25").replace("\r", "").replace("\n", "%0A")
    print(f"::{kind} title={title}::{msg}")
