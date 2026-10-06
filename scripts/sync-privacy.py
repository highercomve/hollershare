#!/usr/bin/env python3
"""Keep the app's offline policy synchronized with the Zine policy source."""
import argparse
import html
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
source = Path("site/content/privacy.smd").read_text().split("---", 2)[2].strip()

def inline(text):
    escaped = html.escape(text)
    def link(match):
        if not match[2].startswith(("https://", "mailto:")):
            raise SystemExit("Policy links must use HTTPS or mailto")
        return f'<a href="{match[2]}">{match[1]}</a>'
    return re.sub(r"\[([^]]+)\]\(([^)]+)\)", link, escaped)

parts = ['<section id="privacy-policy" class="panel privacy-policy" aria-labelledby="privacy-title" hidden>',
         '<div class="section-top"><h2 id="privacy-title">Privacy policy</h2><button id="privacy-close" class="text-button">Close</button></div>']
for paragraph in source.split("\n\n"):
    if paragraph.startswith("# "):
        parts.append("<h3>" + inline(paragraph[2:]) + "</h3>")
    elif paragraph.startswith(("#", "- ", "* ")):
        raise SystemExit("Unsupported policy markup; use level-one headings and paragraphs")
    else:
        parts.append("<p>" + inline(" ".join(paragraph.splitlines())) + "</p>")
parts.append('</section>')
section = '<!-- privacy-policy:start -->\n' + "\n".join(parts) + '\n<!-- privacy-policy:end -->'
path = Path("frontend/index.html")
old = path.read_text()
new, count = re.subn(r"<!-- privacy-policy:start -->.*?<!-- privacy-policy:end -->", lambda match: section, old, flags=re.S)
if count != 1:
    raise SystemExit("Expected one offline policy placeholder")
if args.check:
    if new != old:
        raise SystemExit("Offline policy differs: run python3 scripts/sync-privacy.py")
    print("Offline policy matches the website")
else:
    path.write_text(new)
