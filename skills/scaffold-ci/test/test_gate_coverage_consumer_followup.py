"""Offline contracts for a 2026-11-21 follow-up consumer review of assert_gate_coverage.py.

Same harness as test_gate_coverage_consumer_review.py: a mini repository in a Python-owned temp
directory, the shipped asset run the way CI runs it. GATE_COVERAGE_ASSET points it at another copy.
"""
import os
import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from test_gate_coverage_consumer_review import GATE_IF, gate_yaml, run_gate  # noqa: E402


def feeder_if_yaml(condition):
    """A gate over one feeder `build` carrying the job-level `if: condition`."""
    return (
        f"jobs:\n  build:\n    if: {condition}\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n"
        "  ci-gate:\n    if: always()\n    needs: [build]\n    runs-on: ubuntu-latest\n    steps:\n"
        f"      - if: {GATE_IF}\n        run: exit 1\n"
    )


class GateCoverageConsumerFollowup(unittest.TestCase):
    def assert_gate(self, files, workflow, accepted, needle=""):
        code, output = run_gate(files, workflow)
        self.assertEqual(code == 0, accepted, output)
        if needle:
            self.assertIn(needle, output)

    def test_c1_f4_always_and_not_cancelled_feeder_is_unconditional(self):
        for condition in ("${{ always() && !cancelled() }}", "always() && !cancelled()"):
            with self.subTest(condition=condition):
                self.assert_gate({}, feeder_if_yaml(condition), True)

    def test_c1_f4_always_and_a_runtime_condition_is_still_refused(self):
        self.assert_gate({}, feeder_if_yaml("always() && github.event_name == 'push'"), False, "!cancelled()")

    def test_c1_f7_matrix_include_if_run_pair_is_not_a_gate_step(self):
        workflow = (
            "jobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n"
            "  ci-gate:\n    if: always()\n    needs: [build]\n    runs-on: ubuntu-latest\n"
            "    strategy:\n      matrix:\n        include:\n"
            f"          - if: {GATE_IF}\n            run: exit 1\n"
            "    steps:\n      - run: echo ok\n"
        )
        self.assert_gate({}, workflow, False)

    def test_c1_f7_real_gate_step_after_a_matrix_still_counts(self):
        workflow = (
            "jobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n"
            "  ci-gate:\n    if: always()\n    needs: [build]\n    runs-on: ubuntu-latest\n"
            "    strategy:\n      matrix:\n        include:\n          - os: linux\n"
            f"    steps:\n      - if: {GATE_IF}\n        run: exit 1\n"
        )
        self.assert_gate({}, workflow, True)

    def test_c1_f2_equals_form_discovery_options_are_read(self):
        files = {"ci/check_gate.py": "x = 1"}
        body = "      - run: python3 -m unittest discover --start-directory=ci --pattern=check_*.py\n"
        self.assert_gate(files, gate_yaml(body), False, "ci/check_gate.py")

    def test_c1_m_g2_uppercase_py_suffix_is_a_python_script(self):
        self.assert_gate({"ci_gate.PY": "x = 1"}, gate_yaml("      - run: python3 ci_gate.PY\n"), False, "ci_gate.PY")

    def test_c1_f9_bare_pytest_is_a_runner(self):
        files = {"tests/test_x.py": "def test_x(): pass"}
        for command in ("pytest tests", "py.test tests", "PYTHONPATH=. pytest tests", ".venv/bin/pytest tests", "pytest"):
            with self.subTest(command=command):
                self.assert_gate(files, gate_yaml(f"      - run: {command}\n"), False, "tests/test_x.py")

    def test_c1_f5_folded_node_test_body_is_read_as_one_command(self):
        files = {"tests/a.test.mjs": "// a", "tests/b.test.mjs": "// b"}
        body = "      - run: >-\n          node\n          --test\n          tests/a.test.mjs\n          tests/b.test.mjs\n"
        self.assert_gate(files, gate_yaml(body), False, "tests/b.test.mjs")

    def test_c1_f5_node_test_names_every_positional(self):
        files = {"tests/a.test.mjs": "// a", "tests/b.test.mjs": "// b"}
        self.assert_gate(files, gate_yaml("      - run: node --test tests/a.test.mjs tests/b.test.mjs\n"), False, "tests/b.test.mjs")

    def test_c1_f9_installing_pytest_runs_nothing(self):
        files = {"tests/test_x.py": "def test_x(): pass"}
        # (`echo pytest tests` is required HIGH under the word rule, which reads printed words too.)
        for command in ("pip install pytest pytest-cov", "python3 -m pip install pytest"):
            with self.subTest(command=command):
                self.assert_gate(files, gate_yaml(f"      - run: {command}\n"), True)

    def test_pr503_a_pytest_version_query_runs_no_tests(self):
        files = {"tests/test_x.py": "def test_x(): pass"}
        for command in ("pytest --version", "python3 -m pytest --version", "pytest -V"):
            with self.subTest(command=command):
                self.assert_gate(files, gate_yaml(f"      - run: {command}\n"), True)

    def test_pr503_a_pytest_glob_target_is_expanded(self):
        files = {"checks/test_a.py": "def test_a(): pass", "checks/test_b.py": "def test_b(): pass"}
        code, output = run_gate(files, gate_yaml("      - run: pytest checks/test_*.py\n"),
                                '{"version":1,"high":[".github/workflows/**","checks/**"],"low":[]}')
        self.assertEqual(code, 0, output)
        self.assert_gate(files, gate_yaml("      - run: pytest checks/test_*.py\n"), False, "checks/test_b.py")

    def test_pr503_a_pytest_glob_keeps_its_directory_matches(self):
        # `pytest checks/*` runs checks/unit/ as a directory target, not only the files beside it.
        files = {"checks/test_smoke.py": "def test_a(): pass", "checks/unit/test_gate.py": "def test_b(): pass"}
        code, output = run_gate(files, gate_yaml("      - run: python3 -m pytest checks/*\n"),
                                '{"version":1,"high":[".github/workflows/**","checks/test_smoke.py"],"low":[]}')
        self.assertNotEqual(code, 0, output)
        self.assertIn("checks/unit/test_gate.py", output)

    def test_pr503_quoted_equals_form_discovery_values_are_read(self):
        files = {"ci/check_gate.py": "x = 1"}
        body = "      - run: python3 -m unittest discover --start-directory=\"ci\" --pattern=\"check_*.py\"\n"
        self.assert_gate(files, gate_yaml(body), False, "ci/check_gate.py")


