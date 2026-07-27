#!/usr/bin/env python3
"""Checks that every relative markdown link (`](path/to/file.md)`) in the
repo resolves to a real file. Used manually throughout several repository
reorganization PRs; formalized here so CI catches the same class of
mistake automatically -- run from anywhere inside the repo.
"""
import os
import re
import subprocess
import sys

repo_root = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()

files = subprocess.check_output(
    ["git", "ls-files", "*.md"], cwd=repo_root, text=True
).splitlines()

link_re = re.compile(r"\]\(([^)]+\.md)(#[^)]*)?\)")

broken = []
for f in files:
    path = os.path.join(repo_root, f)
    with open(path, encoding="utf-8") as fh:
        content = fh.read()
    for m in link_re.finditer(content):
        target = m.group(1)
        if target.startswith(("http://", "https://")):
            continue
        resolved = os.path.normpath(os.path.join(os.path.dirname(path), target))
        if not os.path.isfile(resolved):
            line_no = content[: m.start()].count("\n") + 1
            broken.append((f, line_no, target))

if broken:
    print(f"{len(broken)} broken markdown links:")
    for f, ln, target in broken:
        print(f"  {f}:{ln} -> {target}")
    sys.exit(1)
else:
    print("All markdown links resolve.")
