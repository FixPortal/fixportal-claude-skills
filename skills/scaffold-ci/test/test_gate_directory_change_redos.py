"""DIRECTORY_CHANGE must not backtrack exponentially (CodeQL py/redos).

The assignment-prefix value let its unquoted branch consume quote characters too, so
`&_=""\t_=""\t...!` gave the engine about 4x more work per two extra assignments. A gated run
line could hang the gate job. GATE_COVERAGE_ASSET points the suite at another copy.
"""
import importlib.util
import os
import pathlib
import subprocess
import sys
import unittest

ASSET = pathlib.Path(os.environ.get("GATE_COVERAGE_ASSET") or pathlib.Path(__file__).resolve().parents[1] / "assets" / "assert_gate_coverage.py")
SPEC = importlib.util.spec_from_file_location("assert_gate_coverage_redos_under_test", ASSET)
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)

# Run in a child with a hard timeout, so a regression fails instead of hanging the suite.
PROBE = (
    "import importlib.util, sys, time\n"
    "spec = importlib.util.spec_from_file_location('g', sys.argv[1]); g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)\n"
    "start = time.perf_counter()\n"
    "for unit in ('\"\"\\t_=', '\\\\\\\\\\t_=', '\"\\\\\\\\\"\\t_='):\n"
    "    g.DIRECTORY_CHANGE.search('&_=' + unit * 40 + '!')\n"
    "print(time.perf_counter() - start)\n"
)


class DirectoryChangeRedos(unittest.TestCase):
    def test_a_long_run_of_quoted_assignments_finishes(self):
        try:
            done = subprocess.run([sys.executable, "-c", PROBE, str(ASSET)], capture_output=True, text=True, timeout=10)
        except subprocess.TimeoutExpired:
            self.fail("DIRECTORY_CHANGE.search did not finish within 10s on 40 quoted assignments")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertLess(float(done.stdout), 2.0, done.stdout)

    def test_directory_changes_are_still_found(self):
        cases = {
            'X=a"b" cd dir': True,
            'X="a b" cd dir': True,
            "X='a b' cd dir": True,
            "X=1 Y=2 cd dir": True,
            "A= cd dir": True,
            "echo hi; cd dir": True,
            "FOO=bar": False,
            "make cdrom": False,
            # A backslash-escaped quote is literal in bash (code review).
            'X=\\" cd sub': True,
            'X="a\\"b" cd sub': True,
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(GATE.DIRECTORY_CHANGE.search(text) is not None, expected)


if __name__ == "__main__":
    unittest.main()
