#!/usr/bin/env python3
"""Run the registered repository rules with ast-grep over root-relative paths.

`scripts/tron rules check` is the only entry point. Each registry rule names one
ast-grep detector in tools/rules/detectors; ast-grep owns all Swift syntax. Cross-file
sheet state is joined from AST queries per source domain, never from source text.
"""
import argparse
import collections
import datetime
import json
import os
import pathlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
REGISTRY = ROOT / 'tools/rules/rules.yaml'
DETECTORS = ROOT / 'tools/rules/detectors'
TESTS = ROOT / 'tools/rules/tests'
REQUIRED = ('id', 'decision', 'owner', 'engine', 'detector', 'scope', 'allow', 'mode',
            'autofix', 'provenance', 'exit', 'added')
SUPPRESSION_FLAGS = ['--error=no-suppress-all', '--error=unused-suppression']
SUPPRESSION_DECISIONS = {
    'no-suppress-all': 'Do not use file-wide ast-grep suppression directives.',
    'unused-suppression': 'Remove unused ast-grep suppression directives; registered rules cannot be silenced.',
}
SHEET_STATE_RULE = 'ios.presentation.sheet-state'
SHEET_VIEW_QUERIES = (
    ('view', 'struct $NAME: $$$INHERITANCE { $$$BODY }'),
    ('generic-view', 'struct $NAME<$$$GENERIC>: $$$INHERITANCE { $$$BODY }'),
)
SHEET_CLOSURE_QUERIES = (
    ('managed-sheet', '$OBJ.tronManagedSheet($$$ARGS) { $$$BODY }'),
    ('progressive-link', 'TronProgressiveSheetLink($$$ARGS) { $$$BODY }'),
    ('settings-link', 'settingsLink($$$ARGS) { $$$BODY }'),
)
SHEET_CONSTRUCTOR_QUERIES = (
    ('construction', '$TYPE($$$ARGS)'),
    ('generic-construction', '$TYPE<$$$GENERIC>($$$ARGS)'),
    ('trailing-construction', '$TYPE { $$$BODY }'),
)
DESTINATION_RULE = ('id: destination-closure\nlanguage: Swift\nrule:\n  kind: value_argument\n'
                    '  has:\n    kind: value_argument_label\n    regex: ^destination$\n')
VIEW_LOCAL_RULE = 'id: view-local-comment\nlanguage: Swift\nrule:\n  kind: comment\n  regex: ^//\\s*view-local:\\s*\\S\n'


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def configured_ast_grep_version():
    for line in (ROOT / 'config/ci-toolchain.env').read_text().splitlines():
        if line.startswith('TRON_CI_AST_GREP_VERSION='):
            return line.partition('=')[2].strip().strip('"\'')
    raise RuntimeError('TRON_CI_AST_GREP_VERSION is missing from config/ci-toolchain.env')


def resolve_ast_grep():
    """The pinned ast-grep: an explicit AST_GREP fails loudly, otherwise tools dir, then PATH."""
    if os.environ.get('AST_GREP'):
        binary = os.environ['AST_GREP']
        if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
            raise RuntimeError(f'AST_GREP is not an executable: {binary}')
    else:
        candidates = []
        if os.environ.get('TRON_CI_TOOLS_DIR'):
            candidates.append(str(pathlib.Path(os.environ['TRON_CI_TOOLS_DIR']) / 'bin/ast-grep'))
        if shutil.which('ast-grep'):
            candidates.append(shutil.which('ast-grep'))
        binary = next((c for c in candidates if os.path.isfile(c) and os.access(c, os.X_OK)), None)
        if not binary:
            raise RuntimeError('ast-grep is unavailable; install the pinned tool or expose ast-grep on PATH')
    expected = configured_ast_grep_version()
    proc = subprocess.run([binary, '--version'], capture_output=True, text=True)
    lines = (proc.stdout or proc.stderr).strip().splitlines()
    actual = lines[0] if lines else ''
    if proc.returncode != 0 or actual != f'ast-grep {expected}':
        raise RuntimeError(f'ast-grep version mismatch: expected ast-grep {expected}, got {actual or "nothing"}')
    return binary


