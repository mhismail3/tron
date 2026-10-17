#!/usr/bin/env python3
"""Real-boundary regressions for tools/rules: the ast-grep detectors, the `scripts/tron rules` CLI,
ratchet against git history, suppression handling and fail-closed exits.

Every case runs in a disposable git repository that holds copies of the rule registry, detectors,
toolchain pin and scripts/tron, so the live product tree is never mutated. The detector cases run
as `ast-grep test` in the live repository and must execute (not skip).
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
IOS_DIR = 'packages/ios-app'
SOURCES = f'{IOS_DIR}/Sources'
UI = f'{SOURCES}/UI'
RAW_SHEET = 'Foo().sheet(isPresented: $shown) { Text("x") }'
SPINNER = 'ProgressView()'
LOADING_TEXT = 'Text("Loading Home…")'
HOST = '.modifier(TronSheetLoadingHostModifier())'
RAW_SHEET_DECISION = 'App-owned sheets use the activity-managed presentation modifiers.'
SPINNER_DECISION = 'not indeterminate system spinners.'
TEXT_DECISION = 'not visible loading placeholder text.'
HOST_DECISION = 'Only presentation surfaces and the app root host the sheet loading pulse.'
CORE_DECISION = 'TronMobileCore remains Foundation-only'
FILE_WIDE = 'Do not use file-wide ast-grep suppression directives.'
UNUSED = 'Remove unused ast-grep suppression directives'
HOST_FILE = f'{UI}/A.swift'
DRAFT_FILE = f'{UI}/B.swift'


class Repo:
    def __init__(self, root):
        self.root = root

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def git(self, *args):
        subprocess.run(['git', *args], cwd=self.root, check=True, capture_output=True, text=True)

    def commit(self, message):
        self.git('add', '-A')
        self.git('-c', 'user.name=rules-test', '-c', 'user.email=rules-test@example.invalid',
                 'commit', '-q', '--no-verify', '-m', message)

    def rules_cli(self, *args, cwd=None, env=None):
        return subprocess.run([str(self.root / 'scripts/tron'), 'rules', *args], cwd=cwd or self.root,
                              capture_output=True, text=True, env=env)

    def registry(self):
        return json.loads((self.root / 'tools/rules/rules.yaml').read_text())

    def set_registry(self, rules):
        (self.root / 'tools/rules/rules.yaml').write_text(json.dumps(rules, indent=2, ensure_ascii=False) + '\n')


def make_repo(parent):
    root = parent / 'repo'
    root.mkdir(parents=True)
    for relative in ('tools/rules', 'scripts/tron', 'config/ci-toolchain.env', 'sgconfig.yml'):
        source, target = ROOT / relative, root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, target, ignore=shutil.ignore_patterns('__pycache__'))
        else:
            shutil.copy2(source, target)
    repo = Repo(root)
    repo.git('init', '-q')
    repo.git('config', 'commit.gpgsign', 'false')
    # Owners and allowances name real files; a fixture creates each as an empty file.
    for rule in repo.registry():
        owner = rule['owner'].partition('#')[0]
        for relative in [owner, *rule.get('allow', {}).get('paths', []),
                         *[path for path, _ in rule.get('allow', {}).get('literals', [])]]:
            if not (root / relative).exists():
                repo.write(relative, '')
    return repo


def check(name, condition, detail=''):
    if not condition:
        raise AssertionError(f'{name}: {detail}')
    print(f'passed: {name}')


def expect(name, result, status, *needles):
    output = result.stdout + result.stderr
    check(name, result.returncode == status, f'exit {result.returncode} != {status}: {output}')
    for needle in needles:
        check(f'{name} reports {needle!r}', needle in output, output)


def ios_case(repo, relative, text):
    repo.write(relative, text)
    return repo.rules_cli('check', '--files', relative, '--format', 'agent')


def detector_cases():
    sys.path.insert(0, str(ROOT / 'tools/rules'))
    import run
    proc = subprocess.run([run.resolve_ast_grep(), 'test'], cwd=ROOT, capture_output=True, text=True)
    output = proc.stdout + proc.stderr
    counted = re.search(r'Running (\d+) tests', output)
    check('ast-grep test executes the detector cases', counted and int(counted.group(1)) >= 6 and proc.returncode == 0, output)


def live_tree():
    proc = subprocess.run([str(ROOT / 'scripts/tron'), 'rules', 'check', '--format', 'agent'], cwd=ROOT,
                          capture_output=True, text=True)
    check('live tree passes every registered rule', proc.returncode == 0, proc.stdout + proc.stderr)
    validate = subprocess.run([str(ROOT / 'scripts/tron'), 'rules', '--validate'], cwd=ROOT,
                              capture_output=True, text=True)
    check('live registry metadata validates', validate.returncode == 0, validate.stderr)


def structural_cases(repo):
    expect('raw sheet outside the owner fails', ios_case(repo, f'{UI}/Chat/Raw.swift', RAW_SHEET),
           1, RAW_SHEET_DECISION)
    expect('raw sheet in the presentation owner is allowed',
           ios_case(repo, f'{SOURCES}/State/PresentationActivityCoordinator.swift', RAW_SHEET), 0)
    expect('spinner outside the owners fails', ios_case(repo, f'{UI}/Chat/Spin.swift', SPINNER), 1, SPINNER_DECISION)
    expect('determinate spinner is allowed',
           ios_case(repo, f'{UI}/Chat/Spin.swift', 'struct S: View { var body: some View { ProgressView(value: 3, total: 10) } }'), 0)
    expect('a value-looking string is not a determinate argument',
           ios_case(repo, f'{UI}/Chat/Spin.swift', 'ProgressView("value: a string, not a value argument")'), 1, SPINNER_DECISION)
    expect('exact spinner path allowance covers only its own file',
           ios_case(repo, f'{UI}/Chat/HomePinnedRow.swift', SPINNER), 0)
    expect('spinner allowance does not allow loading text in that file',
           ios_case(repo, f'{UI}/Chat/HomePinnedRow.swift', LOADING_TEXT), 1, TEXT_DECISION)
    expect('the interpreted SwiftApps owner keeps its own spinner',
           ios_case(repo, f'{UI}/SwiftApps/SwiftAppViews.swift', SPINNER), 0)
    expect('loading text literal fails outside its exact path pair',
           ios_case(repo, f'{UI}/Loading.swift', 'Text("Preparing details…")'), 1, TEXT_DECISION)
    expect('exact loading text pair is allowed',
           ios_case(repo, f'{UI}/Chat/ChatTranscriptEventViews.swift', 'Text("Preparing details…")'), 0)
    expect('host identifier outside the owners fails', ios_case(repo, f'{UI}/Settings/New.swift', HOST), 1, HOST_DECISION)
    expect('host identifier in the app root is allowed',
           ios_case(repo, f'{SOURCES}/App/TronMobileApp.swift', HOST), 0)
    expect('comments and strings are not loading policy syntax',
           ios_case(repo, f'{UI}/Loading.swift',
                    'let harmless = "TronSheetLoadingHostModifier ProgressView() Text(\\"Loading Home…\\")"\n'
                    '// TronSheetLoadingHostModifier ProgressView()\n'), 0)
    expect('Core rejects a preconcurrency UI import',
           ios_case(repo, f'{SOURCES}/Core/Probe.swift', '@preconcurrency import UIKit\n'), 1, CORE_DECISION)
    expect('Core accepts Foundation', ios_case(repo, f'{SOURCES}/Core/Probe.swift', 'import Foundation\n'), 0)


def sheet_state_cases(repo):
    host = ('struct Host: View { var body: some View {\n'
            '  item.tronManagedSheet(isPresented: $shown, identity: "draft") { Wrapper { Draft<Int>() } }\n'
            '  TronProgressiveSheetLink(accessibilityLabel: "progressive") { ProgressiveDraft() } label: { EmptyView() }\n'
            '  settingsLink(title: "settings") { SettingsDraft() }\n'
            '  Row(title: "destination", destination: { DestinationDraft() })\n'
            '} }\n')
    repo.write(HOST_FILE, host)
    repo.write(DRAFT_FILE, 'struct Draft<T>: View {\n  @State private var text = "one"\n  var body: some View { EmptyView() }\n}\n')
    repo.write(f'{UI}/Progressive.swift', 'struct ProgressiveDraft: View {\n  @State private var text = "bad"\n  var body: some View { EmptyView() }\n}\n')
    repo.write(f'{UI}/Settings.swift', 'struct SettingsDraft: View {\n  @State private var text = "bad"\n  var body: some View { EmptyView() }\n}\n')
    repo.write(f'{UI}/Destination.swift', 'struct DestinationDraft: View {\n  @State private var text = "bad"\n  var body: some View { EmptyView() }\n}\n')
    result = repo.rules_cli('check', '--files', DRAFT_FILE, '--format', 'agent')
    expect('changed Draft file is joined to its unchanged host (generic, managed)', result, 1, 'Sheet content Draft must use @PresentationState')
    expect('progressive destination constructs a root', repo.rules_cli('check', '--files', f'{UI}/Progressive.swift', '--format', 'agent'), 1,
           'Sheet content ProgressiveDraft must use')
    expect('settingsLink trailing closure constructs a root', repo.rules_cli('check', '--files', f'{UI}/Settings.swift', '--format', 'agent'), 1,
           'Sheet content SettingsDraft must use')
    expect('destination argument constructs a root', repo.rules_cli('check', '--files', f'{UI}/Destination.swift', '--format', 'agent'), 1,
           'Sheet content DestinationDraft must use')
    expect('changed host reports the unchanged-state host join', repo.rules_cli('check', '--files', HOST_FILE, '--format', 'agent'), 1,
           'Sheet content Draft must use')
    repo.write(DRAFT_FILE, 'struct Draft<T>: View {\n  @PresentationState private var text = "one"\n  @State private var pulse = false // view-local: animation phase\n  var body: some View { EmptyView() }\n}\n'
                           'struct Unrelated: View { @State private var b = 0\n var body: some View { EmptyView() } }\n')
    repo.write(f'{UI}/Progressive.swift', '')
    repo.write(f'{UI}/Settings.swift', '')
    repo.write(f'{UI}/Destination.swift', '')
    expect('presentation state and justified view-local state pass', repo.rules_cli('check', '--files', DRAFT_FILE, '--format', 'agent'), 0)
    repo.write(DRAFT_FILE, 'struct Draft: View { @State private var text = "bad" \n var body: some View { EmptyView() } }\n')
    repo.write(f'{UI}/Other.swift', 'struct Draft: View { @State private var kept = 1\n var body: some View { EmptyView() } }\n')
    expect('same-name view in an unrelated file is judged by the same hosted name',
           repo.rules_cli('check', '--files', f'{UI}/Other.swift', '--format', 'agent'), 1, 'Sheet content Draft must use')


def suppression_cases(repo):
    expect('targeted ignore cannot hide the AST finding',
           ios_case(repo, f'{UI}/Chat/Suppressed.swift', f'// ast-grep-ignore: raw-sheet\n{RAW_SHEET}\n'), 1, RAW_SHEET_DECISION)
    expect('unused ignore is reported',
           ios_case(repo, f'{UI}/Chat/Suppressed.swift', '// ast-grep-ignore: raw-sheet\nlet note = 1\n'), 1, UNUSED)
    expect('file-wide ignore is rejected',
           ios_case(repo, f'{UI}/Chat/Suppressed.swift', f'// ast-grep-ignore\n{RAW_SHEET}\n'), 1, FILE_WIDE)
    expect('ignore syntax inside a string is not a directive',
           ios_case(repo, f'{UI}/Chat/Suppressed.swift', 'let note = "ast-grep-ignore: raw-sheet .sheet(item:)"\n'), 0)


def ratchet_cases(parent):
    repo = make_repo(parent / 'ratchet')
    rules = repo.registry()
    for rule in rules:
        if rule['id'] == 'ios.presentation.raw-sheet':
            rule['mode'] = 'ratchet'
    repo.set_registry(rules)
    file_path = f'{UI}/Chat/Ratchet.swift'
    repo.write(file_path, f'{RAW_SHEET}\n')
    repo.commit('base')
    base = 'HEAD'
    expect('ratchet without a base ref refuses to guess', repo.rules_cli('check'), 1, 'refusing to guess a baseline')
    expect('no new findings passes', repo.rules_cli('check', '--since', base), 0)
    repo.write(file_path, f'{RAW_SHEET}\n{RAW_SHEET}\n')
    expect('a duplicate identical finding is new', repo.rules_cli('check', '--since', base, '--format', 'agent'), 1, RAW_SHEET_DECISION)
    repo.git('checkout', '-q', '--', file_path)
    repo.write(file_path, f'{RAW_SHEET}\n{RAW_SHEET.replace("shown", "other")}\n')
    expect('a new finding in an existing file is new', repo.rules_cli('check', '--since', base), 1, RAW_SHEET_DECISION)
    repo.git('checkout', '-q', '--', file_path)
    repo.write(file_path, '')
    expect('removing the finding is not new', repo.rules_cli('check', '--since', base), 0)
    repo.git('checkout', '-q', '--', file_path)
    repo.git('mv', file_path, f'{UI}/Chat/Moved.swift')
    expect('moved code is judged as new findings at its new path (ratchet keys by path)',
           repo.rules_cli('check', '--since', base), 1, RAW_SHEET_DECISION)
    expect('missing base ref fails closed', repo.rules_cli('check', '--since', 'no-such-ref'), 1, 'does not exist')


def advise_and_registry_cases(parent):
    repo = make_repo(parent / 'advise')
    rules = repo.registry()
    for rule in rules:
        if rule['id'] == 'ios.presentation.raw-sheet':
            rule['mode'] = 'advise'
    repo.set_registry(rules)
    result = ios_case(repo, f'{UI}/Chat/Advised.swift', RAW_SHEET)
    expect('advise prints a nonfatal finding', result, 0, 'advisory:', RAW_SHEET_DECISION)

    repo = make_repo(parent / 'expired')
    rules = repo.registry()
    rules[0]['expires'] = '2020-01-01'
    repo.set_registry(rules)
    result = repo.rules_cli('--validate')
    expect('expired rule date is reported without failing', result, 0, 'expired rule: ios.presentation.raw-sheet')

    repo = make_repo(parent / 'metadata')
    rules = repo.registry()
    del rules[0]['decision']
    repo.set_registry(rules)
    expect('missing metadata fails validation', repo.rules_cli('--validate'), 1, 'missing metadata decision')

    repo = make_repo(parent / 'orphan')
    repo.write('tools/rules/detectors/stray.yml', 'id: stray\nlanguage: Swift\nrule:\n  pattern: x\n')
    expect('orphan detector fails validation', repo.rules_cli('--validate'), 1, 'orphan detector')

    repo = make_repo(parent / 'missing-test')
    (repo.root / 'tools/rules/tests/raw-sheet.yml').unlink()
    expect('detector without cases fails validation', repo.rules_cli('--validate'), 1, 'missing rule tests')

    repo = make_repo(parent / 'stale-allowance')
    rules = repo.registry()
    rules[0]['allow']['paths'].append(f'{UI}/Gone.swift')
    repo.set_registry(rules)
    expect('allowance naming a missing file fails validation', repo.rules_cli('--validate'), 1, 'missing file')


def toolchain_cases(parent):
    repo = make_repo(parent / 'toolchain')
    minimal_path = '/usr/bin:/bin'
    env = {'PATH': minimal_path, 'HOME': str(parent), 'TMPDIR': str(parent)}
    result = repo.rules_cli('check', '--files', f'{UI}/Chat/Raw.swift', env=env)
    expect('ast-grep unavailable fails closed', result, 1, 'ast-grep is unavailable')
    config = repo.root / 'config/ci-toolchain.env'
    config.write_text(config.read_text().replace('TRON_CI_AST_GREP_VERSION=0.42.1', 'TRON_CI_AST_GREP_VERSION=0.0.1'))
    result = repo.rules_cli('check', '--files', f'{UI}/Chat/Raw.swift')
    expect('pinned ast-grep version mismatch fails closed', result, 1, 'version mismatch')


def root_relative_cases(parent):
    repo = make_repo(parent / 'paths')
    repo.write(f'{UI}/Chat/Raw.swift', RAW_SHEET + '\n')
    result = repo.rules_cli('check', '--files', f'{UI}/Chat/Raw.swift', '--format', 'agent', cwd=repo.root / IOS_DIR)
    expect('root-relative paths are independent of the working directory', result, 1, RAW_SHEET_DECISION)
    result = repo.rules_cli('check', '--files', '/etc/hosts')
    expect('a file outside the repository fails closed', result, 1, 'outside repository')
    json_result = repo.rules_cli('check', '--files', f'{UI}/Chat/Raw.swift', '--format', 'json')
    check('json output is parseable', json.loads(json_result.stdout)[0]['rule'] == 'ios.presentation.raw-sheet', json_result.stdout)


def main():
    failures = []
    with tempfile.TemporaryDirectory(prefix='tron-rules-boundaries-') as directory:
        parent = pathlib.Path(directory)
        cases = [
            ('live', lambda: (live_tree(), detector_cases())),
            ('structural', lambda: structural_cases(make_repo(parent / 'structural'))),
            ('sheet-state', lambda: sheet_state_cases(make_repo(parent / 'state'))),
            ('suppression', lambda: suppression_cases(make_repo(parent / 'suppression'))),
            ('ratchet', lambda: ratchet_cases(parent)),
            ('advise-registry', lambda: advise_and_registry_cases(parent)),
            ('toolchain', lambda: toolchain_cases(parent)),
            ('paths', lambda: root_relative_cases(parent)),
        ]
        for name, run in cases:
            try:
                run()
            except AssertionError as error:
                failures.append(f'{name}: {error}')
                print(f'FAILED {name}: {error}', file=sys.stderr)
    if failures:
        return 1
    print('rules boundary tests passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
