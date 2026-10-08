#!/usr/bin/env python3
"""Build a deterministic, bundled pi-subagents closure from pinned inputs."""
import gzip
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PIN = json.loads((ROOT / "pi-subagents-pin.json").read_text())
SOURCE = ROOT / PIN["sourceArchive"]["path"]
LOCK = ROOT / PIN["lockfile"]["path"]
OUTPUT = ROOT / PIN["closure"]["path"]
EPOCH = 946684800


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    if sha256(SOURCE) != PIN["sourceArchive"]["sha256"]:
        raise SystemExit("source archive SHA-256 mismatch")
    if sha256(LOCK) != PIN["lockfile"]["sha256"]:
        raise SystemExit("fork lockfile SHA-256 mismatch")
    with tempfile.TemporaryDirectory(prefix="tron-pi-subagents-closure-") as temporary:
        root = pathlib.Path(temporary) / "package"
        root.mkdir()
        with tarfile.open(SOURCE, "r:gz") as archive:
            for member in archive.getmembers():
                if not member.name.startswith("package/") or pathlib.PurePosixPath(member.name).is_absolute() or ".." in pathlib.PurePosixPath(member.name).parts:
                    raise SystemExit("unsafe source archive path")
                if not (member.isdir() or member.isfile()):
                    raise SystemExit("source archive may contain only regular files and directories")
                destination = pathlib.Path(temporary) / member.name
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as source, destination.open("wb") as output:
                        shutil.copyfileobj(source, output)
                    destination.chmod(member.mode & 0o755)
        shutil.copyfile(LOCK, root / "package-lock.json")
        manifest_path = root / "package.json"
        manifest = json.loads(manifest_path.read_text())
        if manifest.get("name") != PIN["name"] or manifest.get("version") != PIN["version"]:
            raise SystemExit("source package identity does not match pin")
        declared = manifest.get("dependencies", {})
        lock = json.loads((root / "package-lock.json").read_text())
        locked_root = lock.get("packages", {}).get("")
        if not isinstance(locked_root, dict) or locked_root.get("dependencies") != declared:
            raise SystemExit("fork lockfile root dependencies do not match source manifest")
        manifest["bundledDependencies"] = sorted(declared)
        canonical_manifest = (json.dumps(manifest, indent=2) + "\n").encode()
        # npm ci validates even omitted development dependencies. Runtime-only
        # predecessor locks must not resolve them; preserve them in the artifact.
        install_manifest = {key: value for key, value in manifest.items() if key != "devDependencies"}
        manifest_path.write_text(json.dumps(install_manifest, indent=2) + "\n")
        npm = shutil.which("npm")
        if not npm:
            raise SystemExit("npm is unavailable")
        subprocess.run([npm, "ci", "--omit=dev", "--omit=peer", "--ignore-scripts", "--no-audit", "--no-fund"], cwd=root, check=True)
        manifest_path.write_bytes(canonical_manifest)
        assert manifest_path.read_bytes() == canonical_manifest, "packaged manifest must preserve source metadata and bundledDependencies"
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        temporary_output = OUTPUT.with_suffix(OUTPUT.suffix + ".tmp")
        with temporary_output.open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as archive:
                    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root.parent).as_posix()):
                        relative = path.relative_to(root.parent).as_posix()
                        info = archive.gettarinfo(str(path), arcname=relative)
                        info.uid = info.gid = 0
                        info.uname = info.gname = ""
                        info.mtime = EPOCH
                        info.pax_headers = {}
                        info.mode = 0o755 if (path.is_dir() or path.stat().st_mode & 0o111) else 0o644
                        if path.is_file():
                            with path.open("rb") as source:
                                archive.addfile(info, source)
                        else:
                            archive.addfile(info)
        os.replace(temporary_output, OUTPUT)
    digest = hashlib.sha512(OUTPUT.read_bytes()).hexdigest()
    print(f"{OUTPUT.relative_to(ROOT)} sha512={digest}")


if __name__ == "__main__":
    main()
