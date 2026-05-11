#!/usr/bin/env python3
"""
verify-toc.py — Verify Markdown Table-of-Contents links resolve to real headings.

Reads a Markdown file, derives a GitHub-rendered anchor slug for every `## ` and
`### ` heading, then checks every `[label](#anchor)` link inside the
`## Table of Contents` section against that slug set.

Why this exists
---------------
GitHub renders Markdown headings to anchors using a specific slug algorithm.
When you renumber sections (e.g. inserting a new §8 that bumps Caveats from §8
to §9), the slug for every renumbered heading changes too. The TOC at the top
of the doc *won't* auto-update — its hand-authored `(#9-caveats-and-faqs)`
href has to be edited to match. Easy to forget. Easy for the result to look
fine in a diff view (where the link text still reads "Caveats and FAQs") yet
404 on every click in production.

This script catches that drift before commit.

GitHub's slug algorithm (verified empirically — see staging/docs/CI.md history)
------------------------------------------------------------------------------
1. Lowercase the heading text.
2. Strip every character that is *not* `[a-z0-9_]`, `-`, or space. This drops
   `:` `,` `(` `)` `.` and the em-dash `—`. Underscore is kept because the
   regex `\\w` class includes it; in practice it rarely appears in headings.
3. Replace each space with `-`.
4. GitHub does *NOT* collapse double-dashes. `Per-branch testing — both` →
   `per-branch-testing--both` (two hyphens survive where the em-dash + spaces
   used to be). This was the surprise discovery on 2026-05-11.

Usage
-----
    python3 tools/verify-toc.py docs/CI.md

Exit 0 if the TOC is consistent. Exit 1 (with a printed report) on any
mismatch — link target not found among heading slugs, or duplicate target.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


HEADING_RE = re.compile(r"^(#{2,3})\s+(.+?)\s*$")
TOC_HEADER_RE = re.compile(r"^##\s+Table of Contents\s*$", re.IGNORECASE)
NEXT_H2_RE = re.compile(r"^##\s+")
TOC_LINK_RE = re.compile(r"\[([^\]]+)\]\(#([^)]+)\)")


def github_slug(text: str) -> str:
    """Apply GitHub's heading-to-anchor slug algorithm.

    Per empirical verification on 2026-05-11 against
    https://github.com/carlheinmostert/TrainMe/blob/staging/docs/CI.md
    rendered HTML — GitHub does NOT collapse adjacent hyphens.
    """
    slug = text.lower()
    # Strip every char that isn't a word char, hyphen, or space. The
    # word-char class covers ASCII letters + digits + underscore. Unicode
    # flag keeps things like accented Latin letters; the punctuation we
    # care about (em-dash, colon, comma, period, parens) all gets stripped.
    slug = re.sub(r"[^\w\- ]+", "", slug, flags=re.UNICODE)
    slug = slug.replace(" ", "-")
    return slug


def extract_headings(lines: list[str]) -> list[tuple[int, str, str]]:
    """Return list of (line_no, raw_heading_text, slug) for every ##/### heading."""
    out: list[tuple[int, str, str]] = []
    for i, line in enumerate(lines, start=1):
        m = HEADING_RE.match(line)
        if not m:
            continue
        text = m.group(2)
        out.append((i, text, github_slug(text)))
    return out


def extract_toc_links(lines: list[str]) -> list[tuple[int, str, str]]:
    """Return list of (line_no, link_label, link_target) inside the TOC section."""
    in_toc = False
    out: list[tuple[int, str, str]] = []
    for i, line in enumerate(lines, start=1):
        if TOC_HEADER_RE.match(line):
            in_toc = True
            continue
        if in_toc and NEXT_H2_RE.match(line):
            # Reached the next H2 — TOC section is over.
            break
        if in_toc:
            for m in TOC_LINK_RE.finditer(line):
                out.append((i, m.group(1), m.group(2)))
    return out


def verify(path: Path) -> int:
    lines = path.read_text(encoding="utf-8").splitlines()
    headings = extract_headings(lines)
    toc_links = extract_toc_links(lines)

    if not toc_links:
        print(f"[verify-toc] {path}: no ## Table of Contents section "
              f"with internal links found — nothing to verify.")
        return 0

    slug_set = {slug for (_, _, slug) in headings}

    # Duplicate-anchor sanity (GitHub appends -1, -2 ... in source order;
    # if a doc relies on that, it's already brittle).
    slug_counts: dict[str, int] = {}
    for (_, _, slug) in headings:
        slug_counts[slug] = slug_counts.get(slug, 0) + 1
    dupes = [s for s, c in slug_counts.items() if c > 1]

    broken: list[tuple[int, str, str]] = []
    for (line_no, label, target) in toc_links:
        if target not in slug_set:
            broken.append((line_no, label, target))

    print(f"[verify-toc] {path}")
    print(f"[verify-toc]   headings:  {len(headings)}")
    print(f"[verify-toc]   toc links: {len(toc_links)}")
    print(f"[verify-toc]   ok:        {len(toc_links) - len(broken)}")
    print(f"[verify-toc]   broken:    {len(broken)}")
    if dupes:
        print(f"[verify-toc]   WARN duplicate heading slugs (GitHub appends -1/-2): "
              f"{', '.join(dupes)}")

    if broken:
        print()
        print("Broken TOC entries:")
        for (line_no, label, target) in broken:
            print(f"  {path}:{line_no}: [{label}](#{target}) — no heading "
                  f"slugs to '#{target}'")
        print()
        print("Available heading slugs:")
        for (_, text, slug) in headings:
            print(f"  #{slug}    ({text})")
        return 1

    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    p.add_argument("paths", nargs="+", type=Path,
                   help="Markdown file(s) to verify.")
    args = p.parse_args()
    rc = 0
    for path in args.paths:
        if not path.is_file():
            print(f"[verify-toc] {path}: not a file", file=sys.stderr)
            rc = 1
            continue
        rc = max(rc, verify(path))
    return rc


if __name__ == "__main__":
    sys.exit(main())
