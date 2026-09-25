import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent / "scripts" / "compare-asset-semantics.py"
SPEC = importlib.util.spec_from_file_location("compare_asset_semantics", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CompareAssetSemanticsTests(unittest.TestCase):
    def definitions(self, source):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "asset.py"
            path.write_text(source, encoding="utf-8")
            return MODULE.definitions(path)

    def test_simple_functions_can_be_reordered(self):
        first = self.definitions("def first():\n    return 1\ndef second():\n    return 2\n")
        second = self.definitions("def second():\n    return 2\ndef first():\n    return 1\n")
        self.assertEqual(first, second)

    def test_definition_time_defaults_keep_order(self):
        first = self.definitions("def value():\n    return 1\ndef choose(x=value()):\n    return x\n")
        second = self.definitions("def choose(x=value()):\n    return x\ndef value():\n    return 1\n")
        self.assertNotEqual(first, second)

    def test_duplicate_top_level_names_fail(self):
        with self.assertRaises(SystemExit) as error:
            self.definitions("def check():\n    return 1\ndef check():\n    return 2\n")
        self.assertEqual(error.exception.code, 1)


if __name__ == "__main__":
    unittest.main()