def ast_json(binary, args):
    proc = subprocess.run([binary, *args], cwd=ROOT, capture_output=True, text=True)
    if proc.returncode not in (0, 1):
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip())
    return json.loads(proc.stdout or '[]')


def scan(binary, rule_text, targets):
    """One ast-grep scan of every target with one rule; suppression diagnostics are errors.

    Callers keep only the matches whose ruleId is their own id, so suppression diagnostics
    are reported once by the rule scan that owns them.
    """
    with tempfile.TemporaryDirectory(prefix='tron-rule-') as directory:
        rule_path = pathlib.Path(directory) / 'rule.yml'
        rule_path.write_text(rule_text)
        return ast_json(binary, ['scan', '--rule', str(rule_path), *SUPPRESSION_FLAGS, '--json', *targets])


def engine_rule(detector, engine_id):
    """The detector with a per-run id, so source comments cannot name and silence it."""
    text, count = re.subn(r'^id: \S+$', f'id: {engine_id}', detector.read_text(), count=1, flags=re.M)
    if count != 1:
        raise RuntimeError(f'{detector.relative_to(ROOT)} has no top-level id')
    return text


def load_registry():
    rules = json.loads(REGISTRY.read_text())
    errors, ids, detectors = [], set(), set()
    today = datetime.date.today()
    for rule in rules:
        rule_id = rule.get('id', '<unnamed>')
        missing = [key for key in REQUIRED if key not in rule or rule[key] in (None, '')
                   or (key == 'scope' and not rule[key])]
        if missing:
            errors.append(f"{rule_id}: missing metadata {', '.join(missing)}")
        if rule_id in ids:
            errors.append(f'duplicate rule id: {rule_id}')
        ids.add(rule_id)
        if rule.get('mode') not in ('zero', 'ratchet', 'advise'):
            errors.append(f'{rule_id}: invalid mode')
        if rule.get('autofix') not in ('none', 'suggest'):
            errors.append(f'{rule_id}: invalid autofix')
        if rule.get('engine') != 'ast-grep':
            errors.append(f'{rule_id}: unsupported engine')
        for key in ('added', 'expires'):
            if key in rule:
                try:
                    datetime.date.fromisoformat(rule[key])
                except (TypeError, ValueError):
                    errors.append(f'{rule_id}: {key} must be an ISO date')
        if 'expires' in rule and is_past(rule['expires'], today):
            print(f"expired rule: {rule_id} (expires {rule['expires']}); retire it or renew its date", file=sys.stderr)
        owner = rule.get('owner', '').partition('#')[0]
        if owner and not (ROOT / owner).is_file():
            errors.append(f'{rule_id}: missing owner {owner}')
        for relative in allowed_paths(rule):
            if not (ROOT / relative).is_file():
                errors.append(f'{rule_id}: allowance names a missing file {relative}')
        detector = ROOT / rule.get('detector', '')
        if not detector.is_file() or detector.parent != DETECTORS:
            errors.append(f'{rule_id}: missing detector {rule.get("detector")}')
            continue
        detectors.add(detector.name)
        test = TESTS / detector.name
        if not test.is_file():
            errors.append(f'{rule_id}: missing rule tests tools/rules/tests/{detector.name}')
            continue
        detector_id = re.search(r'^id: (\S+)$', detector.read_text(), re.M)
        test_id = re.search(r'^id: (\S+)$', test.read_text(), re.M)
        if not detector_id or not test_id or detector_id.group(1) != test_id.group(1):
            errors.append(f'{rule_id}: detector and tests disagree on the ast-grep rule id')
    for detector in sorted(DETECTORS.glob('*.yml')):
        if detector.name not in detectors:
            errors.append(f'orphan detector: {detector.relative_to(ROOT)}')
    for test in sorted(TESTS.glob('*.yml')):
        if not (DETECTORS / test.name).is_file():
            errors.append(f'orphan rule tests: {test.relative_to(ROOT)}')
    return rules, errors


