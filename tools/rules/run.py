#!/usr/bin/env python3
"""Validate and execute repository rules with ast-grep at explicit file boundaries."""
import argparse
import collections
import datetime
import fnmatch
import json
import os
import pathlib
import secrets
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
REGISTRY = ROOT / 'tools/rules/rules.yaml'
REQUIRED = ('id', 'decision', 'owner', 'engine', 'detector', 'scope', 'allow', 'mode',
            'autofix', 'provenance', 'exit', 'added')

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()

def configured_ast_grep_version():
    config = ROOT / 'config/ci-toolchain.env'
    for line in config.read_text().splitlines():
        if line.startswith('TRON_CI_AST_GREP_VERSION='):
            return line.partition('=')[2].strip().strip('\"\'')
    raise RuntimeError('TRON_CI_AST_GREP_VERSION is missing from config/ci-toolchain.env')

def resolve_ast_grep():
    candidates = []
    if os.environ.get('AST_GREP'):
        candidates.append(os.environ['AST_GREP'])
    tools_dir = os.environ.get('TRON_CI_TOOLS_DIR')
    if tools_dir:
        candidates.append(str(pathlib.Path(tools_dir) / 'bin/ast-grep'))
    path_binary = shutil.which('ast-grep')
    if path_binary:
        candidates.append(path_binary)
    binary = next((candidate for candidate in candidates if os.path.isfile(candidate) and os.access(candidate, os.X_OK)), None)
    if not binary:
        raise RuntimeError('ast-grep is unavailable; install the pinned tool or expose ast-grep on PATH')
    expected = configured_ast_grep_version()
    actual = subprocess.check_output([binary, '--version'], text=True).strip().splitlines()[0]
    if actual != f'ast-grep {expected}':
        raise RuntimeError(f'ast-grep version mismatch: expected {expected}, got {actual}')
    return binary

def load_registry():
    rules = json.loads(REGISTRY.read_text())
    errors, ids, detectors = [], set(), set()
    for rule in rules:
        missing = [key for key in REQUIRED if key not in rule or rule[key] is None or rule[key] == '']
        if missing:
            errors.append(f"{rule.get('id', '<unnamed>')}: missing metadata {', '.join(missing)}")
        rule_id = rule.get('id')
        if rule_id in ids:
            errors.append(f'duplicate rule id: {rule_id}')
        ids.add(rule_id)
        if rule.get('mode') not in ('zero', 'ratchet', 'advise'):
            errors.append(f'{rule_id}: invalid mode')
        if rule.get('autofix') not in ('none', 'suggest'):
            errors.append(f'{rule_id}: invalid autofix')
        if rule.get('engine') != 'ast-grep':
            errors.append(f'{rule_id}: unsupported engine')
        detector = ROOT / rule.get('detector', '')
        if not detector.is_file():
            errors.append(f'{rule_id}: missing detector {detector}')
        else:
            detectors.add(detector)
        if not (ROOT / 'tools/rules/tests' / f'{rule_id}.yml').is_file():
            errors.append(f'{rule_id}: missing rule tests tools/rules/tests/{rule_id}.yml')
        try:
            exit_date = datetime.date.fromisoformat(rule['exit'][:10])
            if exit_date < datetime.date.today():
                print(f'stale rule exit: {rule_id} ({rule["exit"]})', file=sys.stderr)
        except (ValueError, TypeError, KeyError):
            pass
    for detector in (ROOT / 'tools/rules/detectors').glob('*.yml'):
        if detector not in detectors:
            errors.append(f'orphan detector: {detector.relative_to(ROOT)}')
    return rules, errors

def normalize_paths(values):
    paths = set()
    for value in values:
        path = pathlib.Path(value)
        absolute = path if path.is_absolute() else ROOT / path
        try:
            relative = absolute.resolve().relative_to(ROOT.resolve()).as_posix()
        except ValueError:
            raise RuntimeError(f'file is outside repository: {value}')
        paths.add(relative)
    return paths

def rule_paths(rule, changed=None):
    paths = set()
    for pattern in rule['scope']:
        paths.update(path.relative_to(ROOT).as_posix() for path in ROOT.glob(pattern))
    if rule['id'] == 'ios.sheet.shared-loading':
        host_paths = set(rule['allow']['host_paths'])
        paths = {path for path in paths if path in host_paths or
                 path.startswith('packages/ios-app/Sources/UI/') or
                 path.startswith('packages/ios-app/Sources/State/') or
                 path.startswith('packages/ios-app/SwiftAppEngine/UI/') or
                 path.startswith('packages/ios-app/SwiftAppEngine/State/')}
    if changed is not None:
        paths.intersection_update(changed)
    return sorted(path for path in paths if (ROOT / path).is_file())

