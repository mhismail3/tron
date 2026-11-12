"""Rewrites owned JSON address fields while preserving lexical bytes and provenance."""

import json
import re

TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"')
PATH_FIELDS = {"cwd", "sessionRoot", "sessionDir", "sessionFile", "outputFile", "asyncDir", "currentPath", "workflowReceiptPath", "transcriptPath", "structuredOutputPath", "structuredOutputSchemaPath", "outputPath", "outputDir", "worktreePath", "stdoutPath", "stderrPath", "finalOutputPath", "resultArtifactPath", "path", "resultPath", "configPath", "artifactsDir", "tempRoot", "workflowStateDir", "savedOutputPath", "agentFilePath", "piPackageRoot", "worktreeBaseDir", "controlInbox", "eventSink", "outputClaimPath", "schemaPath", "acceptanceReportPath", "childSessionFactoryModule"}
HISTORY = {"task", "prompt", "systemPrompt", "description", "structuredOutput", "recentOutput", "recentTools", "currentToolArgs", "error", "text", "notes", "message", "errors", "extensionBindings", "requiredExtensions", "structuredOutputSchema", "outputSchema", "args", "parameters", "launchBindingTask", "messages", "input", "output"}


def prefix(value, pairs):
    for old, new in pairs:
        if value == old or value.startswith(old + "/"):
            return new + value[len(old):]
    return value


def unique(pairs):
    value = {}
    for key, child in pairs:
        if key in value:
            raise ValueError("rewrite_key_collision")
        value[key] = child
    return value


def locations(text):
    parsed = json.loads(text, object_pairs_hook=unique)
    def walk(value, path=()):
        if isinstance(value, dict):
            for key, child in value.items():
                yield path + (key,), True, key
                yield from walk(child, path + (key,))
        elif isinstance(value, list):
            for index, child in enumerate(value):
                yield from walk(child, path + (index,))
        elif isinstance(value, str):
            yield path, False, value
    matches = list(TOKEN.finditer(text))
    values = list(walk(parsed))
    if len(matches) != len(values):
        raise ValueError("invalid_rewrite_document")
    return [(path, key, value, match) for (path, key, value), match in zip(values, matches)]


def selected(kind, path, key):
    if kind == "trust":
        return key and len(path) == 1
    if kind == "session":
        return not key and path == ("cwd",)
    if kind == "upload":
        return not key and path == ("path",)
    if kind == "target":
        return not key and path == ("target",)
    if kind == "observed":
        return path[:2] == ("stores", "trust") and (key and len(path) == 4 and path[2] in {"values", "tron", "outside"} or not key and (path[-2:] == ("qualifiers", "project") or path == ("stores", "trust", "digest")))
    if kind == "mission":
        return not key and (len(path) == 3 and path[0] == "runs" and path[2] == "asyncDir" or len(path) == 3 and path[0] == "artifacts" and path[2] == "path" or len(path) == 4 and path[0] == "workflowChildren" and path[2] == "artifactPaths")
    if kind == "budget":
        return not key and path == ("directory",)
    if kind == "candidate":
        return not key and path == ("sessionFile",)
    if kind in {"subagent", "subagent_config"}:
        containers = {"steps", "results", "artifactPaths", "outputPaths", "runFanoutBudget", "preloads", "skillPath", "extensions", "subagentOnlyExtensions", "parallelHandoff", "piOptions", "memory", "children", "nestedChildren", "parallel", "nestedRoute", "runFanoutBudgetDescriptor", "importAsyncRoot", "revivalLease", "sessionFiles"}
        history = HISTORY
        if kind == "subagent_config":
            containers = containers | {"structuredOutput"}
            history = HISTORY - {"structuredOutput"}
        return not key and not any(part in history for part in path[:-1]) and all(isinstance(part, int) or part in containers for part in path[:-1]) and (path[-1] in PATH_FIELDS or path[-2:] in (("runFanoutBudget", "directory"), ("runFanoutBudgetDescriptor", "directory")) or "artifactPaths" in path or path[-2:-1] in (("outputPaths",), ("preloads",), ("skillPath",), ("extensions",), ("subagentOnlyExtensions",), ("sessionFiles",)))
    return False


def mapped(kind, path, key, value, pairs, digest):
    if kind == "observed" and key:
        name, separator, qualifiers = value.partition("\0")
        if not separator:
            raise ValueError("invalid_observed_instance")
        parsed = json.loads(qualifiers)
        if not isinstance(parsed, dict):
            raise ValueError("invalid_observed_instance")
        if isinstance(parsed.get("project"), str):
            parsed["project"] = prefix(parsed["project"], pairs)
        return name + separator + json.dumps(parsed, ensure_ascii=False, separators=(",", ":"))
    if kind == "observed" and path == ("stores", "trust", "digest"):
        return digest[1] if digest and value == digest[0] else value
    return prefix(value, pairs)


def rewrite(text, kind, pairs, before=None, after=None, digest=None):
    if kind == "terminal":
        originals = {}
        if before is not None:
            originals = {new: old for old, new in zip(before.splitlines(keepends=True), after.splitlines(keepends=True))}
        output = []
        for line in text.splitlines(keepends=True):
            if not re.match(r"^(?:HostKey|AuthorizedKeysFile|PidFile)\s", line):
                output.append(line)
            elif line in originals:
                output.append(originals[line])
            else:
                changed = line
                for old, new in pairs:
                    changed = changed.replace(old, new)
                output.append(changed)
        return "".join(output)
    originals = {}
    if before is not None:
        left, right = locations(before), locations(after)
        if len(left) != len(right):
            raise ValueError("rewrite_provenance_changed")
        for old, new in zip(left, right):
            originals[(new[0], new[1])] = (new[2], old[3][0])
    changes = []
    for path, key, value, match in locations(text):
        if not selected(kind, path, key):
            continue
        saved = originals.get((path, key))
        if saved and saved[0] == value:
            encoded = saved[1]
        else:
            changed = mapped(kind, path, key, value, pairs, digest)
            if changed == value:
                continue
            encoded = json.dumps(changed, ensure_ascii="\\u" in match[0])
            if "\\/" in match[0]:
                encoded = encoded.replace("/", "\\/")
        if kind == "observed" and path == ("stores", "trust", "digest") and digest and value == digest[0]:
            encoded = json.dumps(digest[1])
        if encoded != match[0]:
            changes.append((match.start(), match.end(), encoded))
    for start, end, value in reversed(changes):
        text = text[:start] + value + text[end:]
    locations(text)
    return text
