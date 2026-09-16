#!/usr/bin/env python3
"""One-time offline agent-home cutover. Retire this entrypoint after migration."""
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import sys

from tron_mac_reinstall import (Reinstall, Stop, command, exists, main, manifest_digest,
                               owned_container, private_dir, read_json, rename_exclusive, require,
                               safe_path, sync_tree, tree_manifest, write_json)


# This is a reviewed one-time bootstrap, not a generic missing-helper fallback.
# This revision contains no native-host code or update control; see the runbook.
PRE_HELPER_REVISION = '0f376b197df6603c32cee3a5706e0295c1705e55'


def verify_pre_helper_layout(app):
    """Called only after the old app's signature and recorded identity pass."""
    library = safe_path(app / 'Contents/Library')
    require({p.name for p in library.iterdir()} == {'LaunchAgents', 'LoginItems'},
            'pre-helper-ineligible: unexpected embedded capability; use reviewed native retirement')
    agents = safe_path(library / 'LaunchAgents')
    items = safe_path(library / 'LoginItems')
    require({p.name for p in agents.iterdir()} == {'com.tron.server.plist'}
            and {p.name for p in items.iterdir()} == {'Tron Agent.app'},
            'pre-helper-ineligible: old app does not match the reviewed service layout')
    manifest = safe_path(app / 'Contents/Resources/Gateway/manifest.json')
    plist = safe_path(agents / 'com.tron.server.plist')
    for path in (manifest, plist):
        require(path.is_file() and path.stat().st_size <= 65536,
                'pre-helper-ineligible: missing or oversized signed metadata')
    with manifest.open('rb') as stream:
        metadata = json.load(stream)
    with plist.open('rb') as stream:
        service = plistlib.load(stream)
    require(isinstance(metadata, dict) and metadata.get('schema') == 1
            and metadata.get('kind') == 'tron-gateway-payload'
            and metadata.get('sourceRevision') == PRE_HELPER_REVISION
            and isinstance(service, dict) and service.get('Label') == 'com.tron.server',
            'pre-helper-ineligible: old app revision is not the reviewed pre-helper build')


