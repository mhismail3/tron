#!/usr/bin/env python3
"""The gate updates main only after every check passes inside its deadline, and refuses everything else."""
from __future__ import annotations

import io
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout

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
        self.assertEqual(self.admit(self.run_steps(['sleep', '30']), deadline=2, step=30), 1)
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


if __name__ == '__main__':
    unittest.main()
