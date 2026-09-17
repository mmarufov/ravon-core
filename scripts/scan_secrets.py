#!/usr/bin/env python3
"""Fail the build if a privileged credential is committed.

Grepping for the string `service_role` is useless here: .gitignore, CLAUDE.md and
README.md all mention it legitimately, and a real leaked key does not contain the
word at all -- it is a JWT whose *decoded payload* carries {"role": "service_role"}.

So this decodes every JWT-shaped token it finds and inspects the claim. It also
catches Supabase personal access tokens (`sbp_...`), which grant account-wide
Management API access -- during this project one was found sitting in a config file,
already revoked, next to a live one.

Exit 0 = clean, 1 = credential found, 2 = usage error.
"""
from __future__ import annotations

import base64
import json
import pathlib
import re
import subprocess
import sys

# A JWT: three base64url segments. Supabase anon/service keys are always HS256 JWTs.
JWT = re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")
# Supabase personal access token: account-wide Management API credential.
PAT = re.compile(r"sbp_[A-Za-z0-9]{40}")

# Roles that must never reach a client binary or the repo.
FORBIDDEN_ROLES = {"service_role", "supabase_admin"}

SKIP_DIRS = {".git", ".build", ".context", "node_modules", "DerivedData", ".swiftpm"}
SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip", ".ipa", ".xcassets"}


def tracked_files(root: pathlib.Path) -> list[pathlib.Path]:
    """Only scan what git actually tracks -- untracked scratch files are not a leak."""
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z"], cwd=root, capture_output=True, check=True
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    return [root / p for p in out.decode().split("\0") if p]


def decode_jwt_payload(token: str) -> dict | None:
    """Return the JWT's claims, or None if it is not decodable."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)  # restore base64 padding
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return None


def scan(root: pathlib.Path) -> list[str]:
    findings: list[str] = []
    for path in tracked_files(root):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        if path.suffix.lower() in SKIP_SUFFIXES:
            continue
        # This scanner necessarily contains the patterns it looks for.
        if path.name == "scan_secrets.py":
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue

        rel = path.relative_to(root)
        for lineno, line in enumerate(text.splitlines(), start=1):
            for token in JWT.findall(line):
                claims = decode_jwt_payload(token)
                if claims is None:
                    continue
                role = claims.get("role")
                if role in FORBIDDEN_ROLES:
                    findings.append(
                        f"{rel}:{lineno}: JWT with role={role!r} "
                        f"(ref={claims.get('ref', '?')}) -- full database access"
                    )
            for _ in PAT.findall(line):
                findings.append(
                    f"{rel}:{lineno}: Supabase personal access token "
                    f"(sbp_...) -- account-wide Management API access"
                )
    return findings


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    if not (root / ".git").exists():
        print(f"error: {root} is not a git repository", file=sys.stderr)
        return 2

    findings = scan(root)
    if findings:
        print(f"{len(findings)} privileged credential(s) committed:\n", file=sys.stderr)
        for f in findings:
            print(f"  {f}", file=sys.stderr)
        print(
            "\nRotate the credential first -- git history keeps it reachable "
            "even after you delete the line.",
            file=sys.stderr,
        )
        return 1

    print("secret scan: clean (anon/publishable keys are allowed by design)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
