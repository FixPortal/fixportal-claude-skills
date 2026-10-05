"""Phase 0 guidance check: fetch the official skill guidance and diff it against the
committed snapshot the rubric was written from.

The rubric in audit-brief.md is derived from three published pages. When a page changes,
the rubric may be stale, so Axes 1 and 2 (the axes those pages govern) are suspended until
someone reconciles the brief and refreshes the snapshot with --refresh. The audit never
grades from the live page text: that would make two runs over unchanged skills disagree.

    python guidance_drift.py --out <run dir>              # fetch, compare, write guidance-drift.json
    python guidance_drift.py --out <run dir> --refresh    # after reconciling: store the fetch as the snapshot
"""

import argparse
import difflib
import json
import shutil
import subprocess
import sys
from pathlib import Path

SKILL_DIR = Path(__file__).parent
SNAPSHOT_DIR = SKILL_DIR / "assets" / "guidance"

PAGES = [
    {"id": "best-practices", "file": "best-practices.md",
     "url": "https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices"},
    {"id": "spec", "file": "specification.md",
     "url": "https://agentskills.io/specification"},
    {"id": "claude-code", "file": "claude-code-skills.md",
     "url": "https://code.claude.com/docs/en/skills"},
]

# Axes whose rules come from these pages. Axes 3-5 come from house instructions.
GOVERNED_AXES = ["reach", "impl"]

# Site chrome firecrawl prints after the article. Observed 2026-10-03: two uncached scrapes
# of the best-practices page differed only in a breadcrumb printed after the first marker.
CHROME_MARKERS = ("Was this page helpful?", "Assistant")


def normalize(text: str) -> str:
    lines = []
    for line in text.replace("\r\n", "\n").split("\n"):
        if line.strip() in CHROME_MARKERS:
            break
        lines.append(line.rstrip())
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines) + "\n"


def compare(snapshots: Path, fetched: Path) -> dict:
    pages = []
    for page in PAGES:
        entry = {"id": page["id"], "url": page["url"]}
        live = fetched / page["file"]
        if not live.is_file() or not live.read_text(encoding="utf-8").strip():
            entry["status"] = "fetch-failed"
        else:
            stored = snapshots / page["file"]
            if not stored.is_file():
                # The snapshot is optional: a copy shipped without assets/guidance has
                # nothing to diff against. Say so; do not call a missing file drift.
                entry["status"] = "no-snapshot"
                entry["note"] = "no snapshot; compared live only"
                pages.append(entry)
                continue
            old = normalize(stored.read_text(encoding="utf-8"))
            new = normalize(live.read_text(encoding="utf-8"))
            diff = "".join(difflib.unified_diff(
                old.splitlines(keepends=True), new.splitlines(keepends=True),
                f"snapshot/{page['file']}", f"live/{page['file']}"))
            entry["status"] = "drift" if diff else "current"
            if diff:
                entry["diff"] = diff
        pages.append(entry)
    statuses = {p["status"] for p in pages}
    status = ("drift" if "drift" in statuses else "fetch-failed" if "fetch-failed" in statuses
              else "no-snapshot" if "no-snapshot" in statuses else "current")
    return {"status": status, "suspended_axes": GOVERNED_AXES if status == "drift" else [], "pages": pages}


def fetch(dest: Path) -> None:
    exe = shutil.which("firecrawl")
    dest.mkdir(parents=True, exist_ok=True)
    for page in PAGES:
        # A reused run dir must not let an earlier run's file pass as this fetch.
        (dest / page["file"]).unlink(missing_ok=True)
        if not exe:
            continue  # every page then reads as fetch-failed, which is reported, not hidden
        subprocess.run([exe, "scrape", page["url"], "--only-main-content", "--max-age", "0",
                        "-o", str(dest / page["file"])], check=False)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--fetched", type=Path, help="use already-fetched pages instead of calling firecrawl")
    ap.add_argument("--snapshots", type=Path, default=SNAPSHOT_DIR)
    ap.add_argument("--refresh", action="store_true", help="store the fetched pages as the new snapshot")
    args = ap.parse_args(argv)

    fetched = args.fetched or args.out / "guidance-live"
    if not args.fetched:
        fetch(fetched)
    result = compare(args.snapshots, fetched)

    if args.refresh:
        # Per page, not overall: drift outranks fetch-failed in the status.
        if any(p["status"] == "fetch-failed" for p in result["pages"]):
            print("refusing to refresh: a page did not fetch", file=sys.stderr)
            return 1
        args.snapshots.mkdir(parents=True, exist_ok=True)
        for page in PAGES:
            text = normalize((fetched / page["file"]).read_text(encoding="utf-8"))
            (args.snapshots / page["file"]).write_text(text, encoding="utf-8", newline="\n")
        result = compare(args.snapshots, fetched)

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "guidance-drift.json").write_text(json.dumps(result, indent=1), encoding="utf-8")
    for p in result["pages"]:
        print(f"{p['status']:13} {p['id']}")
    print(f"guidance: {result['status']}; suspended axes: {', '.join(result['suspended_axes']) or 'none'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