def is_past(iso_date, today):
    try:
        return datetime.date.fromisoformat(iso_date) < today
    except (TypeError, ValueError):
        return False  # The malformed date is already a validation error.


def allowed_paths(rule):
    allow = rule.get('allow', {})
    paths = list(allow.get('paths', []))
    paths.extend(path for path, _ in allow.get('literals', []))
    return paths


def normalize_paths(values):
    paths = set()
    for value in values:
        path = pathlib.Path(value)
        absolute = path if path.is_absolute() else ROOT / path
        try:
            paths.add(absolute.resolve().relative_to(ROOT.resolve()).as_posix())
        except ValueError:
            raise RuntimeError(f'file is outside repository: {value}')
    return paths


def rule_paths(rule, changed):
    paths = set()
    for pattern in rule['scope']:
        paths.update(path.relative_to(ROOT).as_posix() for path in ROOT.glob(pattern) if path.is_file())
    if changed is not None:
        paths &= changed
    return sorted(paths)


def materialize(paths, directory, tree):
    """Write the inputs into one scan directory; `tree` reads the committed base instead of the worktree."""
    targets, repo_path = [], {}
    for relative in paths:
        if tree:
            try:
                data = subprocess.check_output(['git', 'show', f'{tree}:{relative}'], cwd=ROOT)
            except subprocess.CalledProcessError:
                continue
            target = directory / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        else:
            target = ROOT / relative
            if not target.is_file():
                continue
        targets.append(str(target))
        repo_path[str(target.resolve())] = relative
    return targets, repo_path


def allowed(rule, relative, match):
    allow = rule.get('allow', {})
    if relative in allow.get('paths', []):
        return True
    content = match.get('metaVariables', {}).get('single', {}).get('CONTENT', {}).get('text')
    if content is not None and [relative, content] in allow.get('literals', []):
        return True
    label = allow.get('determinateLabel')
    if label:
        # The first argument of a call is the AST node that carries the label; a
        # `value:` first argument makes the spinner determinate.
        args = match.get('metaVariables', {}).get('multi', {}).get('ARGS', [])
        if args and re.match(rf'{re.escape(label)}\s*:', args[0]['text'].lstrip()):
            return True
    return False


def rule_findings(rule, binary, paths, tree=None):
    """One scan of the whole path set for a rule; suppression diagnostics name their rule."""
    if not paths:
        return []
    engine_id = f'tron-{secrets.token_hex(16)}'
    with tempfile.TemporaryDirectory(prefix='tron-rules-') as directory:
        targets, repo_path = materialize(paths, pathlib.Path(directory), tree)
        if not targets:
            return []
        findings = []
        for match in scan(binary, engine_rule(ROOT / rule['detector'], engine_id), targets):
            relative = repo_path.get(str(pathlib.Path(match['file']).resolve()))
            if relative is None:
                continue
            rule_id = match.get('ruleId')
            if rule_id in SUPPRESSION_DECISIONS:
                findings.append(suppression_finding(rule_id, relative, match))
                continue
            if rule_id != engine_id:
                raise RuntimeError(f'unexpected ast-grep rule ID: {rule_id}')
            if allowed(rule, relative, match):
                continue
            text = ' '.join(match['text'].split())
            findings.append({'rule': rule['id'], 'file': relative, 'line': match['range']['start']['line'] + 1,
                             'text': text, 'key': [rule['id'], relative, text], 'decision': rule['decision'],
                             'owner': rule['owner'], 'mode': rule['mode']})
    return findings


def suppression_finding(rule_id, relative, match):
    canonical = f'repo.ast-grep-{rule_id}'
    text = ' '.join(match['text'].split())
    return {'rule': canonical, 'file': relative, 'line': match['range']['start']['line'] + 1, 'text': text,
            'key': [canonical, relative, text], 'decision': SUPPRESSION_DECISIONS[rule_id],
            'owner': 'tools/rules/rules.yaml', 'mode': 'zero'}


