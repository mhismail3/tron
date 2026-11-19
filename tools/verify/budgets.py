"""The real-time bound each Gateway test runs under: its Vitest timeout and the smallest wait bound it awaits."""
from __future__ import annotations

from pathlib import Path
import re

import vitest_configs

GATEWAY = 'packages/gateway'
WAITS = re.compile(r'\b(?:waitFor|awaitsWithin)\(')
BOUND = re.compile(r'boundMs:\s*([A-Za-z_][\w.]*|[0-9][0-9_]*)|awaitsWithin\([^;]*?,\s*([A-Z_][A-Z0-9_]*|[0-9][0-9_]*)\)\s*;')
CASE = re.compile(r'^([ \t]*)(?:it|test)(?:\.each\([^\n]*?\))?\(\s*', re.M)
HOOK = re.compile(r'^([ \t]*)(?:beforeEach|afterEach)\(', re.M)
CONSTANT = r'\b(?:const|let)\s+{}\s*=\s*([0-9][0-9_]*)\s*;'
PLACEHOLDER = re.compile(r'(%[sdifjoOc#%]|\$[A-Za-z_][\w.]*)')
VITEST_HOOK_TIMEOUT_MS = 10_000


def number(text: str, source: str, defaults: dict[str, int]) -> int | None:
    if text[0].isdigit():
        return int(text.replace('_', ''))
    found = re.search(CONSTANT.format(re.escape(text)), source)
    return int(found.group(1).replace('_', '')) if found else defaults.get(text)


def config_bounds(gateway: Path) -> dict[str, tuple[int, int, int]]:
    """Each Vitest config's (testTimeout, default wait bound, hookTimeout) in milliseconds."""
    waits = gateway / 'test-support/wait-for.ts'
    hang = int(re.search(r'declared\s*:\s*([0-9_]+)', waits.read_text()).group(1).replace('_', ''))
    bounds = {}
    for config in ['vitest.config.ts', *vitest_configs.LISTS]:
        text = (gateway / config).read_text()
        timeout = re.search(r'testTimeout:\s*([0-9_]+)', text)
        declared = re.search(r'TRON_TEST_WAIT_HANG_BOUND_MS:\s*"([0-9]+)"', text)
        hook = re.search(r'hookTimeout:\s*([0-9_]+)', text)
        bounds[config] = (int(timeout.group(1).replace('_', '')) if timeout else 5_000, int(declared.group(1)) if declared else hang,
                          int(hook.group(1).replace('_', '')) if hook else VITEST_HOOK_TIMEOUT_MS)
    return bounds


def cases(source: str) -> list[tuple[str, str, str, int]]:
    """Each test's leading title literal, body text up to the next test, indentation and offset."""
    matches = list(CASE.finditer(source))
    found = []
    for index, match in enumerate(matches):
        body = source[match.end():matches[index + 1].start() if index + 1 < len(matches) else len(source)]
        title = re.match(r'(["\'`])((?:\\.|(?!\1).)*)\1', body)
        found.append((title.group(2) if title else '', body, match.group(1), match.start()))
    return found


def hooks(source: str, default: int) -> list[tuple[int, int, int, int]]:
    """Each beforeEach/afterEach as (block start, block end, indentation width, timeout ms); its block is the enclosing indentation range."""
    lines = source.split('\n')
    starts = [0]
    for line in lines:
        starts.append(starts[-1] + len(line) + 1)
    indent = [len(line) - len(line.lstrip()) if line.strip() else None for line in lines]
    found = []
    for match in HOOK.finditer(source):
        row, width = source.count('\n', 0, match.start()), len(match.group(1))
        before = next((index for index in range(row - 1, -1, -1) if indent[index] is not None and indent[index] < width), -1)
        after = next((index for index in range(row + 1, len(lines)) if indent[index] is not None and indent[index] < width), len(lines))
        close = next((lines[index] for index in range(row, after) if (index == row and re.search(r'\)\s*;?\s*$', lines[index]))
                      or (index > row and indent[index] == width and lines[index].lstrip().startswith('}'))), '')
        own = re.search(r',\s*([0-9][0-9_]*|[A-Z_][A-Z0-9_]*)\s*\)\s*;?\s*$', close)
        found.append((starts[before + 1], starts[after], width, (number(own.group(1), source, {}) if own else None) or default))
    return found


def waits(text: str, source: str, default: int, hook: int) -> list[int]:
    bounds = [bound for match in BOUND.finditer(text)
              if (bound := number(match.group(1) or match.group(2), source, {'HOOK_HANG_BOUND_MS': hook, 'WAIT_HANG_BOUND_MS': default})) is not None]
    plain = len(WAITS.findall(text)) - len(bounds)
    return bounds + ([default] if plain > 0 else [])


def budgets(root: Path) -> dict[str, dict]:
    """Per Gateway test file: its config, test timeout and per-case (title, timeout, enclosing hook timeouts, wait bound) list; cases without a wait inherit the file helpers' bound."""
    gateway = root / GATEWAY
    bounds = config_bounds(gateway)
    hook = int(re.search(r'HOOK_HANG_BOUND_MS\s*=\s*([0-9_]+)', (gateway / 'test-support/wait-for.ts').read_text()).group(1).replace('_', ''))
    owners = {path: config for config, paths in vitest_configs.listed_files(gateway).items() for path in paths}
    result = {}
    for path in sorted((gateway / 'src').rglob('*.test.ts')):
        relative = path.relative_to(gateway).as_posix()
        config = owners.get(relative, 'vitest.config.ts')
        timeout, default, hook_default = bounds[config]
        source = path.read_text()
        found = cases(source)
        around = hooks(source, hook_default)
        helpers = source
        for _title, body, _indent, _offset in found:
            helpers = helpers.replace(body, '')
        helper = min(waits(helpers, source, default, hook), default=None)
        entries = []
        for title, body, indent, offset in found:
            own = re.search(r'^' + indent + r'\}\s*,\s*(?:\{\s*timeout:\s*)?([0-9][0-9_]*|[A-Z_][A-Z0-9_]*)\s*\}?\s*\)', body, re.M) \
                or re.match(r'(?:["\'`][^\n]*?["\'`])\s*,\s*\{\s*timeout:\s*([0-9][0-9_]*|[A-Z_][A-Z0-9_]*)', body)
            limit = (number(own.group(1), source, {}) if own else None) or timeout
            bound = min(waits(body, source, default, hook), default=helper)
            hook_ms = sum(ms for start, end, width, ms in around if start <= offset < end and len(indent) >= width)
            entries.append({'title': title, 'timeoutMs': limit, 'hookMs': hook_ms, 'waitMs': bound})
        result[f'{GATEWAY}/{relative}'] = {'config': config, 'timeoutMs': timeout, 'cases': entries}
    return result


def budget_of(file: dict, name: str) -> dict | None:
    """The case whose title, with Vitest's %s/%i/%d/$name placeholders as wildcards, ends the recorded name; None when no case or several disagreeing cases match."""
    matches = []
    for case in file['cases']:
        if case['title']:
            pattern = ''.join('.+' if index % 2 else re.escape(part) for index, part in enumerate(PLACEHOLDER.split(case['title'])))
            if re.search(r'(?:^|\s)' + pattern + r'$', name, re.S):
                matches.append(case)
    budgets = {(case['timeoutMs'], case['hookMs'], case['waitMs']) for case in matches}
    return matches[0] if len(budgets) == 1 else None
