#!/usr/bin/env python3
"""Fail the build if a relative link in a tracked markdown file does not resolve.

    python3 scripts/check_links.py              # every tracked *.md file
    python3 scripts/check_links.py --self-test

## Why

The README and the docs are how this repository is read, and they link to code, to each
other and to section anchors. Moving a file, or rewording a heading, breaks every link
to it without failing anything; the first to notice is a reader. Two such links were
broken on main when this check was added: one to a README section that a rewrite had
removed, and one that missed the double hyphen GitHub makes of an em dash.

## What is checked

  * `[text](target)` and `![alt](target)`, where the target is a path rather than a URL.
    It is resolved against the linking file (or the repository root, for `/path`) and
    must be a tracked file or directory. Tracked, not merely present: an ignored or
    untracked file exists only on the machine that has it, and the case must match
    exactly, because GitHub is case-sensitive even where the local disk is not.
  * `file.md#anchor` and `#anchor`. The anchor must match a heading of the target,
    slugged the way GitHub does it (lowercase; punctuation other than `-` and `_`
    dropped; each space becomes `-`; repeats get `-1`, `-2`, ...), or an explicit
    `id`/`name` attribute.

Links inside code blocks and inline code are not links, and are skipped. External URLs
are not fetched: whether someone else's page still exists is not a property of this
repository.
"""
from __future__ import annotations

import pathlib
import posixpath
import re
import subprocess
import sys
import tempfile
import unicodedata
from urllib.parse import unquote

FENCE = re.compile(r"^[ \t]*(`{3,}|~{3,}).*?^[ \t]*\1[`~]*[ \t]*$", re.MULTILINE | re.DOTALL)
INLINE_CODE = re.compile(r"(`+)(?!`)(?:[^\n]|\n(?![ \t]*\n))*?(?<!`)\1(?!`)")
LINK = re.compile(
    r"!?\[(?:[^\[\]]|\[[^\[\]]*\])*\]"
    r"\(\s*(<[^>\n]*>|[^\s()]*(?:\([^\s()]*\)[^\s()]*)*)(?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\)"
)
ATX = re.compile(r"^ {0,3}#{1,6}[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$")
SETEXT_UNDERLINE = re.compile(r"^ {0,3}(=+|-+)[ \t]*$")
EXPLICIT_ANCHOR = re.compile(r"""\b(?:id|name)=["']([^"']+)["']""")
SCHEME = re.compile(r"^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|//)")


def _blank(match: re.Match[str], keep: str = "") -> str:
    """Replace a code span with `keep`, preserving its newlines so line numbers hold."""
    return keep + "\n" * match.group(0).count("\n")


def strip_code(text: str) -> str:
    text = FENCE.sub(_blank, text)
    return INLINE_CODE.sub(lambda m: _blank(m, "code"), text)


def slugify(heading: str) -> str:
    heading = re.sub(r"`([^`]*)`", r"\1", heading)
    heading = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)
    heading = re.sub(r"<[^>]+>", "", heading).strip().lower()
    out = []
    for ch in heading:
        if ch == " ":
            out.append("-")
        elif ch in "-_" or unicodedata.category(ch)[0] in "LNM":
            out.append(ch)
    return "".join(out)


def anchors(text: str) -> set[str]:
    lines = FENCE.sub(_blank, text).split("\n")
    titles = []
    for i, line in enumerate(lines):
        atx = ATX.match(line)
        if atx:
            titles.append(atx.group(1))
        elif (i + 1 < len(lines) and SETEXT_UNDERLINE.match(lines[i + 1])
              and line.strip() and not re.match(r"^ {0,3}([-*+>|]|\d+[.)])", line)):
            titles.append(line)
    found: set[str] = set()
    seen: dict[str, int] = {}
    for title in titles:
        slug = slugify(title)
        n = seen.get(slug, 0)
        found.add(slug if n == 0 else f"{slug}-{n}")
        seen[slug] = n + 1
    return found | set(EXPLICIT_ANCHOR.findall(text))