def sheet_state_findings(rule, binary, domain_paths):
    """Sheet content in one source domain: a `@State` in a view that any managed sheet, progressive link,
    settings link or destination closure constructs must be `@PresentationState` or say `// view-local:`."""
    targets = [str(ROOT / path) for path in domain_paths]
    if not targets:
        return []
    found = {}
    for name, pattern in SHEET_VIEW_QUERIES + SHEET_CLOSURE_QUERIES + SHEET_CONSTRUCTOR_QUERIES:
        found[name] = ast_json(binary, ['run', '--lang', 'swift', '--pattern', pattern, '--json', *targets])
    declarations = []
    for name in ('view', 'generic-view'):
        for match in found[name]:
            captures = match.get('metaVariables', {})
            view = captures.get('single', {}).get('NAME', {}).get('text')
            inheritance = [node['text'].strip() for node in captures.get('multi', {}).get('INHERITANCE', [])]
            if view and 'View' in inheritance:
                declarations.append((view, str(pathlib.Path(match['file']).resolve()), match['range']))
    view_names = {declaration[0] for declaration in declarations}
    closures = []
    for name, _ in SHEET_CLOSURE_QUERIES:
        for match in found[name]:
            for body in match.get('metaVariables', {}).get('multi', {}).get('BODY', []):
                closures.append((str(pathlib.Path(match['file']).resolve()), body['range']))
    destination_id = f'destination-{secrets.token_hex(12)}'
    destinations = scan(binary, DESTINATION_RULE.replace('id: destination-closure', f'id: {destination_id}'), targets)
    closures.extend((str(pathlib.Path(match['file']).resolve()), match['range'])
                    for match in destinations if match.get('ruleId') == destination_id)
    root_hosts = collections.defaultdict(set)
    for name, _ in SHEET_CONSTRUCTOR_QUERIES:
        for constructor in found[name]:
            type_name = constructor.get('metaVariables', {}).get('single', {}).get('TYPE', {}).get('text', '')
            type_name = type_name.strip().partition('<')[0].strip()
            if type_name not in view_names:
                continue
            constructed_file = str(pathlib.Path(constructor['file']).resolve())
            start = position(constructor['range']['start'])
            end = position(constructor['range']['end'])
            for host_file, span in closures:
                if host_file == constructed_file and position(span['start']) <= start and end <= position(span['end']):
                    root_hosts[type_name].add(pathlib.Path(host_file).relative_to(ROOT).as_posix())
    if not root_hosts:
        return []
    state_text = engine_rule(ROOT / rule['detector'], f'tron-{secrets.token_hex(16)}')
    state_id = re.search(r'^id: (\S+)$', state_text, re.M).group(1)
    state_matches = [match for match in scan(binary, state_text, targets) if match.get('ruleId') == state_id]
    comment_text = VIEW_LOCAL_RULE.replace('id: view-local-comment', f'id: view-local-{secrets.token_hex(12)}')
    comment_id = re.search(r'^id: (\S+)$', comment_text, re.M).group(1)
    comment_lines = set()
    for match in scan(binary, comment_text, targets):
        if match.get('ruleId') == comment_id and match['text'].split('view-local:', 1)[-1].strip():
            comment_lines.add((str(pathlib.Path(match['file']).resolve()), match['range']['start']['line']))
    results = []
    for match in state_matches:
        file_path = str(pathlib.Path(match['file']).resolve())
        state_start = position(match['range']['start'])
        containing = [declaration for declaration in declarations if declaration[1] == file_path and
                      position(declaration[2]['start']) <= state_start < position(declaration[2]['end'])]
        if not containing:
            continue
        # The innermost declaration owns the state, so a nested view is judged on its own name.
        view = min(containing, key=lambda declaration: (declaration[2]['end']['line'] - declaration[2]['start']['line'],
                                                        declaration[2]['end']['column'] - declaration[2]['start']['column']))[0]
        if view not in root_hosts or (file_path, match['range']['start']['line']) in comment_lines:
            continue
        relative = pathlib.Path(file_path).relative_to(ROOT).as_posix()
        text = ' '.join(match['text'].split())
        results.append({'rule': rule['id'], 'file': relative, 'line': match['range']['start']['line'] + 1,
                        'text': text, 'key': [rule['id'], relative, text],
                        'decision': f'Sheet content {view} must use @PresentationState or explain genuinely '
                                    'view-local @State with // view-local: <reason>.',
                        'owner': rule['owner'], 'mode': rule['mode'], 'hostFiles': sorted(root_hosts[view])})
    return results


