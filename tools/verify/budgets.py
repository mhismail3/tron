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
PLACEHOLDER = re.compile(r'(%%|%[sdifjoOc#]|\$[A-Za-z_][\w.]*)')


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


def budgets(root: Path) -> dict[str, list[dict]]:
    """Per Gateway test file: its tests' (title, Vitest timeout, smallest wait bound) list; a test without its own wait takes the file helpers' bound."""
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
        result[f'{GATEWAY}/{relative}'] = entries
    return result


def budget_of(file: list[dict], name: str) -> dict | None:
    """The case whose title, with Vitest's %s/%i/%d/$name placeholders as wildcards and %% as %, ends the recorded name; None when no case or several disagreeing cases match."""
    matches = []
    for case in file:
        if case['title']:
            pattern = ''.join(('%' if part == '%%' else '.+') if index % 2 else re.escape(part)
                              for index, part in enumerate(PLACEHOLDER.split(case['title'])))
            if re.search(r'(?:^|\s)' + pattern + r'$', name, re.S):
                matches.append(case)
    budgets = {(case['timeoutMs'], case['waitMs']) for case in matches}
    return matches[0] if len(budgets) == 1 else None
