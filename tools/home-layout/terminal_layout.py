"""Retires owned SSH jobs and carries plist enablement across offline layout changes."""

import hashlib
import os
import pwd
import re
import stat
import subprocess
import sys
import time
from pathlib import Path
from xml.sax.saxutils import escape


def label(root):
    return "com.tron.mac-terminal." + hashlib.sha256(os.fsencode(root)).hexdigest()[:16]


def plist(root):
    arguments = "".join("<string>" + escape(value, {'"': "&quot;"}) + "</string>" for value in ("/usr/sbin/sshd", "-D", "-e", "-f", str(root / "sshd_config")))
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0"><dict><key>Label</key><string>' + label(root) + '</string><key>Program</key><string>/usr/sbin/sshd</string><key>ProgramArguments</key><array>' + arguments
            + '</array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer><key>AbandonProcessGroup</key><true/></dict></plist>\n').encode()


def coordinates(report, reverse):
    home = Path(report["home"])
    old, new = home / "mac-terminal", home / "state/mac-terminal"
    source, destination = (new, old) if reverse else (old, new)
    directory = Path(report["user_home"]) / "Library/LaunchAgents"
    return source, destination, directory / (label(source) + ".plist"), directory / (label(destination) + ".plist")


def read(l, r, path):
    info = l.observed(str(path))
    if info is None:
        return None
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077
            or info.st_size > 1048576 or l.linked_component(str(path), "/")):
        raise l.LayoutError("unsafe_terminal_file")
    return r.read_record(l, path)[0]


RETIRE_DEADLINE = 30


def command(l, arguments, timeout=3):
    try:
        return subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise l.LayoutError("terminal_command_failed") from None


def job(l, root, path):
    result = command(l, ["/bin/launchctl", "print", f"gui/{os.getuid()}/{label(root)}"])
    if result.returncode:
        if result.returncode == 113 or "Could not find service" in result.stderr:
            return None
        raise l.LayoutError("terminal_job_unavailable")
    fields = {name: re.search(r"^\s*" + name + r" = (.+)$", result.stdout, re.M) for name in ("path", "program", "state", "pid")}
    arguments = re.search(r"arguments = \{\n([\s\S]*?)\n\s*\}", result.stdout)
    values = [line.strip() for line in arguments[1].splitlines() if line.strip()] if arguments else []
    if (not fields["path"] or fields["path"][1].strip() != str(path) or not fields["program"] or fields["program"][1].strip() != "/usr/sbin/sshd"
            or values != ["/usr/sbin/sshd", "-D", "-e", "-f", str(root / "sshd_config")]):
        raise l.LayoutError("terminal_job_not_owned")
    return {"running": bool(fields["state"] and fields["state"][1].strip() == "running" and fields["pid"])}


def retire_job(l, root, path, fence):
    if job(l, root, path) is None:
        return
    fence()
    deadline = time.monotonic() + RETIRE_DEADLINE
    command(l, ["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{label(root)}"], RETIRE_DEADLINE)
    while job(l, root, path) is not None:
        if time.monotonic() >= deadline:
            raise l.LayoutError("terminal_job_did_not_retire")
        time.sleep(0.1)
    fence()


def configuration(l, root, data):
    text = data.decode("utf-8")
    port = re.search(r"^Port ([0-9]+)$", text, re.M)
    ip = re.search(r"^ListenAddress (100\.(?:[0-9]+\.){2}[0-9]+)$", text, re.M)
    if not port or not 1024 <= int(port[1]) <= 65535 or not ip:
        raise l.LayoutError("terminal_config_not_owned")
    octets = [int(value) for value in ip[1].split(".")]
    if not 64 <= octets[1] <= 127 or any(value > 255 for value in octets):
        raise l.LayoutError("terminal_config_not_owned")
    expected = ["AddressFamily inet", "Port " + port[1], "ListenAddress " + ip[1], f'HostKey "{root}/ssh_host_ed25519_key"',
                f'AuthorizedKeysFile "{root}/authorized_keys"', f'PidFile "{root}/sshd.pid"', "AllowUsers " + pwd.getpwuid(os.getuid()).pw_name,
                "AuthenticationMethods publickey", "PubkeyAuthentication yes", "PubkeyAcceptedAlgorithms ecdsa-sha2-nistp256", "PasswordAuthentication no",
                "KbdInteractiveAuthentication no", "UsePAM no", "StrictModes yes", "PermitRootLogin no", "DisableForwarding yes", "PermitUserEnvironment no",
                "PermitUserRC no", "PermitTTY yes", ""]
    if text != "\n".join(expected):
        raise l.LayoutError("terminal_config_not_owned")