def tree_rule_paths(rule, tree, selected):
    paths = git('ls-tree', '-r', '--name-only', tree).splitlines()
    return sorted(path for path in paths if path in selected and
                  any(fnmatch.fnmatch(path, pattern) for pattern in rule['scope']))

def canonical_allow(rule):
    allow = rule['allow']
    if isinstance(allow, list):
        return {'all': set(allow)}
    return {name: {tuple(value) if isinstance(value, list) else value for value in values}
            for name, values in allow.items()}

def run_ast_grep(rule, paths, binary, tree=None):
    """Run each AST rule once over its complete input path set (not once per file)."""
    if not paths:
        return []
    allow = canonical_allow(rule)
    detector_source = (ROOT / rule['detector']).read_text()
    engine_id = f"tron-{secrets.token_hex(16)}"
    canonical_id = rule['id'].split('.')[-1]
    detector_source = detector_source.replace(f'id: {canonical_id}', f'id: {engine_id}', 1)
    result = []
    with tempfile.TemporaryDirectory(prefix='tron-rules-') as temp_dir:
        temp_dir = pathlib.Path(temp_dir)
        detector_path = temp_dir / 'rule.yml'
        detector_path.write_text(detector_source)
        targets, target_to_repo = [], {}
        if tree:
            for relative in paths:
                try:
                    data = subprocess.check_output(['git', 'show', f'{tree}:{relative}'], cwd=ROOT)
                except subprocess.CalledProcessError:
                    continue
                target = temp_dir / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                targets.append(str(target))
                target_to_repo[str(target.resolve())] = relative
        else:
            for relative in paths:
                target = ROOT / relative
                if target.is_file():
                    targets.append(str(target))
                    target_to_repo[str(target.resolve())] = relative
        if not targets:
            return []
        command = [binary, 'scan', '--rule', str(detector_path), '--error=no-suppress-all',
                   '--error=unused-suppression', '--json', *targets]
        proc = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        try:
            matches = json.loads(proc.stdout or '[]')
        except json.JSONDecodeError as error:
            raise RuntimeError(proc.stderr.strip() or proc.stdout.strip()) from error
        if proc.returncode not in (0, 1) and not matches:
            raise RuntimeError(proc.stderr.strip() or proc.stdout.strip())
        for match in matches:
            file_path = str(pathlib.Path(match['file']).resolve())
            relative = target_to_repo.get(file_path)
            if relative is None:
                continue
            text = ' '.join(match['text'].split())
            rule_id = match.get('ruleId')
            if rule_id in ('no-suppress-all', 'unused-suppression'):
                decision = ('Do not use file-wide ast-grep suppression directives.' if rule_id == 'no-suppress-all'
                            else 'Remove unused ast-grep suppression directives; registered rules cannot be silenced.')
                canonical = f'repo.ast-grep-{rule_id}'
                result.append({'rule': canonical, 'file': relative,
                               'line': match['range']['start']['line'] + 1, 'text': text,
                               'key': (canonical, relative, text), 'decision': decision,
                               'owner': 'tools/rules/rules.yaml', 'mode': 'zero'})
                continue
            if rule_id != engine_id:
                raise RuntimeError(f'unexpected ast-grep rule ID: {rule_id}')
            start_line = match['range']['start']['line'] + 1
            if rule['id'] == 'ios.sheet.shared-loading':
                if text.startswith('ProgressView('):
                    args = match.get('metaVariables', {}).get('multi', {}).get('ARGS', [])
                    if any(argument['text'].lstrip().startswith('value:') for argument in args):
                        continue
                    if relative in allow.get('spinner_paths', set()):
                        continue
                elif text.startswith('Text('):
                    content = match.get('metaVariables', {}).get('single', {}).get('CONTENT', {}).get('text')
                    if content is None or not content.startswith(('Loading', 'Opening', 'Preparing', 'Waiting for',
                                                                   'Connecting', 'Fetching', 'Inspecting', 'Calculating')):
                        continue
                    if not content.endswith(('…', '...')):
                        continue
                    if (relative, content) in allow.get('text_pairs', set()):
                        continue
                elif text == 'TronSheetLoadingHostModifier':
                    if relative in allow.get('host_paths', set()):
                        continue
                else:
                    continue
            result.append({'rule': rule['id'], 'file': relative, 'line': start_line, 'text': text,
                           'key': (rule['id'], relative, text), 'decision': rule['decision'],
                           'owner': rule['owner'], 'mode': rule['mode']})
    return result

