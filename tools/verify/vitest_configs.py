"""The Gateway Vitest configs that each run one listed set of files, read from that config's own list."""
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
