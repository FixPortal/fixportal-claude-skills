"""Contract tests for guidance_drift.py. No network: fetched pages are written to a temp dir."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SKILL_DIR = Path(__file__).parents[1]
MODULE_PATH = SKILL_DIR / "guidance_drift.py"
SPEC = importlib.util.spec_from_file_location("guidance_drift", MODULE_PATH)
assert SPEC and SPEC.loader
drift = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(drift)

BODY = "# Page\n\nKeep SKILL.md under 500 lines.\n\nDescription max 1024 characters.\n"


def seed(snapshots: Path, fetched: Path, fetched_text: dict) -> None:
    snapshots.mkdir()
    fetched.mkdir()
    for page in drift.PAGES:
        (snapshots / page["file"]).write_text(BODY, encoding="utf-8")
        if page["id"] in fetched_text:
            (fetched / page["file"]).write_text(fetched_text[page["id"]], encoding="utf-8")


class CompareTests(unittest.TestCase):
    def run_compare(self, fetched_text: dict) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            snapshots, fetched = Path(tmp) / "snap", Path(tmp) / "fetched"
            seed(snapshots, fetched, fetched_text)
            return drift.compare(snapshots, fetched)

    def all_pages(self, text: str) -> dict:
        return {p["id"]: text for p in drift.PAGES}

    def test_identical_pages_are_current(self) -> None:
        result = self.run_compare(self.all_pages(BODY))
        self.assertEqual(result["status"], "current")
        self.assertEqual({p["status"] for p in result["pages"]}, {"current"})

    def test_one_changed_line_is_drift_naming_the_page_and_the_line(self) -> None:
        fetched = self.all_pages(BODY)
        first = drift.PAGES[0]["id"]
        fetched[first] = BODY.replace("500 lines", "400 lines")
        result = self.run_compare(fetched)
        self.assertEqual(result["status"], "drift")
        changed = [p for p in result["pages"] if p["status"] == "drift"]
        self.assertEqual([p["id"] for p in changed], [first])
        self.assertIn("+Keep SKILL.md under 400 lines.", changed[0]["diff"])
        self.assertIn("-Keep SKILL.md under 500 lines.", changed[0]["diff"])
        self.assertEqual(result["suspended_axes"], ["reach", "impl"])

    def test_page_chrome_after_the_feedback_prompt_is_not_drift(self) -> None:
        # Observed 2026-10-03: two uncached scrapes of the best-practices page differed
        # only in a breadcrumb printed after "Was this page helpful?".
        noisy = self.all_pages(BODY + "\nWas this page helpful?\n\nSkill authoring best practices/\n\nAsk Docs")
        noisy[drift.PAGES[1]["id"]] = BODY + "\nAssistant\n\nResponses are generated using AI."
        result = self.run_compare(noisy)
        self.assertEqual(result["status"], "current")

    def test_a_page_that_did_not_fetch_is_reported_not_skipped(self) -> None:
        fetched = self.all_pages(BODY)
        missing = drift.PAGES[2]["id"]
        del fetched[missing]
        result = self.run_compare(fetched)
        self.assertEqual(result["status"], "fetch-failed")
        statuses = {p["id"]: p["status"] for p in result["pages"]}
        self.assertEqual(statuses[missing], "fetch-failed")
        self.assertEqual(result["suspended_axes"], [])

    def test_drift_outranks_a_failed_fetch(self) -> None:
        fetched = self.all_pages(BODY)
        fetched[drift.PAGES[0]["id"]] = BODY + "New rule.\n"
        del fetched[drift.PAGES[2]["id"]]
        self.assertEqual(self.run_compare(fetched)["status"], "drift")


class MissingSnapshotTests(unittest.TestCase):
    """A copy shipped without assets/guidance must still run Phase 0 against the live pages."""

    def test_missing_snapshot_dir_is_reported_not_called_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fetched = Path(tmp) / "fetched"
            fetched.mkdir()
            for page in drift.PAGES:
                (fetched / page["file"]).write_text(BODY, encoding="utf-8")
            result = drift.compare(Path(tmp) / "no-such-dir", fetched)
        self.assertEqual(result["status"], "no-snapshot")
        self.assertEqual({p["status"] for p in result["pages"]}, {"no-snapshot"})
        self.assertIn("compared live only", result["pages"][0]["note"])
        self.assertEqual(result["suspended_axes"], [])

    def test_one_missing_snapshot_file_leaves_the_others_compared(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            snapshots, fetched = Path(tmp) / "snap", Path(tmp) / "fetched"
            seed(snapshots, fetched, {p["id"]: BODY for p in drift.PAGES})
            (snapshots / drift.PAGES[0]["file"]).unlink()
            statuses = {p["id"]: p["status"] for p in drift.compare(snapshots, fetched)["pages"]}
        self.assertEqual(statuses[drift.PAGES[0]["id"]], "no-snapshot")
        self.assertEqual(statuses[drift.PAGES[1]["id"]], "current")

    def test_drift_elsewhere_still_outranks_a_missing_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            snapshots, fetched = Path(tmp) / "snap", Path(tmp) / "fetched"
            seed(snapshots, fetched, {p["id"]: BODY for p in drift.PAGES})
            (fetched / drift.PAGES[1]["file"]).write_text(BODY + "New rule.\n", encoding="utf-8")
            (snapshots / drift.PAGES[0]["file"]).unlink()
            self.assertEqual(drift.compare(snapshots, fetched)["status"], "drift")

    def test_main_runs_with_a_missing_snapshot_dir_and_mocked_fetch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"

            def fake_fetch(dest: Path) -> None:  # no network
                dest.mkdir(parents=True, exist_ok=True)
                for page in drift.PAGES:
                    (dest / page["file"]).write_text(BODY, encoding="utf-8")

            real_fetch = drift.fetch
            drift.fetch = fake_fetch
            try:
                code = drift.main(["--out", str(out), "--snapshots", str(Path(tmp) / "absent")])
            finally:
                drift.fetch = real_fetch
            result = json.loads((out / "guidance-drift.json").read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertEqual(result["status"], "no-snapshot")

    def test_refresh_creates_the_snapshot_dir(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fetched, out, snapshots = Path(tmp) / "fetched", Path(tmp) / "out", Path(tmp) / "absent"
            fetched.mkdir()
            for page in drift.PAGES:
                (fetched / page["file"]).write_text(BODY, encoding="utf-8")
            code = drift.main(["--out", str(out), "--fetched", str(fetched),
                               "--snapshots", str(snapshots), "--refresh"])
            self.assertEqual(code, 0)
            self.assertTrue(all((snapshots / p["file"]).is_file() for p in drift.PAGES))


class CommittedSnapshotTests(unittest.TestCase):
    # Public mirror: the third-party doc snapshots in assets/guidance/ are not published, so the
    # committed-snapshot check skips when the directory is absent (guidance_drift.py then reports
    # "no-snapshot" and compares live only).
    @unittest.skipUnless(drift.SNAPSHOT_DIR.is_dir(), "SKIP: assets/guidance snapshots not present in this tree")
    def test_every_page_has_a_committed_normalized_snapshot(self) -> None:
        for page in drift.PAGES:
            path = drift.SNAPSHOT_DIR / page["file"]
            self.assertTrue(path.is_file(), f"missing snapshot {path}")
            text = path.read_text(encoding="utf-8")
            self.assertEqual(text, drift.normalize(text), f"{path} is not stored normalized")
            self.assertGreater(len(text.splitlines()), 100, f"{path} looks truncated")

    def test_the_three_official_pages_are_tracked(self) -> None:
        urls = {p["url"] for p in drift.PAGES}
        self.assertEqual(urls, {
            "https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices",
            "https://agentskills.io/specification",
            "https://code.claude.com/docs/en/skills",
        })


class MainTests(unittest.TestCase):
    def test_main_with_fetched_dir_writes_the_result_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            snapshots, fetched, out = Path(tmp) / "snap", Path(tmp) / "fetched", Path(tmp) / "out"
            seed(snapshots, fetched, {p["id"]: BODY for p in drift.PAGES})
            code = drift.main(["--out", str(out), "--fetched", str(fetched), "--snapshots", str(snapshots)])
            self.assertEqual(code, 0)
            result = json.loads((out / "guidance-drift.json").read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "current")

    def test_refresh_refuses_and_writes_nothing_when_any_page_failed_even_alongside_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            snapshots, fetched, out = Path(tmp) / "snap", Path(tmp) / "fetched", Path(tmp) / "out"
            texts = {p["id"]: BODY for p in drift.PAGES}
            texts[drift.PAGES[0]["id"]] = BODY + "New rule.\n"
            del texts[drift.PAGES[2]["id"]]
            seed(snapshots, fetched, texts)
            code = drift.main(["--out", str(out), "--fetched", str(fetched),
                               "--snapshots", str(snapshots), "--refresh"])
            self.assertEqual(code, 1)
            for page in drift.PAGES:
                self.assertEqual((snapshots / page["file"]).read_text(encoding="utf-8"), BODY)


class FetchTests(unittest.TestCase):
    def test_a_stale_page_from_an_earlier_run_is_not_read_as_live(self) -> None:
        # Reused run dir, firecrawl now missing: the old files must not pass as a fresh fetch.
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "live"
            dest.mkdir()
            for page in drift.PAGES:
                (dest / page["file"]).write_text(BODY, encoding="utf-8")
            real_which = drift.shutil.which
            drift.shutil.which = lambda name: None
            try:
                drift.fetch(dest)
            finally:
                drift.shutil.which = real_which
            self.assertEqual([p for p in drift.PAGES if (dest / p["file"]).exists()], [])


class FetchTimeoutTests(unittest.TestCase):
    def test_a_hung_scrape_is_bounded_and_leaves_no_partial_page(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "live"
            seen = []

            def hung_run(cmd, **kwargs):
                seen.append(kwargs.get("timeout"))
                Path(cmd[-1]).write_text("partial", encoding="utf-8")
                raise drift.subprocess.TimeoutExpired(cmd, kwargs.get("timeout"))

            real_which, real_run = drift.shutil.which, drift.subprocess.run
            drift.shutil.which = lambda name: "firecrawl"
            drift.subprocess.run = hung_run
            try:
                drift.fetch(dest)
            finally:
                drift.shutil.which, drift.subprocess.run = real_which, real_run
            self.assertTrue(all(isinstance(t, (int, float)) and t > 0 for t in seen) and seen)
            self.assertEqual([p for p in drift.PAGES if (dest / p["file"]).exists()], [])


class FetchNonzeroExitTests(unittest.TestCase):
    def test_a_failed_scrape_leaves_no_partial_page(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "live"

            def failing_run(cmd, **kwargs):
                Path(cmd[-1]).write_text("partial", encoding="utf-8")
                return drift.subprocess.CompletedProcess(cmd, 1)

            real_which, real_run = drift.shutil.which, drift.subprocess.run
            drift.shutil.which = lambda name: "firecrawl"
            drift.subprocess.run = failing_run
            try:
                drift.fetch(dest)
            finally:
                drift.shutil.which, drift.subprocess.run = real_which, real_run
            self.assertEqual([p for p in drift.PAGES if (dest / p["file"]).exists()], [])


class FetchFailedWithoutSnapshotTests(unittest.TestCase):
    def test_failed_fetch_and_no_snapshot_is_fetch_failed_and_suspends_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fetched = Path(tmp) / "fetched"
            fetched.mkdir()
            result = drift.compare(Path(tmp) / "absent", fetched)
        self.assertEqual(result["status"], "fetch-failed")
        self.assertEqual(result["suspended_axes"], [])


if __name__ == "__main__":
    unittest.main()