def state_query(root_paths, binary):
    """Join AST-derived sheet roots to every matching View declaration in one source root."""
    queries = [
        ('view', 'struct $NAME: $$$INHERITANCE { $$$BODY }'),
        ('generic-view', 'struct $NAME<$$$GENERIC>: $$$INHERITANCE { $$$BODY }'),
        ('managed-sheet', '$OBJ.tronManagedSheet($$$ARGS) { $$$BODY }'),
        ('progressive-link', 'TronProgressiveSheetLink($$$ARGS) { $$$BODY }'),
        ('settings-link', 'settingsLink($$$ARGS) { $$$BODY }'),
        ('construction', '$TYPE($$$ARGS)'),
        ('generic-construction', '$TYPE<$$$GENERIC>($$$ARGS)'),
        ('trailing-construction', '$TYPE { $$$BODY }'),
    ]
    paths = [str(ROOT / path) for path in root_paths if (ROOT / path).is_file()]
    if not paths:
        return []
    found = {}
    for name, pattern in queries:
        proc = subprocess.run([binary, 'run', '--lang', 'swift', '--pattern', pattern, '--json', *paths],
                              cwd=ROOT, capture_output=True, text=True)
        if proc.returncode not in (0, 1):
            raise RuntimeError(proc.stderr.strip() or proc.stdout.strip())
        found[name] = json.loads(proc.stdout or '[]')
    declarations = []
    for query in ('view', 'generic-view'):
        for match in found[query]:
            captures = match.get('metaVariables', {})
            name = captures.get('single', {}).get('NAME', {}).get('text')
            inheritance = [node['text'].strip() for node in captures.get('multi', {}).get('INHERITANCE', [])]
            if name and 'View' in inheritance:
                declarations.append((name, str(pathlib.Path(match['file']).resolve()), match['range']))
    view_names = {entry[0] for entry in declarations}
    if not view_names:
        return []
    closures = []
    for query in ('managed-sheet', 'progressive-link', 'settings-link'):
        for match in found[query]:
            for body in match.get('metaVariables', {}).get('multi', {}).get('BODY', []):
                closures.append((str(pathlib.Path(match['file']).resolve()), body['range']))
    destination_rule = '''id: destination-closure\nlanguage: Swift\nrule:\n  kind: value_argument\n  has:\n    kind: value_argument_label\n    regex: ^destination$\n'''
    with tempfile.TemporaryDirectory(prefix='tron-destination-') as directory:
        rule_path = pathlib.Path(directory) / 'rule.yml'
        rule_path.write_text(destination_rule.replace('id: destination-closure', f'id: destination-{secrets.token_hex(12)}'))
        proc = subprocess.run([binary, 'scan', '--rule', str(rule_path), '--error=no-suppress-all',
                               '--error=unused-suppression', '--json', *paths], cwd=ROOT,
                              capture_output=True, text=True)
        if proc.returncode not in (0, 1):
            raise RuntimeError(proc.stderr.strip() or proc.stdout.strip())
        for match in json.loads(proc.stdout or '[]'):
            closures.append((str(pathlib.Path(match['file']).resolve()), match['range']))
    constructors = found['construction'] + found['generic-construction'] + found['trailing-construction']
    root_hosts = collections.defaultdict(set)
    for constructor in constructors:
        name = constructor.get('metaVariables', {}).get('single', {}).get('TYPE', {}).get('text', '').strip()
        name = name.partition('<')[0].strip()
        if name not in view_names:
            continue
        location = constructor['range']
        location_start = (location['start']['line'], location['start']['column'])
        location_end = (location['end']['line'], location['end']['column'])
        for host_path, span in closures:
            span_start = (span['start']['line'], span['start']['column'])
            span_end = (span['end']['line'], span['end']['column'])
            if (host_path == str(pathlib.Path(constructor['file']).resolve()) and
                span_start <= location_start and location_end <= span_end):
                root_hosts[name].add(pathlib.Path(host_path).resolve().relative_to(ROOT).as_posix())
    if not root_hosts:
        return []
    state_rule = (ROOT / 'tools/rules/detectors/sheet-state.yml').read_text().replace(
        'id: sheet-state', f'id: sheet-state-{secrets.token_hex(12)}', 1)
    comment_rule = '''id: view-local-comment\nlanguage: Swift\nrule:\n  kind: comment\n  regex: ^//\\s*view-local:\\s*\\S\n'''
    state_matches, comments = [], []
    with tempfile.TemporaryDirectory(prefix='tron-sheet-state-') as directory:
        directory = pathlib.Path(directory)
        state_path = directory / 'state.yml'
        state_path.write_text(state_rule)
        comment_path = directory / 'comment.yml'
        comment_path.write_text(comment_rule.replace('id: view-local-comment', f'id: view-local-{secrets.token_hex(12)}'))
        for path, target in ((state_path, state_matches), (comment_path, comments)):
            proc = subprocess.run([binary, 'scan', '--rule', str(path), '--error=no-suppress-all',
                                   '--error=unused-suppression', '--json', *paths], cwd=ROOT,
                                  capture_output=True, text=True)
            if proc.returncode not in (0, 1):
                raise RuntimeError(proc.stderr.strip() or proc.stdout.strip())
            target.extend(json.loads(proc.stdout or '[]'))
    comment_lines = {(str(pathlib.Path(match['file']).resolve()), match['range']['start']['line'])
                     for match in comments if match['text'].split('view-local:', 1)[-1].strip()}
    results = []
    for match in state_matches:
        file_path = str(pathlib.Path(match['file']).resolve())
        state_pos = (match['range']['start']['line'], match['range']['start']['column'])
        containing = []
        for declaration in declarations:
            if declaration[1] != file_path:
                continue
            start = (declaration[2]['start']['line'], declaration[2]['start']['column'])
            end = (declaration[2]['end']['line'], declaration[2]['end']['column'])
            if start <= state_pos < end:
                containing.append(declaration)
        if not containing:
            continue
        view_name = min(containing, key=lambda declaration:
                        (declaration[2]['end']['line'] - declaration[2]['start']['line'],
                         declaration[2]['end']['column'] - declaration[2]['start']['column']))[0]
        if view_name not in root_hosts:
            continue
        line = match['range']['start']['line']
        if (file_path, line) in comment_lines:
            continue
        relative = pathlib.Path(file_path).relative_to(ROOT).as_posix()
        text = ' '.join(match['text'].split())
        results.append({'rule':'ios.presentation.sheet-state','file':relative,'line':line+1,'text':text,
                        'key':('ios.presentation.sheet-state',relative,text),
                        'decision':f'Sheet content {view_name} must use @PresentationState or explain genuinely view-local @State with // view-local: <reason>.',
                        'owner':'packages/ios-app/Sources/State/PresentationScopedState.swift','mode':'zero',
                        'hostFiles':sorted(root_hosts[view_name])})
    return results

