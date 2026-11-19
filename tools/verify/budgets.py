"""The real-time bound each Gateway test runs under: its Vitest timeout and the smallest wait bound it awaits."""
from __future__ import annotations

from pathlib import Path
import re

import vitest_configs

GATEWAY = 'packages/gateway'
WAITS = re.compile(r'\b(?:waitFor|awaitsWithin)\(')
BOUND = re.compile(r'boundMs:\s*([A-Za-z_][\w.]*|[0-9][0-9_]*)|awaitsWithin\([^;]*?,\s*([A-Z_][A-Z0-9_]*|[0-9][0-9_]*)\)\s*;')
CASE = re.compile(r'^([ \t]*)(?:it|test)(?:\.each\([^\n]*?\))?\(\s*', re.M)
CONSTANT = r'\b(?:const|let)\s+{}\s*=\s*([0-9][0-9_]*)\s*;'


def number(text: str, source: str, defaults: dict[str, int]) -> int | None:
    if text[0].isdigit():
        return int(text.replace('_', ''))
    found = re.search(CONSTANT.format(re.escape(text)), source)
    return int(found.group(1).replace('_', '')) if found else defaults.get(text)


def config_bounds(gateway: Path) -> dict[str, tuple[int, int]]:
    """Each Vitest config's (testTimeout, default wait bound) in milliseconds."""
    waits = gateway / 'test-support/wait-for.ts'
    hang = int(re.search(r'declared\s*:\s*([0-9_]+)', waits.read_text()).group(1).replace('_', ''))
    bounds = {}
    for config in ['vitest.config.ts', *vitest_configs.LISTS]:
        text = (gateway / config).read_text()
        timeout = re.search(r'testTimeout:\s*([0-9_]+)', text)
        declared = re.search(r'TRON_TEST_WAIT_HANG_BOUND_MS:\s*"([0-9]+)"', text)
        bounds[config] = (int(timeout.group(1).replace('_', '')) if timeout else 5_000, int(declared.group(1)) if declared else hang)
    return bounds


def cases(source: str) -> list[tuple[str, str, str]]:
    """Each test's leading title literal, body text up to the next test, and indentation."""
    matches = list(CASE.finditer(source))
    found = []
    for index, match in enumerate(matches):
        body = source[match.end():matches[index + 1].start() if index + 1 < len(matches) else len(source)]
        title = re.match(r'(["\'`])((?:\\.|(?!\1).)*)\1', body)
        found.append((title.group(2) if title else '', body, match.group(1)))
    return found


def waits(text: str, source: str, default: int, hook: int) -> list[int]:
    bounds = [bound for match in BOUND.finditer(text)
              if (bound := number(match.group(1) or match.group(2), source, {'HOOK_HANG_BOUND_MS': hook, 'WAIT_HANG_BOUND_MS': default})) is not None]
    plain = len(WAITS.findall(text)) - len(bounds)
    return bounds + ([default] if plain > 0 else [])


def budgets(root: Path) -> dict[str, dict]:
    """Per Gateway test file: its config, test timeout and per-case (title, wait bound) list; cases without a wait inherit the file helpers' bound."""
    gateway = root / GATEWAY
    bounds = config_bounds(gateway)
    hook = int(re.search(r'HOOK_HANG_BOUND_MS\s*=\s*([0-9_]+)', (gateway / 'test-support/wait-for.ts').read_text()).group(1).replace('_', ''))
    owners = {path: config for config, paths in vitest_configs.listed_files(gateway).items() for path in paths}
    result = {}
    for path in sorted((gateway / 'src').rglob('*.test.ts')):
        relative = path.relative_to(gateway).as_posix()
        config = owners.get(relative, 'vitest.config.ts')
        timeout, default = bounds[config]
        source = path.read_text()
        found = cases(source)
        helpers = source
        for _title, body, _indent in found:
            helpers = helpers.replace(body, '')
        helper = min(waits(helpers, source, default, hook), default=None)
        entries = []
        for title, body, indent in found:
            own = re.search(r'^' + indent + r'\}\s*,\s*(?:\{\s*timeout:\s*)?([0-9][0-9_]*|[A-Z_][A-Z0-9_]*)\s*\}?\s*\)', body, re.M) \
                or re.match(r'(?:["\'`][^\n]*?["\'`])\s*,\s*\{\s*timeout:\s*([0-9][0-9_]*|[A-Z_][A-Z0-9_]*)', body)
            limit = (number(own.group(1), source, {}) if own else None) or timeout
            bound = min(waits(body, source, default, hook), default=helper)
            entries.append({'title': title, 'timeoutMs': limit, 'waitMs': bound})
        result[f'{GATEWAY}/{relative}'] = {'config': config, 'timeoutMs': timeout, 'cases': entries}
    return result


def budget_of(file: dict, name: str) -> dict:
    """The case whose leading title literal ends the recorded name; a dynamic title takes the file's tightest case."""
    matches = [case for case in file['cases'] if case['title'] and name.endswith(case['title'])]
    pool = matches or file['cases'] or [{'title': '', 'timeoutMs': file['timeoutMs'], 'waitMs': None}]
    return min(pool, key=lambda case: min(case['timeoutMs'], case['waitMs'] or case['timeoutMs']))
