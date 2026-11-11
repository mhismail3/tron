# Read Swift compiler declaration ranges for verification selection.
from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass


NODE = re.compile(r"^( *)(?:\()([a-z_]+)\b")
RANGE = re.compile(r"range=\[<stdin>:(\d+):(\d+) - line:(\d+):(\d+)\]")
TYPE = re.compile(r'^  \((class_decl|extension_decl)\b.*? "([^"]+)"')
FUNCTION = re.compile(r'^    \(func_decl\b.*? "([^"]+)"')


@dataclass(frozen=True)
class Method:
    name: str
    first: int
    last: int
    text: str
    test: bool
    standalone: bool


@dataclass(frozen=True)
class Members:
    methods: tuple[Method, ...]
    outside: str


def read(text: str, name: str) -> Members | None:
    if "#sourceLocation" in text:
        return None
    try:
        parsed = subprocess.run(["xcrun", "swiftc", "-frontend", "-dump-parse", "-"],
                                input=text, capture_output=True, text=True)
    except OSError:
        return None
    if parsed.returncode or not parsed.stdout.startswith('(source_file "<stdin>"'):
        return None
    lines, dump = text.splitlines(keepends=True), parsed.stdout.splitlines()
    methods: list[Method] = []
    spans = []
    matched = False
    for index, line in enumerate(dump):
        declared = TYPE.match(line)
        if not declared or declared[2] != name:
            continue
        matched = True
        end = next((i for i in range(index + 1, len(dump))
                    if (node := NODE.match(dump[i])) and len(node[1]) <= 2), len(dump))
        region = dump[index + 1:end]
        if any((node := NODE.match(item)) and node[2] in {"if_config_decl", "macro_expansion_decl"} for item in region):
            return None
        for offset, item in enumerate(region):
            node = NODE.match(item)
            if not node or len(node[1]) not in (4, 6) or not node[2].endswith("_attr"):
                continue
            if node[2] == "custom_attr":
                if offset + 1 >= len(region) or not re.search(r'\(type_unqualified_ident id="MainActor" unbound\)', region[offset + 1]):
                    return None
            elif node[2] not in {"access_control_attr", "override_attr", "final_attr", "static_attr", "discardable_result_attr"}:
                return None
        for offset, item in enumerate(region):
            function = FUNCTION.match(item)
            if not function:
                continue
            display = function[1]
            named = re.fullmatch(r"(\w+)\([^)]*\)", display)
            position = RANGE.search(item)
            if named is None or position is None:
                return None
            first, column, last, closing = map(int, position.groups())
            stop = next((i for i in range(offset + 1, len(region))
                         if (node := NODE.match(region[i])) and len(node[1]) <= 4), len(region))
            children = region[offset + 1:stop]
            hidden = False
            for child in children:
                node = NODE.match(child)
                if not node or len(node[1]) != 6 or not node[2].endswith("_attr"):
                    continue
                if location := RANGE.search(child):
                    begin = tuple(map(int, location.groups()[:2]))
                    first, column = min((first, column), begin)
                hidden = hidden or bool(re.search(r"access_level=(?:private|fileprivate)\b", child))
            if not 1 <= first <= last <= len(lines) or (first, column) > (last, closing):
                return None
            if not 1 <= column <= len(lines[first - 1].encode()) or not 1 <= closing <= len(lines[last - 1].encode()):
                return None
            prefix = lines[first - 1].encode()[:column - 1].decode(errors="replace")
            suffix = lines[last - 1].encode()[closing:].decode(errors="replace")
            standalone = not prefix.strip() and not suffix.strip()
            value = "".join(lines[first - 1:last])
            test = bool(re.fullmatch(r"test\w*\(\)", display)) and not hidden and not re.search(r"\btype\b", item)
            if test and any(method.test and method.name == named[1] for method in methods):
                return None
            methods.append(Method(named[1], first, last, value, test, standalone))
            spans.append((first, last))
    if not matched:
        return None
    outside = "".join(line for number, line in enumerate(lines, 1)
                      if not any(first <= number <= last for first, last in spans))
    return Members(tuple(methods), outside)


def changed_methods(before: str, after: str, name: str, diff: str) -> set[str] | None:
    old, new = read(before, name), read(after, name)
    if old is None or new is None:
        return None
    old_tests = {method.name: method for method in old.methods if method.test}
    new_tests = {method.name: method for method in new.methods if method.test}
    changed = {key for key in old_tests.keys() | new_tests.keys()
               if (old_tests[key].text if key in old_tests else None)
               != (new_tests[key].text if key in new_tests else None)}
    if not changed or not changed <= new_tests.keys():
        return None
    for members in (old, new):
        if any(re.search(rf"\b{re.escape(key)}\b", members.outside)
               or any(not (other.test and other.name == key) and re.search(rf"\b{re.escape(key)}\b", other.text)
                      for other in members.methods) for key in changed):
            return None
    hunks = list(re.finditer(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", diff, re.M))
    if not hunks:
        return None
    for match in hunks:
        starts = ((int(match[1]), int(match[2] or 1)), (int(match[3]), int(match[4] or 1)))
        for text, members, (first, count) in zip((before, after), (old, new), starts):
            lines = text.splitlines()
            for number in range(first, first + count):
                if any(method.test and method.name in changed and method.standalone and method.first <= number <= method.last
                       for method in members.methods):
                    continue
                if 1 <= number <= len(lines) and not lines[number - 1].strip():
                    previous, following = number - 1, number + 1
                    while previous >= 1 and not lines[previous - 1].strip():
                        previous -= 1
                    while following <= len(lines) and not lines[following - 1].strip():
                        following += 1
                    if any(method.test and method.name in changed and method.standalone
                           and (method.last == previous or method.first == following)
                           for method in members.methods):
                        continue
                return None
    return changed
