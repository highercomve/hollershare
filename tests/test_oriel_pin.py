"""CI and CLI setup must select the dependency declared by the app."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from oriel_pin import read_pin


class OrielPinTests(unittest.TestCase):
    def parse(self, url):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "build.zig.zon"
            path.write_text('.{ .dependencies = .{ .other = .{ .url = "ignore" }, '
                            '.oriel = .{ .hash = "ignored", .url = "' + url + '" } } }')
            return read_pin(path)

    def test_reads_declared_tag_and_commit(self):
        revision = "a" * 40
        self.assertEqual(self.parse("git+https://github.com/highercomve/Oriel?ref=v9.8.7#" + revision),
                         ("v9.8.7", revision))

    def test_rejects_unpinned_or_wrong_dependency(self):
        for url in [
            "git+https://github.com/highercomve/Oriel?ref=main#" + "a" * 40,
            "git+https://github.com/highercomve/Oriel?ref=v1.2.3#abc",
            "git+https://github.com/other/Oriel?ref=v1.2.3#" + "a" * 40,
            "git+https://github.com/highercomve/Oriel#" + "a" * 40,
        ]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.parse(url)

    def test_missing_dependency_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "build.zig.zon"
            path.write_text('.{ .dependencies = .{} }')
            with self.assertRaises(ValueError):
                read_pin(path)


if __name__ == "__main__":
    unittest.main()
