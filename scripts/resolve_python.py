#!/usr/bin/env python3
"""Prints "<url> <sha256>" of a standalone CPython 3.12 for Apple Silicon (python-build-standalone).

The app downloads exactly this file on first use and checks the hash, so the build pins both.
Env: PYTHON_BUILD_TAG pins a release (default: latest), GITHUB_TOKEN avoids API rate limits.
"""
import json
import os
import re
import sys
import urllib.request

REPO = "astral-sh/python-build-standalone"
NAME = re.compile(r"^cpython-3\.12\.\d+\+\d+-aarch64-apple-darwin-install_only\.tar\.gz$")


def get(url, raw=False):
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "rvcmac-build"})
    tok = os.environ.get("GITHUB_TOKEN")
    if tok and "api.github.com" in url:
        req.add_header("Authorization", f"Bearer {tok}")
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read()
    return data if raw else json.loads(data)


tag = os.environ.get("PYTHON_BUILD_TAG")
rel = get(f"https://api.github.com/repos/{REPO}/releases/" + (f"tags/{tag}" if tag else "latest"))
assets = rel.get("assets", [])
asset = next((a for a in assets if NAME.match(a["name"])), None)
if not asset:
    sys.exit(f"no CPython 3.12 aarch64 install_only asset in {rel.get('tag_name')}")
sha = (asset.get("digest") or "").removeprefix("sha256:")
if not sha:
    sums = next((a for a in assets if a["name"] == "SHA256SUMS"), None)
    if sums:
        for line in get(sums["browser_download_url"], raw=True).decode().splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[1] == asset["name"]:
                sha = parts[0]
if not re.fullmatch(r"[0-9a-f]{64}", sha or ""):
    sys.exit(f"no sha256 for {asset['name']}")
print(asset["browser_download_url"], sha)
