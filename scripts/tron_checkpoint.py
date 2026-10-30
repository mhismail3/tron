#!/usr/bin/env python3
"""Rebuild a main candidate and run stage-current smoke probes without deploying it."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

from tron_mac_replace_platform import MacPlatform, Failure, git

ROOT = Path(__file__).resolve().parents[1]
UI = "TronMobileUITests/RealGatewayPairAndChatUITests/"
# Reuse real UI/socket/process oracles, not preview-only tests. Future product
# stages extend these probes when their owning slice ships, not before it exists.
OUTCOMES = [
    ("Chat: pairing, streaming, reconnect and photo steer", [
        "testInvitationLinkPairsCompletesSetupStreamsAndReconnectsAfterBackground",
        "testImageOnlySteerLeavesTheQueueOnceDelivered"], []),
    ("Home continuity and current Profile", ["testHomeStatusShowsHostPressureAndWorkers"], [
        "src/sessions/home-memory-tools.e2e.test.ts",
        "src/modules/home/home-profile-triage.integration.test.ts"]),
    ("Controls: settings persistence and required approvals", [
        "testSettingsOutsideChangesAndBuiltinExtensionPersist",
        "testAgentApprovalRequestsAppearInTheirChatAndSettleEverywhere"], [
        "src/admin/settings-approval-outcomes.e2e.test.ts"]),
    ("Files/artifacts/research: uploads, reopen and source reads", [
        "testTronMenuListsInstalledAppAndKeepsItsValuesAcrossReopen"], [
        "src/display/display.store.lock.integration.test.ts",
        "src/sessions/home-research-tools.integration.test.ts"]),
    ("Independent SSH access and protocol/release identity", [
        "testMacReplacementRowAndProgressFollowTheJournal"], [
        "src/security/mac-terminal.e2e.test.ts",
        "src/protocol/protocol.wire.lock.integration.test.ts"]),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test-mode", action="store_true", help="committed HEAD, disposable build/state; no reinstall preparation")
    parser.add_argument("--prepare-reinstall", action="store_true", help="maintainer: prepare existing mac reinstall receipt after a green checkpoint; never installs")
    args = parser.parse_args()
    if args.test_mode and args.prepare_reinstall:
        parser.error("--test-mode cannot prepare a live reinstall")
    if not args.test_mode:
        git(ROOT, "fetch", "--no-tags", "origin", "refs/heads/main:refs/remotes/origin/main")
    revision = git(ROOT, "rev-parse", "HEAD" if args.test_mode else "origin/main")
    result = ROOT / "test-results/checkpoint" / revision
    result.mkdir(parents=True, exist_ok=True)
    report = {"revision": revision, "test_mode": args.test_mode, "build": "NOT RUN", "outcomes": []}

    def save():
        target = result / "report.json"
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(target)

    def run(source, argv, log, env=None):
        with (result / log).open("a") as stream:
            stream.write("$ " + " ".join(map(str, argv)) + "\n"); stream.flush()
            # The existing harness owns its processes, simulator lease and the
            # three host slots. Forward cancellation and wait for its cleanup.
            child = subprocess.Popen(list(map(str, argv)), cwd=source, env=env, stdout=stream, stderr=subprocess.STDOUT)
            interrupted = []
            def forward(signum, _frame):
                interrupted.append(signum)
                child.send_signal(signum)
            previous = {s: signal.signal(s, forward) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
            try:
                status = child.wait()
                if interrupted:
                    report["interrupted_signal"] = interrupted[0]
                    save()
                    raise KeyboardInterrupt
                return status
            finally:
                for s, handler in previous.items():
                    signal.signal(s, handler)

    save()
    with tempfile.TemporaryDirectory(prefix="tron-checkpoint-") as temporary:
        # MacPlatform.build is the existing signed full-build path. Calling it
        # alone cannot quit, swap, launch or restart anything.
        platform = MacPlatform(home=temporary) if args.test_mode else MacPlatform()
        source = platform.checkout(ROOT, revision)
        fixture = Path(temporary) / "fixture"
        derived = Path(temporary) / "derived"
        # The signed full build already installed this exact lockfile. Reuse
        # that tree through the harness's existing no-install option, rather
        # than running npm ci again from a different working directory.
        environment = {**os.environ, "TRON_IOS_E2E_STATE_DIR": str(fixture), "TRON_IOS_E2E_DERIVED_DATA": str(derived), "TRON_IOS_E2E_NO_INSTALL": "1"}
        try:
            try:
                # Reuse the existing descendant-aware process owner so a stop
                # during npm/Xcode also joins the detached build descendants.
                build_code = "import sys; sys.path.insert(0, sys.argv[1] + '/scripts'); from tron_mac_replace_platform import MacPlatform; MacPlatform(home=sys.argv[2]).build(sys.argv[1], sys.argv[3], sys.argv[4])"
                status = run(source, [sys.executable, source / "scripts/ios-test-process.py",
                    "--log", result / "build-process.log", "--evidence-dir", result / "build-process",
                    "--overall-seconds", "3600", "--no-output-seconds", "3600", "--",
                    sys.executable, "-c", build_code, ROOT, platform.home, revision, result / "build.log"], "build-driver.log")
                app = platform.built_app(revision)
                if status == 0:
                    status = run(source, [source / "packages/mac-app/scripts/test-signed-pi-payload-smoke.sh", app], "build.log")
                report["build"] = "PASS" if status == 0 else "FAIL"
            except KeyboardInterrupt:
                report["build"] = "INTERRUPTED"
                save()
                raise
            except Failure as error:
                report["build"] = "FAIL"
                report["build_error"] = str(error)
            print(f'{report["build"]} Mac + bundled Gateway build ({revision})', flush=True)
            save()
            for index, (name, journeys, tests) in enumerate(OUTCOMES, 1):
                outcome = {"name": name, "status": "RUNNING", "commands": []}
                report["outcomes"].append(outcome); save()
                commands = [[source / "scripts/ios-gateway-e2e-test", "run-ui", "--only-testing", UI + journey] for journey in journeys]
                if index == 4:
                    commands.append([source / "scripts/ios-gateway-e2e-test", "all"])
                if tests:
                    commands.append([source / "scripts/tron", "test", "gateway", *tests])
                statuses = []
                for number, command in enumerate(commands, 1):
                    status = run(source, command, f"outcome-{index}-{number}.log", environment)
                    statuses.append(status)
                    outcome["commands"].append({"argv": list(map(str, command)), "exit": status})
                    save()
                outcome["status"] = "PASS" if all(s == 0 for s in statuses) else "FAIL"
                print(f'{outcome["status"]} S{index}: {name}', flush=True)
                save()
            if args.prepare_reinstall and report["build"] == "PASS" and all(o["status"] == "PASS" for o in report["outcomes"]):
                report["reinstall_preparation"] = run(source, [source / "scripts/tron", "mac", "reinstall", "--app", app], "reinstall.log")
                save()
        finally:
            # Preserve xcresults/logs even if another outcome failed. The
            # harness's clean owns fixture shutdown and lane/product removal.
            if (fixture / "results").exists():
                shutil.copytree(fixture / "results", result / "journeys", symlinks=True, dirs_exist_ok=True)
                latest = result / "journeys/latest-ui"
                if latest.is_symlink():
                    name = latest.readlink().name
                    latest.unlink()
                    latest.symlink_to(name)
            cleanup = run(source, [source / "scripts/ios-gateway-e2e-test", "clean"], "cleanup.log", environment)
            report["cleanup_exit"] = cleanup
            if args.test_mode:
                git(ROOT, "worktree", "remove", "--force", source)
            save()
    print(f"Partial/full evidence: {result}", flush=True)
    passed = report["build"] == "PASS" and all(o["status"] == "PASS" for o in report["outcomes"]) and report["cleanup_exit"] == 0 and report.get("reinstall_preparation", 0) == 0
    return 0 if passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except (Failure, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
