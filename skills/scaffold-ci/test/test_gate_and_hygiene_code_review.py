"""Offline contracts for a code review of the scaffold-ci gate assets.

The gate cases run the shipped assert_gate_coverage.py the way CI does (test_gate_coverage_consumer_review's
harness); the Dockerfile cases run assert_workflow_hygiene.py (test_workflow_hygiene_consumer_review's).
GATE_COVERAGE_ASSET and HYGIENE_ASSET point the suite at other copies.
"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from test_gate_coverage_consumer_review import GATE_IF, gate_yaml, run_gate  # noqa: E402
from test_workflow_hygiene_consumer_review import DIGEST, run_hygiene  # noqa: E402


def feeder_if_yaml(condition):
    return (
        f"jobs:\n  build:\n    if: {condition}\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n"
        "  ci-gate:\n    if: always()\n    needs: [build]\n    runs-on: ubuntu-latest\n    steps:\n"
        f"      - if: {GATE_IF}\n        run: exit 1\n"
    )


class GateCoverage(unittest.TestCase):
    def assert_gate(self, files, workflow, accepted, needle=""):
        code, output = run_gate(files, workflow)
        self.assertEqual(code == 0, accepted, output)
        if needle:
            self.assertIn(needle, output)

    def test_a_whitespace_string_compared_with_zero_is_false(self):
        # The runner trims ' ' to the number 0, so (' ' != 0) is false: the job never runs.
        self.assert_gate({}, feeder_if_yaml("(' ' != 0) && !cancelled()"), False, "job-level 'if:'")
        self.assert_gate({}, gate_yaml("      - if: ${{ ' ' != 0 }}\n        run: exit 1\n"), False, "always-skipped")
        self.assert_gate({}, feeder_if_yaml("!cancelled()"), True)

    def test_a_folded_uses_in_matrix_data_is_not_an_action_reference(self):
        workflow = (
            "jobs:\n  build:\n    runs-on: ubuntu-latest\n    strategy:\n      matrix:\n        include:\n"
            "          - uses: >-\n              some text\n"
            "    steps:\n      - run: echo ok\n"
            "  ci-gate:\n    if: always()\n    needs: [build]\n    runs-on: ubuntu-latest\n    steps:\n"
            f"      - if: {GATE_IF}\n        run: exit 1\n"
        )
        self.assert_gate({}, workflow, True)

    def test_a_folded_step_uses_is_still_refused(self):
        self.assert_gate({}, gate_yaml("      - uses: >-\n          ./.github/actions/quality\n"), False, "`uses` value must be written")

    def test_a_quoted_script_path_with_a_space_is_read_whole(self):
        files = {"scripts/quality checks.py": "x = 1"}
        self.assert_gate(files, gate_yaml("      - run: python3 \"scripts/quality checks.py\"\n"), False, "scripts/quality checks.py")

    def test_a_pytest_option_value_is_not_a_collection_target(self):
        files = {"tests/test_smoke.py": "def test_x(): pass"}
        for command in ("pytest -k smoke", "pytest -k \"smoke and not slow\"", "python3 -m pytest -m slow -q"):
            with self.subTest(command=command):
                self.assert_gate(files, gate_yaml(f"      - run: {command}\n"), False, "tests/test_smoke.py")

    def test_a_target_less_pytest_is_read_per_shell_command(self):
        # Code review: a separator glued to pytest, or a later command's words,
        # must not hide the implicit root target.
        files = {"tests/test_smoke.py": "def test_x(): pass"}
        for command in ("pytest; echo done", "pytest|tee out.txt", "(pytest)", "pytest&&make", "pytest -k smoke && echo done",
                        "pytest 2>&1 | tee out.txt", "pytest > out.txt", "pytest --maxfail 1", "pytest --capture no", "pytest --tb short -x"):
            with self.subTest(command=command):
                self.assert_gate(files, gate_yaml(f"      - run: {command}\n"), False, "tests/test_smoke.py")

    def test_a_merged_redirection_is_not_a_pytest_target(self):
        # Code review: shlex merges `&>`, `&>>`, `>|` into one token.
        files = {"tests/test_smoke.py": "def test_x(): pass"}
        for command in ("pytest &> out.txt", "pytest &>> out.txt", "pytest >| out.txt", "pytest >& out.txt"):
            with self.subTest(command=command):
                self.assert_gate(files, gate_yaml(f"      - run: {command}\n"), False, "tests/test_smoke.py")

    def test_pytest_through_a_command_wrapper_collects_from_the_root(self):
        # Code review: `command pytest` runs pytest; `command -v pytest` does not.
        files = {"tests/test_smoke.py": "def test_x(): pass"}
        for command in ("command pytest -q", "exec pytest", "env CI=1 pytest", "time pytest"):
            with self.subTest(command=command):
                self.assert_gate(files, gate_yaml(f"      - run: {command}\n"), False, "tests/test_smoke.py")
        for command in ("command -v pytest", "echo pytest"):
            with self.subTest(command=command):
                self.assert_gate(files, gate_yaml(f"      - run: {command}\n"), True)

    def test_a_pytest_exclusion_value_is_not_a_discovery_pattern(self):
        # Code review: `--ignore-glob '*slow*'` excludes; it must not narrow to `*slow*`.
        files = {"tests/test_smoke.py": "def test_x(): pass"}
        for command in ("pytest --ignore-glob '*slow*'", "pytest --ignore-glob=*slow*", "pytest -k '*slow*'"):
            with self.subTest(command=command):
                self.assert_gate(files, gate_yaml(f"      - run: {command}\n"), False, "tests/test_smoke.py")

    def test_an_explicit_pytest_target_still_narrows_collection(self):
        files = {"tests/unit/test_a.py": "def test_a(): pass", "tests/other/test_b.py": "def test_b(): pass"}
        code, output = run_gate(files, gate_yaml("      - run: pytest --maxfail 1 tests/unit && echo done\n"),
                                '{"version":1,"high":[".github/workflows/**","tests/unit/**"],"low":[]}')
        self.assertEqual(code, 0, output)

    def test_npm_test_from_a_subdirectory_reads_the_owning_package(self):
        files = {"web/package.json": '{"scripts":{"test":"node scripts/check.mjs"}}', "web/scripts/check.mjs": "// probe", "web/src/app.js": "x"}
        body = "      - run: npm test\n        working-directory: web/src\n"
        self.assert_gate(files, gate_yaml(body), False, "web/scripts/check.mjs")

    def test_npm_ci_runs_the_prepublish_hook(self):
        files = {"package.json": '{"scripts":{"prepublish":"node scripts/check.mjs"}}', "scripts/check.mjs": "// probe"}
        self.assert_gate(files, gate_yaml("      - run: npm ci\n"), False, "scripts/check.mjs")
        self.assert_gate(files, gate_yaml("      - run: npm ci --ignore-scripts\n"), True)


class DockerfileBaseImages(unittest.TestCase):
    def assert_unpinned_alpine(self, dockerfile):
        code, output = run_hygiene(dockerfile)
        self.assertNotEqual(code, 0, output)
        self.assertIn("alpine", output)

    def test_a_partly_quoted_heredoc_delimiter_ends_at_its_unquoted_word(self):
        self.assert_unpinned_alpine(f"FROM scratch@sha256:{DIGEST}\nCOPY <<E\"OF\" /payload\nhello\nEOF\nFROM alpine:latest\n")

    def test_an_indented_escape_directive_is_read(self):
        self.assert_unpinned_alpine("  # escape=`\nARG UNUSED=x\\\nFROM alpine:latest\n")

    def test_an_escaped_quote_in_a_quoted_delimiter_is_a_quote(self):
        # BuildKit reads <<E"O\"F" as the delimiter EO"F (code review).
        self.assert_unpinned_alpine(f"FROM scratch@sha256:{DIGEST}\nCOPY <<E\"O\\\"F\" /payload\nhello\nEO\"F\nFROM alpine:latest\n")

    def test_a_backslash_before_a_backtick_in_a_quoted_delimiter_is_kept(self):
        # Docker 29.9.3 closed <<"E\`OF" at E\`OF, backslash kept (code review).
        self.assert_unpinned_alpine(f"FROM scratch@sha256:{DIGEST}\nCOPY <<\"E\\`OF\" /payload\nhello\nE\\`OF\nFROM alpine:latest\n")

    def test_a_directive_value_may_hold_whitespace(self):
        # Docker 29.9.3 still applied `# escape=` after `# check=skip=all # explanation` (code review).
        self.assert_unpinned_alpine("# check=skip=all # explanation\n# escape=`\nFROM scratch\nARG UNUSED=x\\\nFROM alpine:latest\n")

    def test_an_empty_directive_ends_the_directives(self):
        # `# syntax=` with no value is a comment, so the `# escape=` after it is ignored (code review).
        self.assert_unpinned_alpine("  # syntax=\n# escape=`\nARG UNUSED=x`\nFROM alpine:latest\n")


if __name__ == "__main__":
    unittest.main()
