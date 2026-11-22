"""Offline contracts for the 2026-11-21 consumer review of assert_gate_coverage.py (RV-13, 14, 15, 40, 41).

Each case builds a mini repository in a Python-owned temp directory and runs the shipped asset
the way CI does (`python3 -S assert_gate_coverage.py <workflow>`), as verify-gate-coverage.ps1's
New-GateFilesRepo does. Python-level so it runs on any host without a PowerShell harness.
"""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

# GATE_COVERAGE_ASSET points the suite at another copy, so a red run on the pre-fix asset is one command.
ASSET = pathlib.Path(os.environ.get("GATE_COVERAGE_ASSET") or pathlib.Path(__file__).resolve().parents[1] / "assets" / "assert_gate_coverage.py")
GATE_IF = "always() && (contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled'))"
POLICY_WORKFLOWS = '{"version":1,"high":[".github/workflows/**"],"low":[]}'


def gate_yaml(build_body):
    """A ci-gate job over one feeder job `build` whose steps are `build_body` (already indented)."""
    return (
        "jobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n" + build_body
        + "  ci-gate:\n    if: always()\n    needs: [build]\n    runs-on: ubuntu-latest\n    steps:\n"
        + f"      - if: {GATE_IF}\n        run: exit 1\n"
    )


def run_gate(files, workflow, policy=POLICY_WORKFLOWS):
    """(exit code, output) of the asset over a mini repo holding `files` and `workflow` as ci.yml."""
    with tempfile.TemporaryDirectory(prefix="gate-consumer-review-") as folder:
        repo = pathlib.Path(folder)
        (repo / ".claude").mkdir()
        (repo / ".claude" / "review-policy.json").write_text(policy, encoding="utf-8")
        for rel, content in {**files, ".github/workflows/ci.yml": workflow}.items():
            path = repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        env = {**os.environ, "GATE_EXEMPT": "", "GATE_CONDITIONAL_EXEMPT": "", "GATE_FILE_EXEMPT": "", "GATE_STEP_EXEMPT": ""}
        done = subprocess.run([sys.executable, "-S", str(ASSET), str(repo / ".github" / "workflows" / "ci.yml")],
                              capture_output=True, text=True, env=env, timeout=120)
        return done.returncode, done.stdout + done.stderr