class AgentHomeCutover(Reinstall):
    """One-time operator cutover: an explicit offline confirmation backs up,
    stages and moves the agent authority into ~/.tron/agent. Never replaces or
    launches an app. Pre-helper confirmation is restricted to a reviewed build."""

    kind = 'agent-home-cutover'
    confirmation_options = dict(Reinstall.confirmation_options,
                                confirm_pre_helper_offline='attest all writers stopped; requires the reviewed signed pre-helper build')
    phases = ('awaiting-offline', 'backing-up', 'staging', 'publishing',
              'awaiting-replacement', 'awaiting-resume', 'verified')

    def source_agent(self):
        return self.home / '.pi/agent'

    def offline_confirmation(self, args):
        if not getattr(args, 'confirm_pre_helper_offline', False):
            confirmed = super().offline_confirmation(args)
            if not confirmed:
                print('For the reviewed pre-helper build only, use --confirm-pre-helper-offline after stopping all writers.')
            return confirmed
        old_app = (self.platform.installed if self.receipt['phase'] in ('awaiting-offline', 'backing-up')
                   else self.operation / 'backups/old-app')
        require(self.platform.validate_app(old_app, False) == self.receipt['original'],
                'pre-helper-identity: original signed app changed; do not proceed')
        verify_pre_helper_layout(old_app)
        self.receipt['retirementBasis'] = 'reviewed-pre-helper-' + PRE_HELPER_REVISION
        self.save()
        print('Reviewed pre-helper build verified: native drain is not applicable. All offline and backup gates still apply.')
        return True

    @property
    def destination(self):
        return self.home / '.tron/agent'

    @property
    def staging(self):
        return self.home / '.tron' / ('.agent-cutover-' + self.receipt['id'])

    @property
    def retired(self):
        return self.home / '.pi' / ('.agent-retired-' + self.receipt['id'])

    def layout(self):
        owned_container(self.home / '.tron')
        owned_container(self.home / '.pi')
        private_dir(self.source_agent())
        require(not exists(self.destination), 'destination-present: use mac reinstall if already migrated; never merge homes')
        require(self.source_agent().stat().st_dev == (self.home / '.tron').stat().st_dev == self.store.stat().st_dev,
                'cross-filesystem: this cutover supports only same-filesystem publication')

    def required_copy_bytes(self, sizes):
        return super().required_copy_bytes(sizes) + sizes['agent']

    def excluded_state_entries(self):
        names = super().excluded_state_entries()
        if self.receipt:
            names |= {self.staging.name, self.staging.name + '.tron-agent-migration.json'}
        return names

    def migration(self, operation, *arguments):
        app = Path(self.receipt['app'])
        payload = app / 'Contents/Resources/Gateway'
        require(platform.machine() in ('arm64', 'x86_64'), 'unsupported-architecture: use a reviewed Mac runtime')
        architecture = 'arm64' if platform.machine() == 'arm64' else 'x64'
        node = safe_path(payload / 'runtime' / ('node-' + architecture))
        name = 'agent-home-preflight.js' if operation == 'preflight' else 'agent-home-migration.js'
        script = safe_path(payload / 'app/dist' / name)
        require(script.is_file(), 'migration-tool-missing: prepare a Release app containing the cutover tools')
        argv = [node, script]
        if operation != 'preflight':
            argv.append(operation)
        output = command([*argv, *arguments], 'agent-home-' + operation,
                         accepted=(0, 2) if operation == 'preflight' else (0,))
        return json.loads(output)

    def prepare(self):
        result = self.migration('preflight', '--source', self.source_agent(), '--destination', self.destination)
        require(isinstance(result, dict) and isinstance(result.get('issues'), list)
                and all(isinstance(item, dict) for item in result['issues']),
                'preflight-invalid: canonical assessment did not return a valid result')
        codes = sorted({item['code'] for item in result.get('issues', [])
                        if isinstance(item, dict) and isinstance(item.get('code'), str)
                        and re.fullmatch(r'[a-z-]{1,80}', item['code'])})
        require(result.get('status') == 'assessment-only'
                and all(item.get('code') == 'writer-quiescence-unproven' for item in result.get('issues', [])),
                'preflight-decision: resolve canonical preflight findings before cutover: ' + ', '.join(codes[:20]))
        self.backup()
        self.save('staging')

    def stage(self):
        # Existing canonical tooling owns path/schema decisions and the single
        # supported settings transform. Never patch staged settings after verify.
        if not exists(self.staging) and not exists(Path(str(self.staging) + '.tron-agent-migration.json')):
            settings = self.source_agent() / 'settings.json'
            options = []
            if exists(settings):
                safe_path(settings)
                require(settings.stat().st_size <= 1024 * 1024, 'settings-size: bounded settings required')
                with settings.open() as stream:
                    document = json.load(stream)
                require(isinstance(document, dict), 'settings-invalid: expected settings object')
                legacy = 'npm:@zhushanwen/pi-ask-user@7.0.15'
                packages = document.get('packages', [])
                require(isinstance(packages, list), 'settings-invalid: packages must be a list')
                if any(value == legacy or isinstance(value, dict) and value.get('source') == legacy for value in packages):
                    options = ['--remove-legacy-ask-user']
            self.migration('stage', '--source', self.source_agent(), '--destination', self.destination,
                           '--staging', self.staging, '--acknowledge-quiescence', '--acknowledge-backup', *options)
        # An interrupted canonical stage stays marked and fails closed here.
        # Its explicit cleanup command is the only owner allowed to remove it.
        verified = self.migration('verify', '--staging', self.staging)
        require(verified.get('changesMade') is False and verified.get('publicationMode') == 'same-filesystem-rename',
                'stage-invalid: publication requires verified same-filesystem staging')
        source = tree_manifest(self.source_agent())
        require(manifest_digest(source) == self.receipt['components']['agent'],
                'source-changed: staged source differs from verified backup')
        staged = tree_manifest(self.staging)
        require(set(source) == set(staged) and all(
            all(source[name][key] == staged[name][key] for key in ('mode', 'acl', 'xattrs', 'type'))
            for name in source), 'stage-metadata-mismatch: canonical staging lost metadata; do not publish or edit the verified tree')
        sync_tree(self.staging, staged)
        write_json(self.operation / 'published-agent.json', staged)
        self.receipt['publishedDigest'] = manifest_digest(staged)
        # Save intent and inode identities before either rename. Recovery admits
        # exactly these trees, including a crash between rename and receipt write.
        self.receipt['sourceInode'] = self.source_agent().stat().st_ino
        self.receipt['stagingInode'] = self.staging.stat().st_ino
        self.save('publishing')

    def publish(self):
        owned_container(self.home / '.tron')
        owned_container(self.home / '.pi')
        source, staged, retired, destination = self.source_agent(), self.staging, self.retired, self.destination
        for path in (source, staged, retired, destination):
            safe_path(path)
        expected_source = read_json(self.operation / 'agent.json')
        expected_staged = read_json(self.operation / 'published-agent.json')
        require(manifest_digest(expected_source) == self.receipt['components']['agent']
                and manifest_digest(expected_staged) == self.receipt['publishedDigest'],
                'manifest-corrupt: publication evidence changed')
        self.platform.offline()
        self.verify_backups()
        # Changes to other owners' state invalidate the offline backup just as
        # agent writes do. Check before retiring either authority, not afterward.
        for name, path in self.sources().items():
            if name != 'agent':
                expected = read_json(self.operation / f'{name}.json')
                require((tree_manifest(path) if exists(path) else None) == expected,
                        f'source-changed: {name}; stop publication until offline ownership is resolved')
        if exists(source):
            require(not exists(retired) and not exists(destination), 'publication-collision: preserve all roots for review')
            require(source.stat().st_ino == self.receipt['sourceInode'] and tree_manifest(source) == expected_source,
                    'source-changed: original authority differs from verified source')
            require(exists(staged) and staged.stat().st_ino == self.receipt['stagingInode']
                    and tree_manifest(staged) == expected_staged, 'stage-changed: staged authority differs from verified tree')
            rename_exclusive(source, retired)
        require(exists(retired) and retired.stat().st_ino == self.receipt['sourceInode']
                and tree_manifest(retired) == expected_source, 'retired-home-mismatch: stop and review rollback evidence')
        if exists(staged):
            require(not exists(destination), 'publication-collision: destination already exists')
            require(staged.stat().st_ino == self.receipt['stagingInode'] and tree_manifest(staged) == expected_staged,
                    'stage-changed: verified tree changed after old home retirement')
            self.platform.offline()
            rename_exclusive(staged, destination)
        require(exists(destination) and destination.stat().st_ino == self.receipt['stagingInode']
                and tree_manifest(destination) == expected_staged, 'published-home-mismatch: do not activate')
        self.save('awaiting-replacement')

    def continue_offline(self, args):
        if self.receipt['phase'] == 'staging':
            self.stage()
        if self.receipt['phase'] == 'publishing':
            self.publish()
        super().continue_offline(args)

    def before_activation(self, app_replaced=False):
        owned_container(self.home / '.tron')
        owned_container(self.home / '.pi')
        private_dir(self.destination)
        self.verify_backups()
        require(not exists(self.source_agent()), 'dual-authority: old source was recreated; do not activate')
        expected = read_json(self.operation / 'published-agent.json')
        require(manifest_digest(expected) == self.receipt['publishedDigest']
                and tree_manifest(self.destination) == expected, 'published-home-changed: do not replace or activate')
        for name, source in self.sources().items():
            if name == 'old-app' and app_replaced:
                continue
            if name == 'agent':
                source = self.retired
            expected = read_json(self.operation / f'{name}.json')
            require(manifest_digest(expected) == self.receipt['components'][name]
                    and (tree_manifest(source) if exists(source) else None) == expected,
                    f'source-changed: {name}; do not activate from outdated evidence')

    def verify(self):
        owned_container(self.home / '.tron')
        owned_container(self.home / '.pi')
        require(not exists(self.source_agent()), 'dual-authority: old agent home is present; do not claim success')
        private_dir(self.destination)
        identity = self.platform.validate_app(self.platform.installed)
        require(identity == self.receipt['candidate'], 'wrong-installed-app: replacement does not match recorded artifact')
        self.platform.verify_installed()
        self.save('verified')


if __name__ == '__main__':
    sys.exit(main(AgentHomeCutover))
