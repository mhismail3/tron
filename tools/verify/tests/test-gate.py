#!/usr/bin/env python3
"""The gate updates main only after every check passes inside its deadline, and refuses everything else."""
from __future__ import annotations

import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gate  # noqa: E402


def git(cwd: Path, *arguments: str) -> str:
    return subprocess.run(['git', *arguments], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class GateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = Path(tempfile.mkdtemp(prefix='gate-test-'))
        self.remote = self.scratch / 'remote.git'
        git(self.scratch, 'init', '--quiet', '--bare', '--initial-branch=main', str(self.remote))
        self.work = self.scratch / 'work'
        git(self.scratch, 'clone', '--quiet', str(self.remote), str(self.work))
        for key, value in (('user.email', 'gate@test.invalid'), ('user.name', 'gate')):
            git(self.work, 'config', key, value)
        self.commit('base')
        git(self.work, 'push', '--quiet', 'origin', 'HEAD:main')
        git(self.work, 'checkout', '--quiet', '-b', 'change')
        self.tip = self.commit('change')

    def tearDown(self) -> None:
        subprocess.run(['rm', '-rf', str(self.scratch)], check=True)

    def commit(self, name: str) -> str:
        (self.work / name).write_text(name)
        git(self.work, 'add', name)
        git(self.work, 'commit', '--quiet', '-m', name)
        return git(self.work, 'rev-parse', 'HEAD')

    def main(self) -> str:
        return git(self.remote, 'rev-parse', 'main')

    def admit(self, checks, deadline: float = 20, step: float = 10, **options) -> int:
        with redirect_stdout(io.StringIO()):
            return gate.Gate(self.work, deadline, step).admit(checks, **options)

    def run_steps(self, *commands: list[str]):
        return lambda g, tree, base, merged: g.parallel([(f's{i}', c, tree) for i, c in enumerate(commands)], None)

    def test_passing_checks_merge_the_change_onto_main(self) -> None:
        before = self.main()
        self.assertEqual(self.admit(self.run_steps(['true'], ['true'])), 0)
        self.assertEqual(git(self.remote, 'rev-parse', 'main^1'), before)
        self.assertEqual(git(self.remote, 'rev-parse', 'main^2'), self.tip)

    def test_a_failing_check_refuses_and_leaves_main(self) -> None:
        before = self.main()
        self.assertEqual(self.admit(self.run_steps(['true'], ['false'])), 1)
        self.assertEqual(self.main(), before)

    def test_a_step_over_budget_is_stopped_and_refused(self) -> None:
        before = self.main()
        began = time.monotonic()
        self.assertEqual(self.admit(self.run_steps(['sleep', '30']), step=1), 1)
        self.assertLess(time.monotonic() - began, 10)
        self.assertEqual(self.main(), before)

    def test_the_end_to_end_deadline_refuses(self) -> None:
        before = self.main()
        began = time.monotonic()
        self.assertEqual(self.admit(self.run_steps(['sleep', '30']), deadline=2, step=30), 1)
        self.assertLess(time.monotonic() - began, 10)
        self.assertEqual(self.main(), before)

    def test_uncommitted_work_is_refused_before_any_check(self) -> None:
        (self.work / 'loose').write_text('x')
        ran = []
        self.assertEqual(self.admit(lambda *_: ran.append(1)), 1)
        self.assertEqual(ran, [])

    def test_check_mode_runs_checks_without_updating_main(self) -> None:
        before = self.main()
        self.assertEqual(self.admit(self.run_steps(['true']), push='check'), 0)
        self.assertEqual(self.main(), before)

    def test_pre_push_refuses_a_main_update_that_is_not_based_on_main(self) -> None:
        git(self.work, 'checkout', '--quiet', 'main')
        self.commit('other')
        git(self.work, 'push', '--quiet', 'origin', 'HEAD:main')
        self.assertEqual(self.admit(self.run_steps(['true']), tip=self.tip, push='pre-push'), 1)

    def hook(self, lines: str, environment: dict | None = None) -> tuple[int, list]:
        ran = []
        with mock.patch.dict(os.environ, environment or {}), mock.patch('sys.stdin', io.StringIO(lines)), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            code = gate.main(['--pre-push', 'origin'], gate=lambda *a: ran.append(a[3]), root=self.work)
        return code, ran

    def test_pre_push_ignores_other_refs_and_refuses_main_deletion_or_several_updates(self) -> None:
        zero = '0' * 40
        self.assertEqual(self.hook(f'refs/heads/change {self.tip} refs/heads/change {zero}\n'), (0, []))
        self.assertEqual(self.hook(f'(delete) {zero} refs/heads/main {self.main()}\n'), (1, []))
        twice = f'refs/heads/a {self.tip} refs/heads/main {zero}\n' * 2
        self.assertEqual(self.hook(twice), (1, []))

    def test_pre_push_skips_only_the_exact_commit_the_gate_checked(self) -> None:
        line = f'refs/heads/change {self.tip} refs/heads/main {self.main()}\n'
        self.assertEqual(self.hook(line, {gate.TOKEN: self.tip}), (0, []))
        self.assertEqual(self.hook(line, {gate.TOKEN: 'f' * 40})[1], [self.tip], 'another token runs the checks')

    def test_pre_push_from_a_linked_worktree_checks_the_pushed_commit_not_the_hook_gitdir(self) -> None:
        git(self.work, 'merge', '--quiet', 'main')
        tip = git(self.work, 'rev-parse', 'HEAD')
        other = self.scratch / 'other'
        git(self.scratch, 'init', '--quiet', str(other))
        before = git(self.work, 'symbolic-ref', 'HEAD')
        code, ran = self.hook(f'refs/heads/change {tip} refs/heads/main {self.main()}\n',
                              {'GIT_DIR': str(other / '.git'), 'GIT_WORK_TREE': str(other)})
        self.assertEqual((code, ran), (0, [tip]))
        self.assertEqual(git(self.work, 'symbolic-ref', 'HEAD'), before)

    def test_the_tron_entry_point_passes_its_arguments_to_the_gate(self) -> None:
        result = subprocess.run([str(Path(__file__).resolve().parents[3] / 'scripts/tron'), 'gate', '--nope'],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual((result.returncode, result.stderr.strip()), (2, 'usage: scripts/tron gate [--check]'))


if __name__ == '__main__':
    unittest.main()