def changed_files(base):
    paths=set(git('diff','--name-only',base,'--').splitlines())
    paths.update(git('ls-files','--others','--exclude-standard').splitlines())
    return normalize_paths(paths)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--validate', action='store_true')
    parser.add_argument('--files', nargs='*')
    parser.add_argument('--since')
    parser.add_argument('--format', choices=['agent','json'], default='agent')
    args=parser.parse_args()
    try:
        rules, errors=load_registry()
        if errors:
            print('\n'.join(errors), file=sys.stderr); return 1
        if args.validate: return 0
        binary=resolve_ast_grep()
        if any(rule['mode']=='ratchet' for rule in rules) and not args.since:
            raise RuntimeError('ratchet rules require --since <ref>; refusing to guess a baseline')
        base=None
        if args.since:
            ref=git('rev-parse','--verify',f'{args.since}^{{commit}}')
            base=git('merge-base','HEAD',ref)
            changed=changed_files(base)
        elif args.files is not None:
            changed=normalize_paths(args.files)
        else:
            changed=None
        all_findings=[]
        for rule in rules:
            paths=rule_paths(rule, changed)
            current=run_ast_grep(rule, paths, binary)
            if rule['mode']=='ratchet' and base:
                baseline_paths=tree_rule_paths(rule, base, set(paths))
                baseline=run_ast_grep(rule, baseline_paths, binary, tree=base)
                counts=collections.Counter(f['key'] for f in baseline)
                new=[]
                for finding in current:
                    if counts[finding['key']]: counts[finding['key']]-=1
                    else: new.append(finding)
                current=new
            if rule['mode']!='advise':
                all_findings.extend(current)
            else:
                all_findings.extend(current)
        # Run cross-file sheet state analysis per original input domain. When
        # changed-file scoped, scan the domain for joins but report only if its
        # host closure or violating @State declaration changed.
        for domain in ('packages/ios-app/Sources', 'packages/ios-app/SwiftAppEngine'):
            domain_paths=sorted(p.relative_to(ROOT).as_posix() for p in (ROOT/domain).rglob('*.swift'))
            state_findings=state_query(domain_paths, binary)
            if changed is not None:
                state_findings=[f for f in state_findings
                                if f['file'] in changed or set(f.get('hostFiles', [])) & changed]
            all_findings.extend(state_findings)
        seen=set(); unique=[]
        for finding in all_findings:
            if finding['key'] not in seen:
                seen.add(finding['key']); unique.append(finding)
        all_findings=unique
        if args.format=='json':
            print(json.dumps(all_findings, indent=2))
        else:
            for finding in all_findings:
                print(f"{finding['file']}:{finding['line']}: {finding['decision']} Owner: {finding['owner']}. Suggested fix: use the owner API.")
        return int(any(finding['mode']!='advise' for finding in all_findings))
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f'rules check failed closed: {error}', file=sys.stderr)
        return 1
if __name__=='__main__': sys.exit(main())
