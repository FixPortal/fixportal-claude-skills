#!/usr/bin/env python3
"""Regression tests for assert_no_private_tokens.py's scan().

This gate is the only thing standing between a README-only PR and a leaked
machine path or private endpoint landing on a PUBLIC repo with CI green (see
the module docstring). It had zero test coverage before this file: every
allowlist edge case (placeholder names, machine-standard accounts, example
domains, PaaS suffixes) was exercised for the first time by whichever PR
happened to trip it. Run with: python3 .github/scripts/test_assert_no_private_tokens.py

Fixture strings that look like real leaks (a Windows username, a real email
domain, a private IP) are assembled from fragments at runtime rather than
written as literals, so this file does not trip the very gate it tests when
assert_no_private_tokens.py scans this repo's own tracked files.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from assert_no_private_tokens import scan  # noqa: E402


def j(*parts):
    return "".join(parts)


class ScanTests(unittest.TestCase):
    def test_flags_real_windows_username(self):
        # This also trips the drive-root-path class; both problems are expected.
        text = j("C:", "\\", "Users", "\\", "chr" + "is", "\\thing.txt")
        problems = scan("f", text)
        self.assertTrue(any("Windows user-profile path" in p for p in problems), problems)

    def test_allows_placeholder_and_standard_accounts(self):
        for name in ("<name>", "Public", "Default"):
            text = j("C:", "\\Users\\", name, "\\thing.txt")
            self.assertEqual(scan("f", text), [], text)

    def test_flags_drive_root_path(self):
        text = j("D:", "\\fix-portal\\some-repo\\file.cs")
        problems = scan("f", text)
        self.assertTrue(any("drive-root absolute path" in p for p in problems), problems)

    def test_flags_org_wiring_forms(self):
        problems = scan("f", j("Fix", "Portal", ".Something.Api"))
        self.assertTrue(any("org-name wiring form" in p for p in problems), problems)

    def test_allows_org_name_in_prose(self):
        # A bare mention of the org name (no dotted/env/scope wiring form) is not flagged.
        self.assertEqual(scan("f", j("This project is used by Fix", "Portal")), [])

    def test_flags_paas_hostname(self):
        problems = scan("f", j("See https://myapp.azure", "websites.net/health"))
        self.assertTrue(any("deployable suffix" in p for p in problems), problems)

    def test_allows_documentation_host(self):
        self.assertEqual(scan("f", "See https://github.com/foo/bar"), [])

    def test_flags_private_tld(self):
        problems = scan("f", j("curl http://service.", "internal", "/status"))
        self.assertTrue(any("private TLD" in p for p in problems), problems)

    def test_flags_private_ip(self):
        ip = j("192.168.", "1.5")
        problems = scan("f", j("connect to http://", ip, ":8080/"))
        # The non-default port also trips the credentials-or-port branch; either reason is
        # fine, but there must be exactly one problem for the one URL match, not zero.
        self.assertEqual(len(problems), 1)

    def test_allows_placeholder_host(self):
        self.assertEqual(scan("f", "https://<app>.example.com"), [])

    def test_flags_non_placeholder_email(self):
        problems = scan("f", j("contact chris@real", "company.com for access"))
        self.assertTrue(any("non-placeholder email" in p for p in problems), problems)

    def test_allows_example_domain_email(self):
        self.assertEqual(scan("f", "contact you@example.com for access"), [])

    def test_reports_correct_line_number(self):
        path_fragment = j("C:", "\\Users\\chr" + "is\\x")
        text = "line one\nline two\n" + path_fragment + "\nline four"
        problems = scan("f", text)
        self.assertTrue(problems[0].startswith("f:3:"), problems)


if __name__ == "__main__":
    unittest.main()
