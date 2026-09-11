import importlib.util
import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('native_validator', Path(__file__).with_name('validate-native-host.py'))
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class NativeCompositionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.app = Path(self.temp.name) / 'Tron.app'
        self.agent = 'Contents/Library/LaunchAgents/' + validator.SERVICE + '.plist'
        self.put(self.agent, validator.AGENT)
        self.put('Contents/Info.plist', {'TronSigningTeam': 'EXAMPLE123'})
        self.put(validator.BUNDLE + '/Contents/Info.plist', {
            'TronSigningTeam': 'EXAMPLE123', 'CFBundleIdentifier': validator.SERVICE,
            'CFBundleExecutable': 'TronNativeHost', 'LSUIElement': True, 'LSBackgroundOnly': False})
        executable = self.app / validator.EXECUTABLE
        executable.parent.mkdir(parents=True)
        executable.write_text('offline fixture; never executed')
        executable.chmod(0o700)
        (self.app / validator.CLIENT).write_bytes(b'offline fixture' * 100)
        (self.app / validator.CLIENT_INPUTS).write_text(json.dumps({
            'schema': 1, 'testOnly': False, 'inputs': {'fixture': '0' * 64}}))
        cua = self.app / validator.CUA
        cua.write_bytes(b'offline Cua fixture'); cua.chmod(0o755)
        (self.app / 'Contents/Library/Native/cua-driver-LICENSE.txt').write_text('fixture license')
        (self.app / validator.CUA_MANIFEST).write_text(json.dumps({
            'version': '0.28.0', 'revision': '0' * 40, 'githubPrerelease': True, 'upstreamSigner': 'YCK386LBJ7',
            'archiveSHA256': '0' * 64, 'binarySHA256': hashlib.sha256(cua.read_bytes()).hexdigest()}))

    def tearDown(self):
        self.temp.cleanup()

    def put(self, relative, value):
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def test_valid_composition(self):
        validator.validate(self.app)

    def test_cua_bytes_must_match_manifest_and_cannot_be_symlinked(self):
        cua = self.app / validator.CUA
        original = cua.read_bytes(); cua.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'pinned release'):
            validator.validate(self.app)
        cua.unlink(); cua.symlink_to('/bin/echo')
        with self.assertRaisesRegex(ValueError, 'Symlink'):
            validator.validate(self.app)
        cua.unlink(); cua.write_bytes(original); cua.chmod(0o755)
        (self.app / validator.CUA_MANIFEST).unlink()
        with self.assertRaises(FileNotFoundError): validator.validate(self.app)

    def test_outer_release_product_name_cannot_replace_native_executable(self):
        executable = self.app / validator.EXECUTABLE
        executable.rename(executable.with_name('Tron'))
        with self.assertRaises(FileNotFoundError):
            validator.validate(self.app)

    def test_duplicate_auto_embedded_host_is_rejected(self):
        host = plistlib.loads((self.app / validator.BUNDLE / 'Contents/Info.plist').read_bytes())
        self.put('Contents/Resources/TronNativeHost.app/Contents/Info.plist', host)
        with self.assertRaisesRegex(ValueError, 'Duplicate native helper'):
            validator.validate(self.app)

    def test_missing_service_is_rejected(self):
        (self.app / self.agent).unlink()
        with self.assertRaises(FileNotFoundError):
            validator.validate(self.app)

    def test_mach_identity_scope_and_program_are_not_optional(self):
        for field, bad in [('MachServices', {}), ('Label', 'wrong'), ('BundleProgram', '/tmp/foreign'),
                           ('LimitLoadToSessionType', 'Background'), ('AssociatedBundleIdentifiers', [])]:
            altered = dict(validator.AGENT)
            altered[field] = bad
            self.put(self.agent, altered)
            with self.assertRaises(ValueError):
                validator.validate(self.app)

    def test_capture_role_is_required_and_not_a_permission_alias(self):
        for services in [{validator.SERVICE: True},
                         {validator.SERVICE: True, validator.CAPTURE_SERVICE: False},
                         {validator.SERVICE: True, validator.CAPTURE_SERVICE: 1},
                         {validator.SERVICE: True, validator.CAPTURE_SERVICE: True, 'extra': True}]:
            altered = dict(validator.AGENT, MachServices=services)
            self.put(self.agent, altered)
            with self.assertRaises(ValueError):
                validator.validate(self.app)

    def test_missing_or_test_only_client_is_rejected(self):
        path = self.app / validator.CLIENT_INPUTS
        path.write_text(json.dumps({'schema': 1, 'testOnly': True, 'inputs': {'fixture': '0' * 64}}))
        with self.assertRaisesRegex(ValueError, 'production input manifest'):
            validator.validate(self.app)
        path.unlink()
        with self.assertRaises(FileNotFoundError):
            validator.validate(self.app)

    def test_symlink_or_wrong_team_cannot_pass(self):
        executable = self.app / validator.EXECUTABLE
        executable.unlink()
        executable.symlink_to('/bin/echo')
        with self.assertRaises(ValueError):
            validator.validate(self.app)
        executable.unlink(); executable.write_text('fixture'); executable.chmod(0o700)
        self.put('Contents/Info.plist', {'TronSigningTeam': 'OTHER12345'})
        with self.assertRaises(ValueError):
            validator.validate(self.app)


if __name__ == '__main__':
    unittest.main()
