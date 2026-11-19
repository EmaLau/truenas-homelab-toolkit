#!/usr/bin/env python3
"""Checks the relative links of the Markdown documentation: the file exists and,
for links with #anchor, the heading exists (anchors computed as GitHub does).

    python3 tests/docs-links-test.py
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
FILES = [
    "README.md",
    "README.it.md",
    "docs/documentation.md",
    "docs/documentazione.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "CHANGELOG.md",
    "ROADMAP.md",
]


def without_code(text):
    return re.sub(r"```.*?```", "", text, flags=re.DOTALL)


def slug(heading):
    return re.sub(r"[^\w\- ]", "", heading.strip().lower()).replace(" ", "-")


def main():
    anchors, broken = {}, []
    for f in FILES:
        with open(os.path.join(ROOT, f)) as fh:
            text = without_code(fh.read())
        anchors[f] = {slug(h) for h in re.findall(r"^#+ (.+)$", text, re.MULTILINE)}
    for f in FILES:
        with open(os.path.join(ROOT, f)) as fh:
            text = without_code(fh.read())
        for link in re.findall(r"\]\(([^)\s]+)\)", text):
            if link.startswith(("http://", "https://", "mailto:")):
                continue
            path, _, frag = link.partition("#")
            target = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else f
            if not os.path.exists(os.path.join(ROOT, target)):
                broken.append(f"{f}: missing file {link}")
            elif frag and target in anchors and frag not in anchors[target]:
                broken.append(f"{f}: missing heading {link}")
    for b in broken:
        print("FAIL", b)
    if broken:
        sys.exit(1)
    print(f"all documentation links work ({len(FILES)} files)")


if __name__ == "__main__":
    main()