def check(root: pathlib.Path, md_files: list[str], tracked: set[str]) -> tuple[list[str], int]:
    """Return (broken links as `file:line: message`, number of links checked)."""
    known = set(tracked)
    for path in tracked:
        parts = path.split("/")
        known |= {"/".join(parts[:i]) for i in range(1, len(parts))}
    anchor_cache: dict[str, set[str]] = {}
    broken, checked = [], 0
    for rel in md_files:
        text = (root / rel).read_text(encoding="utf-8")
        scanned = strip_code(text)
        for match in LINK.finditer(scanned):
            target = match.group(1).strip("<>")
            if not target or SCHEME.match(target):
                continue
            checked += 1
            where = f"{rel}:{scanned.count(chr(10), 0, match.start()) + 1}"
            file_part, _, anchor = target.partition("#")
            file_part = unquote(file_part)
            if not file_part:
                dest = rel
            elif file_part.startswith("/"):
                dest = posixpath.normpath(file_part.lstrip("/"))
            else:
                dest = posixpath.normpath(posixpath.join(posixpath.dirname(rel), file_part))
            if dest == ".":
                dest = ""
            if dest.startswith("../") or dest == "..":
                broken.append(f"{where}: {target} points outside the repository")
                continue
            if dest and dest not in known:
                broken.append(f"{where}: {target} does not exist in the tracked tree")
                continue
            if anchor and dest.endswith(".md") and dest in tracked:
                if dest not in anchor_cache:
                    anchor_cache[dest] = anchors((root / dest).read_text(encoding="utf-8"))
                if unquote(anchor).lower() not in anchor_cache[dest]:
                    broken.append(f"{where}: {target} names no heading in {dest}")
    return broken, checked


def self_test() -> int:
    files = {
        "README.md": "# Top\n\n## Ship it — fast\n\n## Repeat\n\n## Repeat\n",
        "docs/guide.md": "Setext title\n============\n\n<a name=\"pinned\"></a>\n",
        "docs/img.png": "",
        "src/Main.kt": "",
    }
    cases = [
        ("relative file", "[a](guide.md)", True),
        ("parent and anchor", "[a](../README.md#top)", True),
        ("em dash makes a double hyphen", "[a](../README.md#ship-it--fast)", True),
        ("single hyphen for an em dash", "[a](../README.md#ship-it-fast)", False),
        ("repeated heading gets -1", "[a](../README.md#repeat-1)", True),
        ("third repeat does not exist", "[a](../README.md#repeat-2)", False),
        ("setext heading", "[a](guide.md#setext-title)", True),
        ("explicit anchor", "[a](guide.md#pinned)", True),
        ("same-file anchor", "## Here\n\n[a](#here)", True),
        ("same-file anchor that is elsewhere", "[a](#pinned)", False),
        ("missing file", "[a](nothing.md)", False),
        ("missing anchor", "[a](guide.md#nowhere)", False),
        ("wrong case", "[a](Guide.md)", False),
        ("directory", "[a](../src/)", True),
        ("root-relative", "[a](/src/Main.kt)", True),
        ("image", "![a](img.png)", True),
        ("missing image", "![a](gone.png)", False),
        ("code in link text", "[`src/`](../src/)", True),
        ("escapes the repo", "[a](../../outside.md)", False),
        ("external URL is not fetched", "[a](https://example.invalid/x)", True),
        ("inside a code fence", "```\n[a](nothing.md)\n```", True),
        ("inside inline code", "`[a](nothing.md)`", True),
    ]
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        for name, body in files.items():
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text(body, encoding="utf-8")
        for name, link, should_pass in cases:
            (root / "docs/case.md").write_text(link + "\n", encoding="utf-8")
            broken, _ = check(root, ["docs/case.md"], set(files) | {"docs/case.md"})
            ok = (not broken) == should_pass
            failed += not ok
            print(f"  {'ok  ' if ok else 'FAIL'} {name}: {'accepted' if not broken else 'rejected'}")
    print(f"\n{len(cases) - failed}/{len(cases)} self-test cases behaved")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        return self_test()
    if argv:
        print(__doc__.split("## Why")[0], file=sys.stderr)
        return 2
    root = pathlib.Path(subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], text=True).strip())
    tracked = set(subprocess.check_output(["git", "ls-files"], cwd=root, text=True).splitlines())
    md_files = sorted(p for p in tracked if p.endswith(".md") and (root / p).is_file())
    broken, checked = check(root, md_files, tracked)
    for line in broken:
        print(f"  BROKEN {line}")
    print(f"check_links: {checked} relative links in {len(md_files)} markdown files, "
          f"{len(broken)} broken")
    return 1 if broken else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
