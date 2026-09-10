import tempfile
from pathlib import Path
import unittest
from build_observer import freeze_sources, output_path, source_inventory


class ObserverBuildInputTests(unittest.TestCase):
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
            for value in ['relative', str(root), str(repository / 'artifact'), '/Applications/new-observer-build', '/Library/new-observer-build']:
                with self.assertRaises(ValueError):
                    output_path(value, repository)
            (root / 'alias').symlink_to('/Applications')
            with self.assertRaises(ValueError):
                output_path(str(root / 'alias/new-build'), repository)


if __name__ == '__main__':
    unittest.main()
