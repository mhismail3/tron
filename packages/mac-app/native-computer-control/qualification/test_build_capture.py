import contextlib
import io
import tempfile
from pathlib import Path
import unittest
from build_capture import arguments, freeze_sources, output_path, source_inventory, signing_policy


class CaptureBuildInputTests(unittest.TestCase):
    def test_only_capture_is_built(self):
        # The qualification artifact must never build a different product; the
        # exact argv it uses is the build script's own concern.
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            arguments(['--output', '/private/tmp/unused', '--product', 'observer'])

    def test_signing_requires_an_existing_development_certificate(self):
        identity = 'A' * 40
        inventory = f'1) {identity} "Apple Development: Fixture"\n'
        self.assertEqual(signing_policy(None, inventory, 'ABCDEFGHIJ'), identity)
        for invalid in ['-', 'B' * 40, 'Apple Development: Fixture']:
            with self.assertRaises(ValueError): signing_policy(invalid, inventory, 'ABCDEFGHIJ')
        multiple = inventory + f'2) {"B" * 40} "Apple Development: Other"\n'
        with self.assertRaises(ValueError): signing_policy(None, multiple, 'ABCDEFGHIJ')
        self.assertEqual(signing_policy(identity, multiple, 'ABCDEFGHIJ'), identity)

    def test_shared_output_boundary_rejects_owned_stores(self):
        for home in ['.pi', '.tron', '.tron-dev']:
            with self.subTest(home=home), self.assertRaises(ValueError):
                output_path(str(Path.home() / home / 'workspace/state/capture-test'))

    def test_snapshot_records_exact_inputs_and_excludes_generated_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'package'
            root.mkdir()
            (root / 'Package.swift').write_text('// fixture\n')
            (root / 'Sources').mkdir()
            source = root / 'Sources/Fixture.swift'
            source.write_text('let fixture = 1\n')
            (root / '.build').mkdir()
            (root / '.build/generated').write_text('not a source input')
            frozen = Path(temp) / 'frozen'
            manifest = freeze_sources(root, frozen)
            self.assertEqual(set(manifest), {'Package.swift', 'Sources/Fixture.swift'})
            self.assertEqual(manifest, source_inventory(frozen))
            source.write_text('let fixture = 2\n')
            self.assertNotEqual(manifest, source_inventory(root))
            self.assertEqual(manifest, source_inventory(frozen))
            (frozen / 'Sources/Fixture.swift').write_text('tampered')
            self.assertNotEqual(manifest, source_inventory(frozen))

    def test_source_symlink_is_rejected_not_silently_omitted(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'Package.swift').write_text('// fixture')
            (root / 'Sources').mkdir()
            (root / 'Sources/escape.swift').symlink_to(root / 'Package.swift')
            with self.assertRaisesRegex(ValueError, 'symlinks'):
                source_inventory(root)

    def test_output_cannot_replace_or_install(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            repository = root / 'repo'
            repository.mkdir()
            self.assertEqual(output_path(str(root / 'artifact'), repository), (root / 'artifact').resolve())
            for value in ['relative', str(root), str(repository / 'artifact'), '/Applications/new-capture-build', '/Library/new-capture-build']:
                with self.assertRaises(ValueError):
                    output_path(value, repository)
            (root / 'alias').symlink_to('/Applications')
            with self.assertRaises(ValueError):
                output_path(str(root / 'alias/new-build'), repository)


if __name__ == '__main__':
    unittest.main()