class FeederStepConditions(unittest.TestCase):
    """C1-D-G2, owner decision: a runtime feeder step `if:` is refused unless GATE_STEP_IF_EXEMPT names it."""

    def gate(self, step, step_if_exempt="", workflow=None):
        # patch.dict restores a caller's own GATE_STEP_IF_EXEMPT, or its absence (code review).
        with mock.patch.dict(os.environ, {"GATE_STEP_IF_EXEMPT": step_if_exempt}):
            return run_gate({}, workflow or gate_yaml(step))

    def test_pr503_an_entry_naming_the_gate_jobs_own_step_is_refused(self):
        workflow = (
            "jobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n"
            "  ci-gate:\n    if: always()\n    needs: [build]\n    runs-on: ubuntu-latest\n    steps:\n"
            f"      - id: fail-feeder\n        if: {GATE_IF}\n        run: exit 1\n"
        )
        code, output = self.gate(None, "ci-gate/fail-feeder", workflow)
        self.assertNotEqual(code, 0, output)
        self.assertIn("GATE_STEP_IF_EXEMPT names step(s)", output)

    def test_pr503_matrix_include_data_is_not_a_feeder_step(self):
        workflow = (
            "jobs:\n  build:\n    runs-on: ubuntu-latest\n    strategy:\n      matrix:\n        include:\n"
            "          - if: github.event_name == 'push'\n            run: echo matrix data\n"
            "    steps:\n      - run: echo ok\n"
            "  ci-gate:\n    if: always()\n    needs: [build]\n    runs-on: ubuntu-latest\n    steps:\n"
            f"      - if: {GATE_IF}\n        run: exit 1\n"
        )
        code, output = self.gate(None, "", workflow)
        self.assertEqual(code, 0, output)

    def test_c1_d_g2_runtime_if_without_an_id_is_refused_and_asks_for_one(self):
        code, output = self.gate("      - name: Test\n        if: github.event_name == 'push'\n        run: exit 1\n")
        self.assertNotEqual(code, 0, output)
        self.assertIn("give the step an `id:`", output)
        self.assertIn("GATE_STEP_IF_EXEMPT", output)

    def test_c1_d_g2_runtime_if_with_an_id_is_refused_unless_exempted(self):
        step = "      - id: test\n        if: github.event_name == 'push'\n        run: exit 1\n"
        code, output = self.gate(step)
        self.assertNotEqual(code, 0, output)
        self.assertIn("build/test", output)
        code, output = self.gate(step, "build/test")
        self.assertEqual(code, 0, output)

    def test_c1_d_g2_unconditional_spellings_still_pass(self):
        for condition in ("always()", "!cancelled()", "success()", "${{ always() && !cancelled() }}", "true"):
            with self.subTest(condition=condition):
                code, output = self.gate(f"      - if: {condition}\n        run: exit 1\n")
                self.assertEqual(code, 0, output)

    def test_c1_d_g2_a_stale_exemption_is_refused(self):
        code, output = self.gate("      - id: test\n        run: exit 1\n", "build/test")
        self.assertNotEqual(code, 0, output)
        self.assertIn("GATE_STEP_IF_EXEMPT names step(s)", output)

    def test_c1_d_g2_a_malformed_exemption_is_refused(self):
        code, output = self.gate("      - run: exit 1\n", "test")
        self.assertIn("GATE_STEP_IF_EXEMPT entries are `<job>/<step id>`", output)


if __name__ == "__main__":
    unittest.main()
