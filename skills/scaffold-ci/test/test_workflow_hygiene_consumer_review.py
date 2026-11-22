"""Offline contracts for the Dockerfile base-image reading in assert_workflow_hygiene.py
(items 3 and 4 of a consumer re-sync review).

Each case builds a mini repository holding a local docker action and runs the shipped asset from
inside it, as verify-workflow-hygiene.ps1's Invoke-Hygiene does (the asset reads .github/workflows
relative to the current directory). Python-level so it runs on any host without a PowerShell harness.
"""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

# HYGIENE_ASSET points the suite at another copy, so a red run on the pre-fix asset is one command.
ASSET = pathlib.Path(os.environ.get("HYGIENE_ASSET") or pathlib.Path(__file__).resolve().parents[1] / "assets" / "assert_workflow_hygiene.py")
DIGEST = "a" * 64
WORKFLOW = (
    "on:\n  pull_request:\npermissions:\n  contents: read\njobs:\n  build:\n    runs-on: ubuntu-latest\n"
    "    steps:\n      - uses: ./.github/actions/d\n"
)
ACTION = "name: d\nruns:\n  using: docker\n  image: Dockerfile\n"


def run_hygiene(dockerfile):
    """(exit code, output) of the asset over a repo whose local docker action builds `dockerfile`."""
    with tempfile.TemporaryDirectory(prefix="hygiene-consumer-review-") as folder:
        repo = pathlib.Path(folder)
        files = {".github/workflows/ci.yml": WORKFLOW, ".github/actions/d/action.yml": ACTION, ".github/actions/d/Dockerfile": dockerfile}
        for rel, content in files.items():
            path = repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8", newline="\n")
        env = {**os.environ, "PRIVILEGED_TRIGGER_NO_CHECKOUT": "", "TRUSTED_THIRD_PARTY_ACTIONS": ""}
        done = subprocess.run([sys.executable, str(ASSET)], cwd=repo, capture_output=True, text=True, env=env, timeout=120)
        return done.returncode, done.stdout + done.stderr


class DockerfileBaseImages(unittest.TestCase):
    def assert_hygiene(self, dockerfile, accepted, needle=""):
        code, output = run_hygiene(dockerfile)
        self.assertEqual(code == 0, accepted, output)
        if needle:
            self.assertIn(needle, output)

    def test_496_3_pinned_image_after_a_line_continuation_passes(self):
        # Docker 29.9.3 builds `FROM \` + `  base` as `FROM base`.
        for dockerfile in (f"FROM \\\n  node@sha256:{DIGEST}\nRUN echo hi\n",
                           f"FROM --platform=linux/amd64 \\\n  node@sha256:{DIGEST} \\\n  AS build\nFROM build\n",
                           f"# escape=`\nFROM `\n  node@sha256:{DIGEST}\n"):
            with self.subTest(dockerfile=dockerfile):
                self.assert_hygiene(dockerfile, True)

    def test_496_3_mutable_image_after_a_line_continuation_still_fails(self):
        self.assert_hygiene("FROM \\\n  node:20\n", False, "'node:20'")

    def test_496_4_heredoc_body_is_not_a_build_stage(self):
        # Docker 29.9.3 reads the final FROM as a registry image: the heredoc line names no stage.
        dockerfile = "FROM scratch\nCOPY <<EOF /note\nFROM scratch AS alpine\nEOF\nFROM alpine\nENTRYPOINT [\"/bin/true\"]\n"
        self.assert_hygiene(dockerfile, False, "'alpine'")

    def test_496_4_heredoc_body_is_not_an_instruction(self):
        dockerfile = f"FROM node@sha256:{DIGEST}\nRUN <<-SCRIPT\n\tFROM node:20\n\tSCRIPT\n"
        self.assert_hygiene(dockerfile, True)

    def test_496_4_genuine_earlier_stage_is_still_excluded(self):
        dockerfile = f"FROM node@sha256:{DIGEST} AS build\nCOPY <<EOF /note\nhello\nEOF\nFROM build\n"
        self.assert_hygiene(dockerfile, True)

    # Each case below was built with Docker 29.9.3: the final FROM was pulled from the registry, so
    # Docker read it as an instruction (or, for the numeric and ONBUILD cases, the heredoc body as data).
    def test_499_line_that_hides_a_mutable_image_still_fails(self):
        pinned = f"FROM node@sha256:{DIGEST}\n"
        cases = {
            "here-string": pinned + "RUN cat <<<EOF\nFROM node:20\n",
            "escaped escape": pinned + "RUN echo \\\\\nFROM node:20\n",
            "quoted heredoc marker": pinned + "RUN echo \"<<EOF\"\nFROM node:20\n",
            "json form": pinned + "RUN [\"echo\", \"<<EOF\"]\nFROM node:20\n",
        }
        for label, dockerfile in cases.items():
            with self.subTest(label):
                self.assert_hygiene(dockerfile, False, "'node:20'")

    def test_499_heredoc_body_names_no_stage(self):
        for label, opener in {"numeric delimiter": "COPY <<123 /note\nFROM scratch AS alpine\n123\n",
                              "onbuild": "ONBUILD COPY <<EOF /note\nFROM scratch AS alpine\nEOF\n"}.items():
            with self.subTest(label):
                self.assert_hygiene("FROM scratch\n" + opener + "FROM alpine\n", False, "'alpine'")

    def test_499_unknown_directive_ends_directive_scanning(self):
        # Docker kept the backslash escape here, so `FROM alpine` is its own instruction.
        self.assert_hygiene("# owner=team\n# escape=`\nFROM scratch\nCOPY note `\nFROM alpine\n", False, "'alpine'")

    def test_499_known_directives_before_escape_still_apply(self):
        # Docker joined `COPY note `` and `FROM node:20` under `# syntax` then `# escape=``.
        dockerfile = f"# syntax=docker/dockerfile:1\n# escape=`\nFROM node@sha256:{DIGEST}\nCOPY note `\nFROM node:20\n"
        self.assert_hygiene(dockerfile, True)

    def test_499_quoted_and_fd_heredoc_delimiters_are_read(self):
        for opener in ('RUN <<"EOF"\n', "RUN 3<<'EOF' cat\n"):
            with self.subTest(opener=opener):
                self.assert_hygiene(f"FROM node@sha256:{DIGEST}\n{opener}FROM node:20\nEOF\n", True)


if __name__ == "__main__":
    unittest.main()