def position(point):
    return (point['line'], point['column'])


def tree_paths(paths, base):
    committed = set(git('ls-tree', '-r', '--name-only', base).splitlines())
    return [path for path in paths if path in committed]


def new_findings(current, baseline):
    """Ratchet: a finding is new when its (rule, file, text) count exceeds the base's count."""
    remaining = collections.Counter(tuple(finding['key']) for finding in baseline)
    new = []
    for finding in current:
        key = tuple(finding['key'])
        if remaining[key]:
            remaining[key] -= 1
        else:
            new.append(finding)
    return new


def merge_base(ref):
    try:
        commit = git('rev-parse', '--verify', f'{ref}^{{commit}}')
    except subprocess.CalledProcessError:
        raise RuntimeError(f'base ref {ref} does not exist; refusing to guess a baseline')
    try:
        return git('merge-base', 'HEAD', commit)
    except subprocess.CalledProcessError:
        raise RuntimeError(f'no merge base between HEAD and {ref}; refusing to guess a baseline')


def changed_files(base):
    paths = set(git('diff', '--name-only', base, '--').splitlines())
    paths.update(git('ls-files', '--others', '--exclude-standard').splitlines())
    return normalize_paths(paths)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--validate', action='store_true')
    parser.add_argument('--files', nargs='*')
    parser.add_argument('--since')
    parser.add_argument('--format', choices=['agent', 'json'], default='agent')
    args = parser.parse_args()
    try:
        rules, errors = load_registry()
        if errors:
            print('\n'.join(errors), file=sys.stderr)
            return 1
        if args.validate:
            return 0
        if any(rule['mode'] == 'ratchet' for rule in rules) and not args.since:
            raise RuntimeError('ratchet rules require --since <ref>; refusing to guess a baseline')
        if args.since and args.files is not None:
            raise RuntimeError('--since and --files are exclusive')
        binary = resolve_ast_grep()
        base = merge_base(args.since) if args.since else None
        if base:
            changed = changed_files(base)
        elif args.files is not None:
            changed = normalize_paths(args.files)
        else:
            changed = None
        findings = []
        for rule in rules:
            if rule['id'] == SHEET_STATE_RULE:
                # Each source root is a separate domain: a view joins only to hosts in its own root.
                domains = sorted({rule_scope.split('/**')[0] for rule_scope in rule['scope']})
                for domain in domains:
                    domain_paths = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / domain).rglob('*.swift'))
                    state = sheet_state_findings(rule, binary, domain_paths)
                    if changed is not None:
                        state = [f for f in state if f['file'] in changed or set(f['hostFiles']) & changed]
                    findings.extend(state)
                continue
            paths = rule_paths(rule, changed)
            current = rule_findings(rule, binary, paths)
            if rule['mode'] == 'ratchet':
                current = new_findings(current, rule_findings(rule, binary, tree_paths(paths, base), tree=base))
            findings.extend(current)
        unique, seen = [], set()
        for finding in findings:
            # Each repeated suppression directive is one diagnostic, whichever rule scan reported it.
            if finding['rule'].startswith('repo.ast-grep-'):
                marker = (finding['rule'], finding['file'], finding['line'])
                if marker in seen:
                    continue
                seen.add(marker)
            unique.append(finding)
        if args.format == 'json':
            print(json.dumps(unique, indent=2))
        else:
            for finding in unique:
                prefix = '' if finding['mode'] != 'advise' else 'advisory: '
                print(f"{prefix}{finding['file']}:{finding['line']}: {finding['decision']} "
                      f"Owner: {finding['owner']}. Suggested fix: use the owner API.")
        return int(any(finding['mode'] != 'advise' for finding in unique))
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f'rules check failed closed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
