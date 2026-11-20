"""The Gateway Vitest configs that each run one listed set of files, and the one classifier of a selection into them."""
from __future__ import annotations
from pathlib import Path
import re

LISTS = {"vitest.nested.config.ts": "nestedTestFiles", "vitest.mac-terminal.config.ts": "macTerminalTestFiles"}


def listed_files(gateway: Path) -> dict[str, set[str]]:
    """Each listing config's files, relative to the Gateway package; a config this checkout lacks lists none."""
    listed = {}
    for config, name in LISTS.items():
        path = gateway / config
        block = re.search(name + r"\s*=\s*\[(.*?)\]", path.read_text(), re.S) if path.exists() else None
        listed[config] = set(re.findall(r'"([^"]+)"', block.group(1))) if block else set()
    return listed


VALUE_OPTIONS = {'--config', '-c', '--project', '--reporter', '--outputFile', '-t', '--testNamePattern', '--root', '-r', '--dir', '--shard',
                 '--testTimeout', '--hookTimeout', '--teardownTimeout', '--bail', '--retry', '--maxWorkers', '--minWorkers', '--pool',
                 '--environment', '--maxConcurrency', '--sequence.seed', '--exclude'}


def vitest_selection(args: list[str], gateway: Path) -> tuple[str | None, list[tuple[str, str]]]:
    """The config file this Vitest selection names, if any, and each file filter as given and relative to the Gateway package."""
    config, filters, value = None, [], None
    for word in args:
        if value:
            if value in ('--config', '-c'):
                config = word
            value = None
        elif word.split('=', 1)[0] in ('--config', '-c') and '=' in word:
            config = word.split('=', 1)[1]
        elif word in VALUE_OPTIONS:
            value = word
        elif not word.startswith('-'):
            relative = re.sub(r':\d+$', '', word).removeprefix(str(gateway) + '/')
            filters.append((word, relative.removeprefix('./').removeprefix('packages/gateway/')))
    return config, filters


def filter_selects(relative: str, path: str) -> bool:
    """Whether a file filter selects the test file at `path`: Vitest's rule, the path contains the filter ignoring case."""
    return relative.lower() in path.lower()


def with_own_config(args: list[str], gateway: Path) -> list[str]:
    """`args` under the one config that runs every file its filters select: a listing config when that is it.

    A filter selects each test file `filter_selects` matches. Filters selecting files of
    more than one config are refused with each config's command, since any one config would skip the rest."""
    config, filters = vitest_selection(args, gateway)
    if config is not None or not filters:
        return args
    listed = listed_files(gateway)
    owners = {path.relative_to(gateway).as_posix(): None for path in (gateway / 'src').rglob('*.test.ts')}
    owners.update({path: name for name, paths in listed.items() for path in paths})
    selected: dict[str | None, list[str]] = {}
    for word, relative in filters:
        for name in {owner for path, owner in owners.items() if filter_selects(relative, path)} or {None}:
            selected.setdefault(name, []).append(word)
    if len(selected) == 1:
        name = next(iter(selected))
        return args if name is None else ['--config', name, *args]
    options = ' '.join(word for word in args if word not in {raw for raw, _ in filters})
    commands = [' '.join(['scripts/tron test gateway', '--config', name or 'vitest.config.ts', *([options] if options else []), *words])
                for name, words in sorted(selected.items(), key=lambda item: item[0] or '')]
    raise Refused('gateway tests: these files run under different Vitest configs; run each set under its own:\n  '
                  + '\n  '.join(commands))


class Refused(Exception):
    """A selection this runner cannot run as one Vitest process; nothing ran."""
