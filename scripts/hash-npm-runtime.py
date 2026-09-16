#!/usr/bin/env python3
"""Hash an extracted npm tree using canonical relative paths and file bytes.

The Node archive is the provenance authority; this digest only authenticates
that the staged npm tree still matches the archive extraction. Symlinks and
special files are rejected rather than followed.
"""
import hashlib
import os
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: hash-npm-runtime.py NPM_ROOT")
root = os.path.realpath(sys.argv[1])
if not os.path.isdir(root) or os.path.islink(sys.argv[1]):
    raise SystemExit("npm root must be a regular directory")

records = []
for directory, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
    dirnames.sort()
    filenames.sort()
    relative_directory = os.path.relpath(directory, root)
    if relative_directory != ".":
        records.append((f"directory:{relative_directory}", None))
    for name in filenames:
        path = os.path.join(directory, name)
        relative = os.path.relpath(path, root)
        if os.path.islink(path) or not os.path.isfile(path):
            raise SystemExit(f"npm tree contains an unsafe entry: {relative}")
        with open(path, "rb") as stream:
            records.append((f"file:{relative}", stream.read()))
    for name in dirnames:
        if os.path.islink(os.path.join(directory, name)):
            raise SystemExit(f"npm tree contains a symlink: {os.path.relpath(os.path.join(directory, name), root)}")
records.sort(key=lambda record: record[0].encode("utf-8"))
digest = hashlib.sha256()
for path, data in records:
    digest.update(path.encode("utf-8"))
    digest.update(b"\0")
    if data is not None:
        digest.update(data)
        digest.update(b"\0")
print(digest.hexdigest())
