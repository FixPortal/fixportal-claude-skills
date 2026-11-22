#!/usr/bin/env python3
"""Fails when a tracked file leaks something the public mirror must never carry.

Everything in this repository is world-readable, and the low-risk tiers get no AI
reviewer — so a README-only PR can publish a private path with CI green unless the
sweep is mechanical. This is that sweep. It enumerates `git ls-files` rather than
globbing: `**` and `rg` skip dot-directories by default, so a glob-scoped sweep reports
clean while a private slug sits in `.github/` — which is exactly how one reached main.

Four classes, all matched against the public placeholder vocabulary in AGENTS.md
(`~/.claude/...`, `<vault>`, `<workdir>`, `you@example.com`, `Acme`, `<your-org>`):

1. Windows user-profile paths — a drive root, the `Users` directory, then a real
   account name. A placeholder `<name>` and the machine-standard accounts (Public,
   Default) are not a leak; any other name is.
2. Drive-root absolute paths — a multi-segment absolute path with a drive letter is
   a machine layout, never portable documentation. Single-segment and regex-shaped
   text are not matched.
3. Org-name wiring forms — the dotted namespace, environment-variable, and package-scope
   forms of the organisation name. Prose mentions are not matched; these forms only ever
   appear as real wiring. The tokens are assembled from fragments so this gate does not
   flag its own source.
4. URLs and hostnames — enumerated as their own class because a token-list gate only
   finds names it was told about, and a deployment hostname is a leak with no token in
   it. Flagged: hosts under deployable PaaS suffixes (Azure app/Service Bus/Key Vault/
   SQL/storage endpoints, tunnel providers), private TLDs, RFC1918/loopback IP hosts,
   and URLs carrying credentials. Documentation hosts (github.com, learn.microsoft.com,
   ...) are unaffected.
"""

import os
import re
import subprocess
import sys


# Class 1+2: machine paths.
WINDOWS_PROFILE = re.compile(r"[A-Za-z]:[\\/]+Users[\\/]+([^\\/\s\"'`]+)")
DRIVE_PATH = re.compile(r"[A-Za-z]:\\[A-Za-z0-9_.$()\\<>][A-Za-z0-9_.$() \\<>-]*\\")
STANDARD_ACCOUNTS = {"public", "default", "default user", "all users"}
# A drive-root path that only locates an allowed profile (placeholder name or a
# machine-standard account) is covered by the class-1 allowlist, not flagged twice.
ALLOWED_PROFILE_PREFIX = re.compile(
    r"^[A-Za-z]:[\\/]+Users[\\/]+(?:<|Public\\|Default\\|Default User\\|All Users\\)",
    re.IGNORECASE,
)

# Class 3: org-name wiring forms, fragment-built so this file does not flag itself.
_ORG = "Fix" + "Portal"
ORG_FORMS = [
    _ORG + ".",                    # dotted namespace form, e.g. a package id prefix
    _ORG.upper() + "_",            # environment-variable prefix form
    "@" + _ORG.lower() + "/",      # package-scope form
]

# Class 4: endpoints.
URL = re.compile(r"https?://([^/\s)\]>\"'`]+)")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
PAAS_SUFFIXES = (
    ".azurewebsites.net",
    ".azurecontainerapps.io",
    ".azurestaticapps.net",
    ".azure-api.net",
    ".servicebus.windows.net",
    ".vault.azure.net",
    ".database.windows.net",
    ".blob.core.windows.net",
    ".queue.core.windows.net",
    ".table.core.windows.net",
    ".file.core.windows.net",
    ".redis.cache.windows.net",
    ".cloudapp.azure.com",
    ".trafficmanager.net",
    ".ngrok.io",
    ".ngrok-free.app",
)
PRIVATE_TLDS = (".internal", ".lan", ".corp", ".local", ".home")
EXAMPLE_DOMAINS = ("example.com", "example.org", "example.net", "example.test", "example.invalid")
PRIVATE_IP = re.compile(
    r"^(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}"
    r"|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|127\.\d{1,3}\.\d{1,3}\.\d{1,3})$"
)


def check_host(host):
    """Return a reason string if the host looks like a real deployment endpoint."""
    host = host.lower().rstrip(".")
    if "@" in host or ":" in host:  # credentials or a non-default port in a URL
        return "URL carries credentials or an explicit port"
    if host.startswith("<"):  # a placeholder such as https://<app>.example.com
        return None
    for suffix in PAAS_SUFFIXES:
        if host.endswith(suffix):
            return f"host ends with deployable suffix '{suffix}'"
    for tld in PRIVATE_TLDS:
        if host.endswith(tld):
            return f"host uses private TLD '{tld}'"
    if PRIVATE_IP.match(host):
        return "host is a private or loopback IP address"
    return None


def scan(path, text):
    problems = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        for match in WINDOWS_PROFILE.finditer(line):
            name = match.group(1)
            if name.startswith("<") or name.lower() in STANDARD_ACCOUNTS:
                continue
            problems.append(f"{path}:{lineno}: Windows user-profile path with a real name: {match.group(0)}")
        for match in DRIVE_PATH.finditer(line):
            if ALLOWED_PROFILE_PREFIX.match(match.group(0)):
                continue
            problems.append(f"{path}:{lineno}: drive-root absolute path: {match.group(0)}")
        for form in ORG_FORMS:
            if form in line:
                problems.append(f"{path}:{lineno}: org-name wiring form: {form}")
        for match in URL.finditer(line):
            reason = check_host(match.group(1))
            if reason:
                problems.append(f"{path}:{lineno}: {reason}: {match.group(0)}")
        for match in EMAIL.finditer(line):
            domain = match.group(1).lower()
            if not any(domain == d or domain.endswith("." + d) for d in EXAMPLE_DOMAINS):
                problems.append(f"{path}:{lineno}: non-placeholder email address: {match.group(0)}")
    return problems


def main():
    # `-z` terminates entries with NUL and disables path quoting, so a tracked name
    # with a space, quote, or non-ASCII byte arrives verbatim instead of as a
    # core.quotePath-escaped string that open() would then miss.
    listing = subprocess.run(
        ["git", "ls-files", "-z"], check=True, capture_output=True
    ).stdout.decode("utf-8", errors="replace").split("\0")

    problems = []
    scanned = 0
    for path in listing:
        if not path:
            continue
        if os.path.isdir(path):
            continue  # a tracked submodule entry is a directory, not a greppable file
        with open(path, "rb") as handle:
            blob = handle.read()
        if b"\0" in blob:  # binary artefact; bytes are not greppable prose
            continue
        scanned += 1
        problems.extend(scan(path, blob.decode("utf-8", errors="replace")))

    if problems:
        for problem in problems:
            print(problem)
        sys.exit(f"{len(problems)} private-token leak(s) in tracked files.")
    print(f"No private tokens in {scanned} tracked files (dot-directories included).")


if __name__ == "__main__":
    main()
