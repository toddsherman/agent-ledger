#!/usr/bin/env python3
"""Prints the CHANGELOG.md section for a version as HTML (for Sparkle) or Markdown (for GitHub)."""
import html, re, sys

def section(changelog, version):
    text = open(changelog, encoding="utf-8").read()
    m = re.search(r"^## " + re.escape(version) + r"\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not m:
        sys.exit(f"CHANGELOG.md has no '## {version}' section")
    return m.group(1).strip()

def to_html(md):
    out, in_list = [], False
    for line in md.splitlines():
        line = line.rstrip()
        item = re.match(r"^[-*] (.*)", line)
        if item:
            if not in_list:
                out.append("<ul>"); in_list = True
            out.append("<li>" + inline(item.group(1)) + "</li>")
            continue
        if in_list:
            out.append("</ul>"); in_list = False
        if line:
            out.append("<p>" + inline(line) + "</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)

def inline(s):
    s = html.escape(s)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", s)

if __name__ == "__main__":
    changelog, version, fmt = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "html")
    body = section(changelog, version)
    print(to_html(body) if fmt == "html" else body)
