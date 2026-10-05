import importlib.util
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('recovery', pathlib.Path(__file__).with_name('recover.py'))
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)

class RecoveryTests(unittest.TestCase):
    def test_merge_preserves_variants_and_quarantines_malformed_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            a, b = pathlib.Path(directory) / 'a.jsonl', pathlib.Path(directory) / 'b.jsonl'
            original = b'{"recordedAt":"2026-10-05T12:00:00Z","percentage":50}'
            variant = b'{"recordedAt":"2026-10-05T12:00:00Z","percentage":49}'
            a.write_bytes(original + b'\ninvalid\n')
            b.write_bytes(original + b'\n' + variant + b'\n')
            lines, bad, conflicts = recovery.records([a, b])
            self.assertEqual(set(lines), {original, variant})
            self.assertEqual(conflicts, 1)
            self.assertEqual(len(bad), 1)
            self.assertEqual(bad[0]['line'], 2)
            a.write_bytes(b'\n'.join(lines) + b'\n')
            self.assertEqual(recovery.records([a, b])[0], lines)

if __name__ == '__main__': unittest.main()
