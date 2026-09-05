#!/usr/bin/env python3
"""Replaces (or appends) key=value lines in an .env file in place.

Used by install.sh instead of `cat >>`, which duplicates any key that
.env.example already declares as a blank placeholder. A real bug that once
caused LibreChat to pick up an empty GMCP_HTTP_TOKEN instead of the real one
and treat gmcp as if it required OAuth. Reads replacement key=value pairs
from stdin (one per line) so no value ever has to be escaped into a shell
command line.
"""
import sys

path = sys.argv[1]

replacements = {}
for line in sys.stdin:
    if not line.strip() or "=" not in line:
        continue
    key, _, value = line.rstrip("\n").partition("=")
    replacements[key] = value

with open(path) as f:
    lines = f.readlines()

seen = set()
out = []
for line in lines:
    stripped = line.rstrip("\n")
    key = stripped.split("=", 1)[0] if "=" in stripped and not stripped.startswith("#") else None
    if key in replacements:
        out.append(f"{key}={replacements[key]}\n")
        seen.add(key)
    else:
        out.append(line)
for key, value in replacements.items():
    if key not in seen:
        out.append(f"{key}={value}\n")

with open(path, "w") as f:
    f.writelines(out)