class GateCoverageConsumerReview(unittest.TestCase):
    def assert_gate(self, files, workflow, accepted, needle=""):
        code, output = run_gate(files, workflow)
        self.assertEqual(code == 0, accepted, output)
        if needle:
            self.assertIn(needle, output)

    def test_rv13_cd_inside_package_script_is_refused(self):
        cases = {
            "script": {"package.json": '{"scripts":{"gate":"cd frontend && node gate.mjs"}}', "frontend/gate.mjs": "// probe"},
            "nested npm": {"package.json": '{"scripts":{"gate":"cd frontend && npm run inner"}}',
                           "frontend/package.json": '{"scripts":{"inner":"node gate.mjs"}}', "frontend/gate.mjs": "// probe"},
        }
        for label, files in cases.items():
            with self.subTest(label):
                self.assert_gate(files, gate_yaml("      - run: npm run gate\n"), False, "directory change")

    def test_rv13_cd_inside_package_script_without_a_script_still_passes(self):
        files = {"package.json": '{"scripts":{"gate":"cd frontend && tsc --noEmit"}}'}
        self.assert_gate(files, gate_yaml("      - run: npm run gate\n"), True)

    def test_rv14_ancestor_conftest_is_tiered(self):
        files = {"conftest.py": "x = 1", "tests/unit/test_gate.py": "def test_x(): pass"}
        for target in ("tests/unit/test_gate.py", "tests/unit"):
            with self.subTest(target=target):
                self.assert_gate(files, gate_yaml(f"      - run: python3 -m pytest {target}\n"), False, "conftest.py")

    def test_rv15_valueless_bash_flag_does_not_swallow_the_script(self):
        files = {"ci/gate.sh": "exit 0"}
        # `bash -r` is a restricted shell and takes no value; node's `-r` (--require) does.
        self.assert_gate(files, gate_yaml("      - run: bash -r ci/gate.sh\n"), False, "not tiered HIGH")

    def test_rv15_node_require_still_takes_a_value(self):
        files = {"ci/gate.mjs": "// probe", "ci/hook.cjs": "// hook"}
        self.assert_gate(files, gate_yaml("      - run: node -r ./ci/hook.cjs ci/gate.mjs\n"), False, "ci/gate.mjs")

    def test_rv40_install_hooks_are_followed(self):
        files = {"package.json": '{"scripts":{"postinstall":"node scripts/check.mjs","prepare":"node scripts/prep.mjs"}}',
                 "scripts/check.mjs": "// probe", "scripts/prep.mjs": "// probe"}
        for command in ("npm ci", "npm install", "npm i", "npm cit", "npm install-test"):
            with self.subTest(command=command):
                self.assert_gate(files, gate_yaml(f"      - run: {command}\n"), False, "not tiered HIGH")

    def test_rv40_ignore_scripts_runs_no_hook(self):
        files = {"package.json": '{"scripts":{"postinstall":"node scripts/check.mjs"}}', "scripts/check.mjs": "// probe"}
        self.assert_gate(files, gate_yaml("      - run: npm ci --ignore-scripts\n"), True)

    def test_rv40_cd_then_install_is_refused_only_when_a_package_defines_a_hook(self):
        hooked = {"frontend/package.json": '{"scripts":{"postinstall":"node scripts/check.mjs"}}', "frontend/scripts/check.mjs": "// probe"}
        self.assert_gate(hooked, gate_yaml("      - run: cd frontend && npm ci\n"), False, "directory change")
        plain = {"frontend/package.json": '{"scripts":{"gate":"node scripts/check.mjs"}}', "frontend/scripts/check.mjs": "// probe"}
        self.assert_gate(plain, gate_yaml("      - run: cd frontend && npm ci\n"), True)

    def test_rv40_install_without_any_hook_keeps_the_s7_contracts(self):
        # verify-gate-coverage.ps1's S7 cases: an install in another package must not be refused
        # when no package defines an install hook, and `npm sit` still follows `test`.
        files = {"package.json": '{"scripts":{"test":"node scripts/gate.mjs"}}', "scripts/gate.mjs": "process.exit(1)"}
        for command in ("npm ci --prefix frontend", "npm install -w app", "npm --workspace=app install"):
            with self.subTest(command=command):
                code, output = run_gate(files, gate_yaml(f"      - run: {command}\n"), '{"version":1,"high":[".github/workflows/ci.yml","scripts/**"],"low":[]}')
                self.assertEqual(code, 0, output)
        self.assert_gate(files, gate_yaml("      - run: npm sit\n"), False, "scripts/gate.mjs")

    def test_rv41_uses_value_off_the_key_line_is_refused(self):
        callee = "on: workflow_call\njobs:\n  inner:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n"
        for spelling in ("\n      ./.github/workflows/reuse.yml", " >-\n      ./.github/workflows/reuse.yml"):
            with self.subTest(spelling=spelling):
                workflow = (
                    f"jobs:\n  build:\n    uses:{spelling}\n  ci-gate:\n    if: always()\n    needs: [build]\n"
                    f"    runs-on: ubuntu-latest\n    steps:\n      - if: {GATE_IF}\n        run: exit 1\n"
                )
                self.assert_gate({".github/workflows/reuse.yml": callee}, workflow, False, "`uses` value must be written on the key's own line")

    def test_rv41_step_uses_value_off_the_key_line_is_refused(self):
        self.assert_gate({}, gate_yaml("      - uses:\n          ./.github/actions/quality\n"), False, "`uses` value must be written")

    def test_rv41_uses_alias_is_refused_and_named(self):
        # An alias resolves to the node at its anchor, so a line reader sees `*co`, not the action.
        self.assert_gate({}, gate_yaml("      - uses: &co actions/checkout@v7\n      - uses: *co\n"), False, "alias")

    def test_rv41_an_input_or_variable_named_uses_is_data(self):
        for owner in ("with", "env"):
            with self.subTest(owner=owner):
                step = f"      - uses: actions/checkout@v7\n        {owner}:\n          uses: |\n            a\n            b\n"
                self.assert_gate({}, gate_yaml(step), True)

    def test_rv41_a_job_named_like_a_data_key_is_still_checked(self):
        # `with` and `env` are legal job ids; the job's own `uses:` is an action reference, not data.
        callee = "on: workflow_call\njobs:\n  inner:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n"
        for job in ("with", "env"):
            with self.subTest(job=job):
                workflow = (
                    f"jobs:\n  {job}:\n    uses:\n      ./.github/workflows/reuse.yml\n  ci-gate:\n    if: always()\n    needs: [{job}]\n"
                    f"    runs-on: ubuntu-latest\n    steps:\n      - if: {GATE_IF}\n        run: exit 1\n"
                )
                self.assert_gate({".github/workflows/reuse.yml": callee}, workflow, False, "`uses` value must be written")

    def test_rv40_root_install_follows_workspace_install_hooks(self):
        # npm 11.14 runs a workspace's prepare and postinstall on a root `npm ci` / `npm install`.
        files = {
            "package.json": '{"private":true,"workspaces":["pkg"]}',
            "pkg/package.json": '{"name":"pkg","scripts":{"prepare":"node gate.mjs"}}',
            "pkg/gate.mjs": "// probe",
        }
        for command in ("npm ci", "npm install"):
            with self.subTest(command=command):
                self.assert_gate(files, gate_yaml(f"      - run: {command}\n"), False, "pkg/gate.mjs")

    def test_rv40_workspace_scoped_install_still_follows_the_root_install_hooks(self):
        # npm 11.14 runs the root package's postinstall and prepare on `npm ci --workspace=pkg` too.
        files = {
            "package.json": '{"private":true,"workspaces":["pkg"],"scripts":{"postinstall":"node gate.mjs"}}',
            "pkg/package.json": '{"name":"pkg"}',
            "gate.mjs": "// probe",
        }
        for command in ("npm ci --workspace=pkg", "npm install -w pkg"):
            with self.subTest(command=command):
                self.assert_gate(files, gate_yaml(f"      - run: {command}\n"), False, "gate.mjs")

    def test_496_1_nested_workspace_install_follows_the_root_install_hooks(self):
        # npm 11.14.1 runs the root postinstall when `npm run gate` runs `npm ci --workspace=pkg`.
        files = {
            "package.json": '{"private":true,"workspaces":["pkg"],"scripts":{"gate":"npm ci --workspace=pkg","postinstall":"node gate.mjs"}}',
            "pkg/package.json": '{"name":"pkg"}',
            "gate.mjs": "// probe",
        }
        self.assert_gate(files, gate_yaml("      - run: npm run gate\n"), False, "gate.mjs")

    def test_496_1_nested_run_prepare_stays_in_its_own_package(self):
        files = {
            "package.json": '{"private":true,"workspaces":["pkg"],"scripts":{"gate":"npm run prepare","prepare":"echo ready"}}',
            "pkg/package.json": '{"name":"pkg","scripts":{"prepare":"cd src && node gate.mjs"}}',
            "pkg/src/gate.mjs": "// probe",
        }
        self.assert_gate(files, gate_yaml("      - run: npm run gate\n"), True)

    def test_496_2_extensionless_glob_after_cd_is_refused(self):
        # bash expands `checks/*` from `ci`, so it runs ci/checks/gate.mjs, which nothing resolves from the root.
        files = {"ci/checks/gate.mjs": "// probe"}
        self.assert_gate(files, gate_yaml("      - run: cd ci && node --test checks/*\n"), False, "directory change")

    def test_496_2_extensionless_glob_from_a_working_directory_still_resolves(self):
        files = {"ci/checks/gate.mjs": "// probe"}
        step = "      - working-directory: ci\n        run: node --test checks/*\n"
        self.assert_gate(files, gate_yaml(step), False, "ci/checks/gate.mjs")
        code, output = run_gate(files, gate_yaml(step), '{"version":1,"high":[".github/workflows/**","ci/**"],"low":[]}')
        self.assertEqual(code, 0, output)

    def test_496_2_extensionless_glob_matching_nothing_without_cd_still_passes(self):
        self.assert_gate({}, gate_yaml("      - run: node --test checks/*\n"), True)

    def test_rv40_running_a_hook_by_name_stays_in_its_own_package(self):
        # `npm run prepare` runs the root script only; it is not an install, so no workspace hook runs.
        files = {
            "package.json": '{"private":true,"workspaces":["pkg"],"scripts":{"prepare":"echo ready"}}',
            "pkg/package.json": '{"name":"pkg","scripts":{"prepare":"cd src && node gate.mjs"}}',
            "pkg/src/gate.mjs": "// probe",
        }
        self.assert_gate(files, gate_yaml("      - run: npm run prepare\n"), True)

    def test_rv13_cd_with_only_a_printed_script_path_still_passes(self):
        files = {"package.json": '{"scripts":{"gate":"cd frontend && echo scripts/report.py"}}', "scripts/report.py": "x = 1"}
        code, output = run_gate(files, gate_yaml("      - run: npm run gate\n"), '{"version":1,"high":[".github/workflows/ci.yml","scripts/**"],"low":[]}')
        self.assertEqual(code, 0, output)

    def test_rv41_uses_on_its_own_line_still_passes(self):
        callee = "on: workflow_call\njobs:\n  inner:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n"
        workflow = (
            "jobs:\n  build:\n    uses: './.github/workflows/reuse.yml'\n  ci-gate:\n    if: always()\n    needs: [build]\n"
            f"    runs-on: ubuntu-latest\n    steps:\n      - if: {GATE_IF}\n        run: exit 1\n"
        )
        self.assert_gate({".github/workflows/reuse.yml": callee}, workflow, True)


if __name__ == "__main__":
    unittest.main()
