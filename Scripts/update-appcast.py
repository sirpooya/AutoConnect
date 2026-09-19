#!/usr/bin/env python3
"""Regenerate appcast.xml with an entry for one release.

Called by .github/workflows/release.yml once the zip is built, verified and signed. It lives in a
file rather than inline in the workflow because generating the entry needs multi-line XML
templating, and nesting that inside an indented YAML `run:` block is how you get a silently broken
heredoc.

Idempotent: re-running for the same build replaces that build's <item> instead of adding a second
one, so a re-run of a release cannot produce a feed with two entries claiming the same version.
The newest entry is always first.

Sparkle's own `generate_appcast` is not used: it expects a directory holding every archive ever
shipped, and here only the archive just built exists locally. Every earlier one is a GitHub release
asset, and the feed is the record of them.
"""

import argparse
import os
import re
import sys
import xml.dom.minidom as minidom
from datetime import datetime, timezone
from xml.sax.saxutils import escape

APPCAST = "appcast.xml"


def inline(text):
    """Bold, code and links, on text that has already been HTML-escaped."""
    text = escape(text)
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return text


def markdown_to_html(text):
    """Turn a changelog section into the HTML Sparkle actually renders.

    Sparkle draws <description> as HTML, not as markdown. Feeding it markdown is not a
    formatting nicety that degrades gracefully: the update dialog showed a literal
    `**Full Changelog**: https://...` to every user offered 1.7.0, asterisks and all.

    Deliberately small. The input is a changelog section, so it is headings and bullets with the
    occasional bold, code span or link, and a real markdown dependency would be a package added
    to a repo whose whole rule is not to add packages.
    """
    html = []
    in_list = False

    def close_list():
        nonlocal in_list
        if in_list:
            html.append("</ul>")
            in_list = False

    for raw in text.splitlines():
        line = raw.strip()

        if not line:
            close_list()
            continue

        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if heading:
            close_list()
            level = len(heading.group(1))
            html.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
            continue

        bullet = re.match(r"^[-*]\s+(.*)$", line)
        if bullet:
            if not in_list:
                html.append("<ul>")
                in_list = True
            html.append(f"<li>{inline(bullet.group(1))}</li>")
            continue

        close_list()
        html.append(f"<p>{inline(line)}</p>")

    close_list()
    return "\n".join(html)

SKELETON = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>AutoConnect</title>
        <link>{feed_url}</link>
        <description>Most recent changes to AutoConnect.</description>
        <language>en</language>
    </channel>
</rss>
"""

ITEM = """        <item>
            <title>{short_version}</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{build_version}</sparkle:version>
            <sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{min_system}</sparkle:minimumSystemVersion>
            <description><![CDATA[
{notes}
            ]]></description>
            <enclosure
                url="{url}"
                length="{length}"
                type="application/octet-stream"
                sparkle:edSignature="{signature}" />
        </item>
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--short-version", required=True)
    parser.add_argument("--build-version", required=True)
    parser.add_argument("--min-system", required=True)
    parser.add_argument("--zip-name", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--notes", default="")
    args = parser.parse_args()

    feed_url = f"https://raw.githubusercontent.com/{args.repo}/main/appcast.xml"
    url = (
        f"https://github.com/{args.repo}/releases/download/"
        f"{args.tag}/{args.zip_name}"
    )

    notes = markdown_to_html(
        args.notes.strip() or f"AutoConnect {args.short_version}"
    )
    # A literal ]]> inside the notes would close the CDATA block early and corrupt the feed.
    notes = notes.replace("]]>", "]]&gt;")

    if os.path.exists(APPCAST):
        with open(APPCAST, encoding="utf-8") as handle:
            xml = handle.read()
    else:
        xml = SKELETON.format(feed_url=escape(feed_url))

    # Drop any existing <item> for this build, so re-running a release replaces it.
    stale = re.compile(
        r"[ \t]*<item>(?:(?!</item>).)*?<sparkle:version>"
        + re.escape(args.build_version)
        + r"</sparkle:version>.*?</item>\n?",
        re.S,
    )
    xml, removed = stale.subn("", xml)
    if removed:
        print(f"Replaced the existing entry for build {args.build_version}")

    item = ITEM.format(
        short_version=escape(args.short_version),
        pub_date=datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000"),
        build_version=escape(args.build_version),
        min_system=escape(args.min_system),
        notes=notes,
        url=escape(url),
        length=escape(args.length),
        signature=escape(args.signature),
    )

    marker = "</language>\n"
    if marker not in xml:
        print("error: appcast.xml has no <language> line to insert after", file=sys.stderr)
        return 1

    index = xml.index(marker) + len(marker)
    xml = xml[:index] + item + xml[index:]

    with open(APPCAST, "w", encoding="utf-8") as handle:
        handle.write(xml)

    # Fail the release rather than publish a feed Sparkle cannot parse.
    minidom.parse(APPCAST)
    print(f"appcast.xml updated for {args.tag} (build {args.build_version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
