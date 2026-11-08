"""Exercise the parse-only lint on disposable Git fixtures; never run fixture source."""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import uuid


SKILLS = Path(__file__).resolve().parents[2]
ENTRY = SKILLS / "scaffold-ci/assets/Test-PowerShellTestSafety.ps1"
HELPER = SKILLS / "scaffold-ci/assets/Find-PesterSuites.ps1"
MARKER = ".powershell-safety-test-owner"


def owned_tempdir(test, prefix):
    """Create a temp directory and register a cleanup that deletes it only on positive ownership evidence."""
    path = Path(tempfile.mkdtemp(prefix=prefix)).resolve()
    token = uuid.uuid4().hex
    (path / MARKER).write_text(token, encoding="utf-8")

    def remove():
        marker = path / MARKER
        owned = (path.parent == Path(tempfile.gettempdir()).resolve() and path.name.startswith(prefix)
                 and not path.is_symlink() and marker.is_file() and marker.read_text(encoding="utf-8") == token)
        if not owned:
            raise AssertionError(f"refusing to delete a directory this test does not own: {path}")
        print(f"removing owned fixture {path}", file=sys.stderr)
        # Git writes its object files read-only; Windows refuses to unlink those until the bit is cleared.
        def clear_readonly(func, target, _exc):
            os.chmod(target, stat.S_IWRITE)
            func(target)

        handler = {"onexc": clear_readonly} if sys.version_info >= (3, 12) else {"onerror": clear_readonly}
        shutil.rmtree(path, **handler)

    test.addCleanup(remove)
    return path


class SafetyLintTests(unittest.TestCase):
    def setUp(self):
        self.root = owned_tempdir(self, "powershell-safety-")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.tools = self.root / ".github/scripts"
        self.tools.mkdir(parents=True)
        shutil.copyfile(ENTRY, self.tools / ENTRY.name)
        shutil.copyfile(HELPER, self.tools / HELPER.name)

    def source(self, name, text, tracked=True):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        if tracked:
            subprocess.run(["git", "-C", str(self.root), "add", "--", name], check=True)
        return path

    def lint(self, repository=None):
        return subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(self.tools / ENTRY.name),
             "-Repository", str(repository or self.root)],
            capture_output=True, text=True, timeout=20,
        )

    def test_safe_text_is_parsed_never_executed(self):
        self.source("tests/safe.Tests.ps1", "throw 'MUST_NOT_EXECUTE'\n# $HOME = 'bad'\n$x = '$script:Home = 1'\n")
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 tracked", result.stdout)

    def test_scoped_automatic_assignment(self):
        self.source("tests/incident.Tests.ps1", "$script:Home = 'fake'\nRemove-Item $script:Home -Recurse -Force\n")
        result = self.lint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("automatic-variable-assignment", result.stdout)

    def test_variable_commands_and_case(self):
        self.source("verify-case.ps1", "Set-Variable -Name hOmE -Value fake\n")
        result = self.lint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("automatic-variable-assignment", result.stdout)

    def test_other_variable_bindings(self):
        for source in ("foreach ($HOME in @('x')) { }", "$HOME++", "param($HOME)"):
            with self.subTest(source=source):
                self.source("verify-binding.ps1", source)
                result = self.lint()
                self.assertNotEqual(result.returncode, 0, source)
                self.assertIn("automatic-variable-assignment", result.stdout)

    def test_variable_command_bindings(self):
        for source in ("Set-Variable -Scope Script Home 'x'", "Set-Variable -Name Home,widget -Value 'x'", "nv -Scope:Script -Force Home 'x'"):
            with self.subTest(source=source):
                self.source("verify-command.ps1", source)
                result = self.lint()
                self.assertNotEqual(result.returncode, 0, source)
                self.assertIn("automatic-variable-assignment", result.stdout)

    def test_additional_automatic_write_forms(self):
        for source in ("$PSCulture = 'x'", "Set-Item -Path Variable:HOME -Value 'x' -Force"):
            with self.subTest(source=source):
                self.source("verify-provider.ps1", source)
                result = self.lint()
                self.assertNotEqual(result.returncode, 0, source)
                self.assertIn("automatic-variable-assignment", result.stdout)

    def test_variable_provider_values_are_not_targets(self):
        self.source("verify-values.ps1", "Set-Item -Path file.txt -Value Variable:HOME\nSet-Item -Value Variable:HOME -Path file.txt\nSet-Item Variable:widget x\n")
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ordinary_variable_bindings_are_allowed(self):
        self.source("verify-bindings.ps1", "param($fixtureRoot)\nforeach ($fixtureName in @('x')) { }\n$fixtureCount++\nSet-Variable -Scope Script fixtureRoot 'x'\nNew-Variable -Name fixtureRoot,widget -Value 'x'\n")
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_parse_errors_fail(self):
        self.source("tests/broken.Test.ps1", "function Broken {\n")
        result = self.lint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("parse-error", result.stdout)

    def test_empty_scan_fails(self):
        result = self.lint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no tracked", result.stdout + result.stderr)

    def test_non_repository_fails(self):
        result = self.lint(owned_tempdir(self, "not-a-repository-"))
        self.assertNotEqual(result.returncode, 0)

    def test_untracked_worktree_not_read(self):
        self.source("verify-safe.ps1", "$fixtureRoot = 'safe'\n")
        self.source(".claude/worktrees/other/verify-bad.ps1", "$HOME = 'bad'", tracked=False)
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 tracked", result.stdout)

    def test_space_and_unicode_path(self):
        self.source("tests/space é.Tests.ps1", "$fixtureRoot = 'safe'\n")
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_uppercase_extension_is_checked(self):
        self.source("tests/case.TESTS.PS1", "$script:Home = 'fake'\n")
        result = self.lint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("automatic-variable-assignment", result.stdout)

    def test_missing_tracked_source_fails(self):
        path = self.source("verify-missing.ps1", "$fixtureRoot = 'safe'\n")
        path.unlink()
        self.assertNotEqual(self.lint().returncode, 0)

    @unittest.skipIf(os.name == "nt", "symlink creation requires separate Windows privilege")
    def test_tracked_symlink_not_followed(self):
        outside = owned_tempdir(self, "outside-source-") / "source.ps1"
        outside.write_text("$fixtureRoot = 'safe'\n", encoding="utf-8")
        (self.root / "verify-link.ps1").symlink_to(outside)
        subprocess.run(["git", "-C", str(self.root), "add", "verify-link.ps1"], check=True)
        result = self.lint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("linked", result.stdout + result.stderr)

    @unittest.skipIf(os.name == "nt", "symlink creation requires separate Windows privilege")
    def test_index_link_materialized_as_regular_file(self):
        path = self.root / "verify-index-link.ps1"
        path.symlink_to("elsewhere.ps1")
        subprocess.run(["git", "-C", str(self.root), "add", "verify-index-link.ps1"], check=True)
        path.unlink()
        path.write_text("elsewhere.ps1", encoding="utf-8")
        result = self.lint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("linked", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