def inspect(l, r, report, root):
    directory = Path(report["user_home"]) / "Library/LaunchAgents"
    path = directory / (label(root) + ".plist")
    payload = read(l, r, path)
    info = l.observed(str(root))
    if info is None and payload is None:
        return False, None
    if payload is not None and payload != plist(root):
        raise l.LayoutError("terminal_plist_not_owned")
    running = job(l, root, path) if sys.platform == "darwin" else None
    if payload is not None or running is not None:
        if sys.platform != "darwin":
            raise l.LayoutError("terminal_requires_macos")
        if read(l, r, root / "ssh_host_ed25519_key") is None:
            raise l.LayoutError("terminal_identity_missing")
        config = read(l, r, root / "sshd_config")
        if config is not None:
            configuration(l, root, config)
    return payload is not None, running


def plan(l, r, report, root, owned=None):
    home = Path(report["home"])
    for path in (home / "mac-terminal.lock", r.physical(l, home, "gateway", "state") / "mac-terminal.lock"):
        info = l.observed(str(path))
        if info is not None and time.time() - info.st_mtime < l.RUNTIME_LOCK_STALE_SECONDS and (owned is None or (info.st_dev, info.st_ino) not in owned):
            report["blockers"].append("terminal_runtime_lock_present")
    enabled, running = inspect(l, r, report, root)
    report["terminal"] = {"enabled": enabled, "job_loaded": running is not None, "label": label(root)}


def lock(l, r, report, locks, guards, owned):
    home = Path(report["home"])
    old = home / "mac-terminal"
    new = home / "state/mac-terminal"
    if not any(l.observed(str(path)) is not None for path in (old, new, coordinates(report, False)[2], coordinates(report, False)[3])):
        return
    guards.append(locks.enter_context(l.runtime_lock(home / "mac-terminal.lock", interval=1, owned=owned)))
    def location():
        return r.physical(l, home, "gateway", "state") / "mac-terminal.lock"
    guards.append(locks.enter_context(l.runtime_lock(location(), locate=location, interval=1, owned=owned)))


def validate(l, records):
    if not isinstance(records, dict) or not records.keys() <= {"forward", "rollback"}:
        raise l.LayoutError("invalid_journal")
    for phase, saved in records.items():
        if (not isinstance(saved, dict) or saved.keys() != {"enabled", "sha256", "source"} or type(saved["enabled"]) is not bool
                or saved["source"] not in {"legacy", "canonical"} or (phase == "forward" and saved["source"] != "legacy")
                or (saved["sha256"] is not None and (not isinstance(saved["sha256"], str) or re.fullmatch(r"[a-f0-9]{64}", saved["sha256"]) is None))
                or (saved["sha256"] is not None and not saved["enabled"])
                or (saved["enabled"] and saved["sha256"] is None and (phase != "rollback" or not records.get("forward", {}).get("enabled")))):
            raise l.LayoutError("invalid_journal")


def endpoints(report, saved, reverse):
    old, new, old_plist, new_plist = coordinates(report, False)
    source, before = (old, old_plist) if saved["source"] == "legacy" else (new, new_plist)
    return source, old if reverse else new, before, old_plist if reverse else new_plist


def validate_backups(l, r, report, layout):
    for direction, saved in layout["terminal"].items():
        if saved["sha256"] is None:
            continue
        reverse = direction == "rollback"
        source, _, _, _ = endpoints(report, saved, reverse)
        snapshot = r.backup_root(report, layout, reverse) / "mac-terminal.plist"
        if l.observed(str(snapshot)) is None or r.file_sha(snapshot) != saved["sha256"] or read(l, r, snapshot) != plist(source):
            raise l.LayoutError("rewrite_backup_changed")


