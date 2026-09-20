#!/usr/bin/env python3
"""Test publication hygiene using disposable Git repositories and synthetic data."""

import subprocess
import sys
import tempfile
from pathlib import Path


SCANNER = Path(__file__).resolve().with_name("check_public_release.py")
REQUIRED_FILES = (
    "LICENSE", "README.md", "CONTRIBUTING.md", "SECURITY.md", "Package.swift",
    "docs/PRIVACY.md", "docs/RELEASING.md", ".github/workflows/ci.yml",
)


def git(root, *args):
    # Synthetic identity and disabled hooks/signing keep all writes in the fixture.
    return subprocess.run(
        ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
         "-c", "user.name=Synthetic Test", "-c", "user.email=test@example.invalid", *args],
        cwd=root, capture_output=True, check=True, timeout=30,
    )


def write(root, name, data):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())


def check_case(label, mutate, *, expect_ok=False, diagnostic=None, withheld=()):
    # TemporaryDirectory only removes the synthetic files created by this test.
    with tempfile.TemporaryDirectory(prefix="guard-synthetic-hygiene-") as directory:
        root = Path(directory)
        git(root, "init", "--template=")
        for name in REQUIRED_FILES:
            write(root, name, "Synthetic source fixture.\n")
        git(root, "add", "--all")
        mutate(root)
        result = subprocess.run(
            [sys.executable, str(SCANNER)], cwd=root,
            capture_output=True, text=True, timeout=30,
        )
        combined = result.stdout + result.stderr
        if result.returncode != (0 if expect_ok else 1):
            raise RuntimeError(f"{label}: unexpected exit status {result.returncode}")
        if diagnostic is not None and diagnostic not in combined:
            raise RuntimeError(f"{label}: expected diagnostic is missing")
        if any(value in combined for value in withheld):
            # Do not echo captured output: this assertion checks non-disclosure.
            raise RuntimeError(f"{label}: matched content was disclosed")
        if "Traceback" in combined:
            raise RuntimeError(f"{label}: scanner raised an uncaught exception")
    print(f"PASS {label}")


def main():
    count = 0

    def run(*args, **kwargs):
        nonlocal count
        check_case(*args, **kwargs)
        count += 1

    run("clean staged source with no commits", lambda root: None, expect_ok=True)
    run("clean committed source", lambda root: git(root, "commit", "-m", "Synthetic fixture"),
        expect_ok=True)

    # Build unmistakably synthetic values at runtime so the test source itself
    # remains publishable under the same detector it exercises.
    samples = {
        "personal home path": "/" + "Users" + "/synthetic-user/private-project",
        "private key material": "-----BEGIN " + "PRIVATE KEY-----",
        "API key format": "sk-" + "A" * 32,
        "GitHub token format": "ghp_" + "B" * 36,
        "GitHub fine-grained token format": "github_pat_" + "C" * 45,
        "JWT format": "eyJ" + "D" * 24 + "." + "E" * 24 + "." + "F" * 24,
    }
    for label, sample in samples.items():
        def add_sample(root, sample=sample):
            write(root, "README.md", f"Synthetic fixture with {sample}\n")
            git(root, "add", "README.md")
        run(label, add_sample, diagnostic=label, withheld=(sample,))

    for name in (".env.example", "profiles/demo/auth.json", "qa-artifacts/private.log",
                 "docs/foundry-planning/brief.md"):
        sample = "FORBIDDEN_CONTENT_SENTINEL_" + "Z" * 24

        def add_forbidden(root, name=name, sample=sample):
            write(root, name, sample)
            git(root, "add", "--force", name)
        run(f"forbidden path {name}", add_forbidden,
            diagnostic="contents not read", withheld=(sample,))

    def add_symlink(root):
        (root / "Sources").mkdir()
        (root / "Sources/Synthetic.swift").symlink_to("../nonexistent-synthetic-target")
        git(root, "add", "Sources/Synthetic.swift")
    run("allowed-name symlink", add_symlink, diagnostic="non-regular file")

    history_sample = "sk-" + "H" * 32

    def removed_history(root):
        write(root, "Sources/Synthetic.swift", history_sample)
        git(root, "add", "Sources/Synthetic.swift")
        git(root, "commit", "-m", "Synthetic history sample")
        git(root, "rm", "Sources/Synthetic.swift")
        git(root, "commit", "-m", "Remove synthetic sample")
    run("removed token remains in reachable history", removed_history,
        diagnostic="history: API key format", withheld=(history_sample,))

    def removed_forbidden_history(root):
        write(root, "profiles/example/auth.json", "SYNTHETIC_ONLY")
        git(root, "add", "--all")
        git(root, "commit", "-m", "Synthetic forbidden path")
        git(root, "rm", "profiles/example/auth.json")
        git(root, "commit", "-m", "Remove synthetic forbidden path")
    run("removed forbidden path remains in history", removed_forbidden_history,
        diagnostic="history: unexpected publish path", withheld=("SYNTHETIC_ONLY",))

    def other_branch_history(root):
        git(root, "commit", "-m", "Clean synthetic base")
        git(root, "branch", "clean-base")
        write(root, "Sources/Synthetic.swift", history_sample)
        git(root, "add", "--all")
        git(root, "commit", "-m", "Synthetic sample on branch")
        git(root, "checkout", "clean-base")
    run("noncurrent branch history", other_branch_history,
        diagnostic="history: API key format", withheld=(history_sample,))

    def missing_required(root):
        git(root, "rm", "--cached", "SECURITY.md")
    run("required publication file absent from index", missing_required,
        diagnostic="Missing required publication file: SECURITY.md")

    for label, data, diagnostic in (
        ("oversized source", b"a" * 1_000_001, "oversized source artifact"),
        ("non-UTF-8 source", b"\xff", "non-text source artifact"),
        ("binary source", b"hello\x00world", "binary content"),
    ):
        def add_invalid(root, data=data):
            write(root, "Sources/Synthetic.swift", data)
            git(root, "add", "Sources/Synthetic.swift")
        run(label, add_invalid, diagnostic=diagnostic)

    print(f"All {count} synthetic publication checks passed; temporary repositories removed.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"Publication regression check failed: {error}", file=sys.stderr)
        sys.exit(1)
