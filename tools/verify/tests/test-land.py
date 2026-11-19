#!/usr/bin/env python3
"""scripts/tron land end to end: real land.py, mini.py and host_lock.py, a disposable origin and a stand-in mini.

A disposable checkout lands a task branch onto its own bare origin. The mini is a disposable home reached through
the `ssh` stand-in of test-mini.py, and the commit's own `tools/verify/verify.py` there is a stand-in that records
the commit it validated and fails when the tree holds a planted `RED`. The cases check that a red merge is refused
and main is unchanged; that a main moved during validation is merged again and validated again, and only that new
merge lands; and that two concurrent lands wait in arrival order, the second validated on top of the first.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('mini_fixture', ROOT / 'tools/verify/tests/test-mini.py')
mini_fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mini_fixture)

VERIFY = r'''import json, os, subprocess, sys, time
from pathlib import Path
root = Path(__file__).resolve().parents[2]
home = Path(os.environ['HOME'])
sha = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
with open(home / 'runs', 'a') as runs:
    runs.write(sha + '\n')
if (home / 'hold').exists():
    (home / 'held').write_text(sha)
    while (home / 'hold').exists():
        time.sleep(0.05)
red = (root / 'RED').exists()
out = root / 'test-results/verify'
out.mkdir(parents=True, exist_ok=True)
(out / f'{sha}.json').write_text(json.dumps({'commit': sha, 'verdict': 'failed' if red else 'passed', 'args': sys.argv[1:],
                                              'message': 'planted RED' if red else 'Tiers 0 to 2 passed'}))
sys.exit(1 if red else 0)
'''


class Land(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = Path(tempfile.mkdtemp(prefix='tron-land-test-'))
        self.addCleanup(shutil.rmtree, self.temporary, True)
        self.local, self.mini, self.origin = self.temporary / 'local', self.temporary / 'mini-home', self.temporary / 'origin.git'
        for path in ('tools/verify/land.py', 'tools/verify/mini.py', 'tools/verify/ledger.py', 'scripts/tron-node', '.node-version',
                     'config/ci-toolchain.env'):
            (self.local / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, self.local / path)
        lock = (ROOT / 'tools/verify/host_lock.py').read_text()
        self.write('tools/verify/host_lock.py', lock.replace("'/tmp/tron-land.lock'", repr(str(self.temporary / 'land.lock'))))
        self.write('tools/verify/verify.py', VERIFY)
        self.write('packages/gateway/package.json', json.dumps({'name': 'fixture', 'version': '1.0.0', 'private': True}))
        self.write('packages/gateway/package-lock.json', json.dumps({'name': 'fixture', 'version': '1.0.0', 'lockfileVersion': 3, 'requires': True,
                                                                     'packages': {'': {'name': 'fixture', 'version': '1.0.0'}}}))
        self.write('packages/gateway/.npmrc', 'audit=false\nfund=false\noffline=true\n')
        self.write('packages/gateway/third_party/README', 'vendored tarballs\n')
        self.write('.gitignore', 'test-results/\nnode_modules/\n')
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'tron.verify.mini', 'mini.test')
        self.base = self.commit('base')
        self.git('init', '-q', '--bare', '-b', 'main', str(self.origin))
        self.git('remote', 'add', 'origin', str(self.origin))
        self.git('push', '-q', 'origin', 'main')
        self.git('checkout', '-q', '-b', 'topic')
        bin_dir = self.temporary / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'ssh').write_text(mini_fixture.SSH)
        (bin_dir / 'ssh').chmod(0o755)
        self.git('init', '-q', '--bare', str(self.mini / 'tron-ci/tron.git'))
        node = Path(subprocess.check_output([str(ROOT / 'scripts/tron-node')], text=True).strip())
        (self.mini / '.nvm/versions/node').mkdir(parents=True)
        (self.mini / f'.nvm/versions/node/v{(ROOT / ".node-version").read_text().strip()}').symlink_to(node.parent.parent)
        self.env = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}', 'MINI_HOME': str(self.mini),
                    'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@example.invalid',
                    'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@example.invalid'}

    def write(self, path: str, text: str, tree: Path | None = None) -> None:
        target = (tree or self.local) / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def git(self, *args: str, cwd: Path | None = None) -> str:
        return subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', *args], cwd=cwd or self.local,
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, message: str, cwd: Path | None = None) -> str:
        self.git('add', '-A', cwd=cwd)
        self.git('commit', '-qm', message, cwd=cwd)
        return self.git('rev-parse', 'HEAD', cwd=cwd)

    def land(self, tree: Path | None = None) -> subprocess.Popen:
        tree = tree or self.local
        process = subprocess.Popen(['python3', str(tree / 'tools/verify/land.py')], cwd=tree, env=self.env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        return process

    def finish(self, process: subprocess.Popen) -> tuple[int, str]:
        output = process.communicate(timeout=120)[0]
        return process.returncode, output

    def main(self) -> str:
        return self.git('rev-parse', 'main', cwd=self.origin)

    def runs(self) -> list[str]:
        path = self.mini / 'runs'
        return path.read_text().split() if path.is_file() else []

    def wait_for(self, condition, what: str) -> None:
        deadline = time.monotonic() + 60
        while not condition():
            self.assertLess(time.monotonic(), deadline, f'{what} never happened')
            time.sleep(0.05)

    def parents(self, commit: str) -> list[str]:
        return self.git('rev-list', '--parents', '-n', '1', commit, cwd=self.origin).split()[1:]

    def test_a_red_merge_is_refused_and_main_stays(self) -> None:
        self.write('RED', 'planted fault\n')
        head = self.commit('red change')
        code, output = self.finish(self.land())
        self.assertEqual(code, 1, output)
        self.assertIn('failed: planted RED', output)
        self.assertEqual(self.main(), self.base, 'a red merge never reaches main')
        [validated] = self.runs()
        self.assertEqual(self.git('rev-list', '--parents', '-n', '1', validated).split()[1:], [self.base, head],
                         'it validated the --no-ff merge onto main')

    def test_a_green_merge_lands_as_the_exact_commit_it_validated(self) -> None:
        self.write('feature.txt', 'feature\n')
        head = self.commit('green change')
        code, output = self.finish(self.land())
        self.assertEqual(code, 0, output)
        self.assertEqual(self.runs(), [self.main()], 'main is exactly the validated commit')
        self.assertEqual(self.parents(self.main()), [self.base, head], 'a --no-ff merge whose first parent is the old main')
        self.assertTrue((self.local / 'test-results/land' / self.main() / 'verify.json').is_file(), output)

    def test_a_main_moved_during_validation_is_merged_and_validated_again(self) -> None:
        self.write('feature.txt', 'feature\n')
        head = self.commit('green change')
        (self.mini / 'hold').write_text('')
        process = self.land()
        self.wait_for((self.mini / 'held').is_file, 'the first validation')
        other = self.temporary / 'other'
        self.git('clone', '-q', str(self.origin), str(other))
        self.write('other.txt', 'landed meanwhile\n', other)
        moved = self.commit('landed meanwhile', other)
        self.git('push', '-q', 'origin', 'HEAD:main', cwd=other)
        (self.mini / 'hold').unlink()
        code, output = self.finish(process)
        self.assertEqual(code, 0, output)
        self.assertIn('main moved', output)
        stale, fresh = self.runs()
        self.assertEqual(fresh, self.main(), 'only the revalidated merge lands')
        self.assertEqual(self.parents(fresh), [moved, head])
        self.assertNotEqual(subprocess.run(['git', 'merge-base', '--is-ancestor', stale, 'main'], cwd=self.origin,
                                           capture_output=True).returncode, 0,
                            'the merge validated on the old main never lands')

    def test_two_concurrent_lands_wait_in_order_and_the_second_validates_on_the_first(self) -> None:
        self.write('first.txt', 'first\n')
        first_head = self.commit('first change')
        second = self.temporary / 'second'
        self.git('worktree', 'add', '-q', '-b', 'second', str(second), self.base)
        self.write('second.txt', 'second\n', second)
        second_head = self.commit('second change', second)
        (self.mini / 'hold').write_text('')
        first = self.land()
        self.wait_for((self.mini / 'held').is_file, 'the first validation')
        waiting = self.land(second)
        self.wait_for(lambda: len(list((self.temporary / 'land.lock.queue').glob('*.ticket'))) == 1, 'the second land queuing')
        self.assertEqual(self.runs(), [(self.mini / 'held').read_text()], 'the second waits; it validates nothing yet')
        (self.mini / 'hold').unlink()
        (first_code, first_output), (second_code, second_output) = self.finish(first), self.finish(waiting)
        self.assertEqual(first_code, 0, first_output)
        self.assertEqual(second_code, 0, second_output)
        self.assertIn('waiting for', second_output)
        self.assertNotIn('main moved', second_output, 'the second fetched main only after the first landed')
        one, two = self.runs()
        self.assertEqual(self.main(), two)
        self.assertEqual(self.parents(two), [one, second_head])
        self.assertEqual(self.parents(one), [self.base, first_head])


if __name__ == '__main__':
    unittest.main()
