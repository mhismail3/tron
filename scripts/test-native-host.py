import importlib.util
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

    def tearDown(self):
        self.temp.cleanup()

    def put(self, relative, value):
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def test_valid_composition(self):
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
