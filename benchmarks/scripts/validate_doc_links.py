#!/usr/bin/env python3
"""Validate local documentation links, Markdown images and HTML img/a assets.

Runs without third-party dependencies on Windows, Linux and WSL.
"""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
FENCED = re.compile(r"(?ms)^\s*```[^\n]*\n.*?^\s*```\s*$")


class HtmlReferences(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = []

    def handle_starttag(self, tag, attrs):
        fields = dict(attrs)
        if tag == "img" and fields.get("src"):
            self.urls.append(fields["src"])
        elif tag == "a" and fields.get("href"):
            self.urls.append(fields["href"])


def path_from_url(doc: Path, url: str):
    url = url.strip().strip("<>")
    # Markdown links may contain an optional quoted title.
    if ' "' in url:
        url = url.split(' "', 1)[0]
    if not url or url.startswith(("#", "//")):
        return None
    target = urlsplit(url)
    if target.scheme or target.netloc:
        return None
    relative = unquote(target.path)
    if not relative:
        return None
    return (doc.parent / relative).resolve()


def main():
    docs = sorted(ROOT.glob("docs/**/*.md"))
    docs.extend([ROOT / "README.md", ROOT / "README.es.md", ROOT / "benchmarks/README.md"])
    errors = []
    validated = 0
    for doc in docs:
        if not doc.is_file():
            errors.append(f"Missing required document: {doc.relative_to(ROOT)}")
            continue
        source = FENCED.sub("", doc.read_text(encoding="utf-8"))
        # Inline code examples are not documentation hyperlinks.
        source = re.sub(r"`[^`\n]*`", "", source)
        html = HtmlReferences()
        html.feed(source)
        urls = MARKDOWN_LINK.findall(source) + html.urls
        for url in urls:
            target = path_from_url(doc, url)
            if target is None:
                continue
            validated += 1
            if not target.exists():
                errors.append(f"{doc.relative_to(ROOT)} -> {url} (missing)")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Checked {len(docs)} Markdown files and {validated} local links/assets.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