def retire(l, r, report, layout, journal, journal_path, reverse, fence):
    direction = "rollback" if reverse else "forward"
    root = r.backup_root(report, layout, reverse)
    saved = layout["terminal"].get(direction)
    if saved is None:
        current = r.physical(l, report["home"], "mac-terminal", "state/mac-terminal")
        canonical = reverse and current == Path(report["home"]) / "state/mac-terminal"
        saved = {"source": "canonical" if canonical else "legacy", "enabled": False, "sha256": None}
        source, destination, before, after = endpoints(report, saved, reverse)
        payload = read(l, r, before)
        if payload is not None and payload != plist(source):
            raise l.LayoutError("terminal_plist_not_owned")
        if before != after and read(l, r, after) is not None:
            raise l.LayoutError("terminal_destination_exists")
        inherited = reverse and layout["direction"] == "rollback-partial" and layout["terminal"].get("forward", {}).get("enabled")
        if inherited and payload is None:
            validate_backups(l, r, report, layout)
        saved.update(enabled=payload is not None or bool(inherited), sha256=hashlib.sha256(payload).hexdigest() if payload is not None else None)
        layout["terminal"][direction] = saved
        l.write_journal(journal_path, journal)
    source, destination, before, after = endpoints(report, saved, reverse)
    snapshot = root / "mac-terminal.plist"
    if saved["sha256"] is not None:
        if l.observed(str(snapshot)) is None:
            if read(l, r, before) != plist(source):
                raise l.LayoutError("terminal_plist_changed")
            r.clone(l, before, snapshot)
        if r.file_sha(snapshot) != saved["sha256"] or read(l, r, snapshot) != plist(source):
            raise l.LayoutError("rewrite_backup_changed")
    elif read(l, r, before) is not None:
        raise l.LayoutError("terminal_plist_changed")
    if read(l, r, after) not in (None, plist(destination)):
        raise l.LayoutError("terminal_destination_exists")
    if source == destination:
        return
    if reverse and saved["enabled"] and not any("state/mac-terminal/sshd_config" in layout[phase] for phase in ("inverse", "rewrites")):
        raise l.LayoutError("terminal_config_missing")
    if sys.platform == "darwin" and l.observed(str(source)) is not None:
        retire_job(l, source, before, fence)
    fence()
    if read(l, r, before) is not None:
        before.unlink()
        l.fsync_directory(str(before.parent))
    if saved["enabled"] and l.observed(str(source / "sshd_config")) is not None:
        key = "state/mac-terminal/sshd_config"
        record = (layout["inverse"] if reverse else layout["rewrites"]).get(key)
        if record is None:
            raise l.LayoutError("terminal_config_not_backed_up")
        r.snapshots(l, record, r.receipt_paths(report, layout, key, record, reverse))
        (source / "sshd_config").unlink()
        l.fsync_directory(str(source))


def publish(l, root, path, payload):
    if l.observed(str(path)) is not None:
        if path.read_bytes() != payload:
            raise l.LayoutError("terminal_destination_exists")
        return
    l.private_directory(root)
    l.private_directory(path.parent)
    temporary = root / "terminal-publish.partial"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    l.rename_exclusive(str(temporary), str(path))


def finish(l, r, report, layout, reverse):
    _, destination, _, target = coordinates(report, reverse)
    saved = layout["terminal"].get("rollback" if reverse else "forward")
    if saved is None or not saved["enabled"]:
        return
    root = r.backup_root(report, layout, reverse)
    if reverse and l.observed(str(destination / "sshd_config")) is None:
        key = "state/mac-terminal/sshd_config"
        inverse = layout["inverse"].get(key)
        forward = layout["rewrites"].get(key)
        if inverse is not None:
            _, data = r.snapshots(l, inverse, r.receipt_paths(report, layout, key, inverse, True))
        elif forward is not None:
            data, _ = r.snapshots(l, forward, r.receipt_paths(report, layout, key, forward))
        else:
            raise l.LayoutError("terminal_config_missing")
        configuration(l, destination, data)
        publish(l, root, destination / "sshd_config", data)
    publish(l, root, target, plist(destination))
    if reverse and job(l, destination, target) is None:
        result = command(l, ["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(target)])
        if result.returncode:
            raise l.LayoutError("terminal_restart_failed")
