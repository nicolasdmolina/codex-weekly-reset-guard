#!/usr/bin/env python3
"""Inspect staged source and reachable Git history without printing matched data."""

import re
import subprocess
import sys
from pathlib import PurePosixPath


ROOT_FILES = {
    ".gitignore", "AGENTS.md", "CHANGELOG.md", "CONTRIBUTING.md", "DESIGN.md",
    "LICENSE", "Package.swift", "README.md", "SECURITY.md",
}
DOC_FILES = {
    "ARCHITECTURE.md", "PRIVACY.md", "RELEASING.md", "RELEASE-RECEIPT.md", "VISUAL-QA.md",
}
PATTERNS = {
    "personal home path": re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+"),
    "private key material": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "API key format": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    "GitHub token format": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    "GitHub fine-grained token format": re.compile(r"\bgithub_pat_[A-Za-z0-9_]{40,}\b"),
    "JWT format": re.compile(r"\beyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b"),
}


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.PIPE)


def allowed_path(name):
    path = PurePosixPath(name)
    if name in ROOT_FILES:
        return True
    if any(part.startswith(".env") or part.lower() in {
        "auth.json", "credentials.json", "secrets", "profiles", "state.json", "events.json",
    } for part in path.parts):
        return False
    if name == "Resources/Info.plist":
        return True
    if len(path.parts) == 2 and path.parts[0] == "docs":
        return path.name in DOC_FILES
    if path.parts[0] in {"Sources", "Tests"}:
        return path.suffix == ".swift"
    if len(path.parts) == 2 and path.parts[0] == "scripts":
        return path.suffix in {".sh", ".py"}
    if path.parts[0] == ".github":
        return path.suffix in {".md", ".yml", ".yaml"}
    return False


def scan():
    issues = []
    seen_entries = set()
    seen_blobs = set()
    checked_paths = set()

    def inspect(mode, oid, path, origin):
        entry = (mode, oid, path)
        if entry in seen_entries:
            return
        seen_entries.add(entry)
        if not allowed_path(path):
            issues.append(f"{origin}: unexpected publish path {path!r} (contents not read)")
            return
        if mode not in {"100644", "100755"}:
            issues.append(f"{origin}: non-regular file {path!r} (contents not read)")
            return
        checked_paths.add(path)
        if oid in seen_blobs:
            return
        seen_blobs.add(oid)
        if int(git("cat-file", "-s", oid)) > 1_000_000:
            issues.append(f"{origin}: oversized source artifact {path!r} (contents not read)")
            return
        data = git("cat-file", "blob", oid)
        try:
            source = data.decode("utf-8")
        except UnicodeDecodeError:
            issues.append(f"{origin}: non-text source artifact {path!r}")
            return
        if "\x00" in source:
            issues.append(f"{origin}: binary content in {path!r}")
        for label, pattern in PATTERNS.items():
            if pattern.search(source):
                issues.append(f"{origin}: {label} in {path!r} (value withheld)")

    index = git("ls-files", "--stage", "-z")
    if not index:
        issues.append("No source is staged or tracked. Stage the intended publish set first.")
    for record in index.split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, oid, stage = metadata.decode().split()
        path = raw_path.decode("utf-8", errors="replace")
        if stage != "0":
            issues.append(f"Unresolved index conflict in {path!r}")
        else:
            inspect(mode, oid, path, "index")

    trees = set(git("log", "--all", "--format=%T").splitlines())
    for tree in sorted(trees):
        for record in git("ls-tree", "-r", "-z", tree.decode()).split(b"\0"):
            if not record:
                continue
            metadata, raw_path = record.split(b"\t", 1)
            mode, _, oid = metadata.decode().split()
            inspect(mode, oid, raw_path.decode("utf-8", errors="replace"), "history")

    required = {"LICENSE", "README.md", "CONTRIBUTING.md", "SECURITY.md", "Package.swift",
                "docs/PRIVACY.md", "docs/RELEASING.md", ".github/workflows/ci.yml"}
    index_paths = set(git("ls-files", "-z").decode().split("\0"))
    for path in sorted(required - index_paths):
        issues.append(f"Missing required publication file: {path}")
    if issues:
        print("Publication check failed:", file=sys.stderr)
        for issue in sorted(set(issues)):
            print(f"- {issue}", file=sys.stderr)
        return 1
    print(f"Publication check passed: {len(checked_paths)} source paths, "
          f"{len(seen_blobs)} distinct blobs, {len(trees)} historical trees.")
    print("This checks the Git publish set, not untracked/unstaged files or account state.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(scan())
    except (subprocess.CalledProcessError, ValueError) as error:
        print(f"Publication check could not complete ({type(error).__name__}).", file=sys.stderr)
        sys.exit(1)
