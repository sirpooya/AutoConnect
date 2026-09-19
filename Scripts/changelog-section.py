#!/usr/bin/env python3
"""Print one version's section of CHANGELOG.md, for use as release notes.

Called by .github/workflows/release.yml. The workflow used to publish `--generate-notes`, which
is a link to GitHub's compare view and nothing else; that body is also what lands in the appcast,
so every user offered 1.7.0 was shown a bare compare URL in place of the four things that had
changed. The changelog is already written for exactly this audience, so it is what ships.

Exits non-zero when there is no section for the version, which is the workflow's signal to fall
back to generated notes rather than publish a release with an empty body.
"""

import argparse
import re
import sys

CHANGELOG = "CHANGELOG.md"


def section(text, version):
    """The body under `## [<version>]`, up to the next `## ` heading."""
    pattern = re.compile(
        r"^##\s*\[?" + re.escape(version) + r"\]?.*?$(.*?)(?=^##\s|\Z)",
        re.M | re.S,
    )
    found = pattern.search(text)
    return found.group(1).strip() if found else ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--path", default=CHANGELOG)
    args = parser.parse_args()

    try:
        with open(args.path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    body = section(text, args.version)
    if not body:
        print(f"error: no section for {args.version} in {args.path}", file=sys.stderr)
        return 1

    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
