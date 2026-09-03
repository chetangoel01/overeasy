"""Render the public Overeasy pages from the policy the repository already keeps.

Apple needs a privacy policy at a public HTTPS URL, and a support page is
wanted for the store listing. Both are published with GitHub Pages from the
`gh-pages` branch. The policy is a legal document that will be edited again, so
nothing here retypes it: `docs/privacy-policy.md` stays the single source and
this script renders it, which is the only way the published page and the
repository cannot drift apart.

    python3 Tools/release/build_site.py [--out build/site]

The markdown subset understood here is the subset the policy actually uses —
two heading levels, bullet lists whose items wrap across lines, paragraphs, and
bold runs. Anything else would be silently mangled, so it raises instead.
"""

from __future__ import annotations

import argparse
import html
import re
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / "docs" / "privacy-policy.md"
CONTACT = "hello@chetangoel.me"
DOMAIN = "overeasy.chetangoel.me"

# The app's own palette, read from Ladle/Resources/Assets.xcassets so the page
# and the app agree about what Overeasy looks like.
STYLE = """
:root {
  --paper: #f7f4ef;
  --oat: #ece7e1;
  --ink: #14181b;
  --muted: #64707a;
  --brick: #ee4b2f;
  --rule: rgba(20, 24, 27, 0.12);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --paper: #101214;
    --oat: #1c2024;
    --ink: #f2f4f5;
    --muted: #a6afb7;
    --brick: #ff674e;
    --rule: rgba(242, 244, 245, 0.14);
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--paper);
  color: var(--ink);
  font: 17px/1.65 ui-serif, "Iowan Old Style", "Palatino Linotype", Palatino, Georgia, serif;
  -webkit-text-size-adjust: 100%;
}
.wrap { max-width: 39rem; margin: 0 auto; padding: 4rem 1.5rem 6rem; }
header.masthead { display: flex; align-items: baseline; gap: 0.6rem; margin-bottom: 3.5rem; }
.mark {
  font: 600 0.78rem/1 ui-sans-serif, -apple-system, "Helvetica Neue", sans-serif;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--brick);
}
.mark a { color: inherit; text-decoration: none; }
.masthead nav {
  margin-left: auto;
  font: 0.78rem/1 ui-sans-serif, -apple-system, "Helvetica Neue", sans-serif;
  letter-spacing: 0.06em;
}
.masthead nav a { color: var(--muted); text-decoration: none; margin-left: 1.1rem; }
.masthead nav a:hover, .masthead nav a:focus-visible { color: var(--ink); }
h1 {
  font-size: 2.1rem;
  line-height: 1.15;
  font-weight: 600;
  margin: 0 0 0.6rem;
  text-wrap: balance;
}
.effective {
  font: 0.82rem/1.5 ui-sans-serif, -apple-system, "Helvetica Neue", sans-serif;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--muted);
  margin: 0 0 2.75rem;
}
h2 {
  font-size: 1.16rem;
  font-weight: 600;
  margin: 3rem 0 0.9rem;
  padding-top: 1.6rem;
  border-top: 1px solid var(--rule);
  text-wrap: balance;
}
p { margin: 0 0 1.15rem; }
ul { margin: 0 0 1.15rem; padding-left: 1.15rem; }
li { margin-bottom: 0.85rem; }
li::marker { color: var(--brick); }
strong { font-weight: 600; }
a { color: var(--ink); text-decoration-color: var(--brick); text-underline-offset: 0.18em; }
.lede { font-size: 1.08rem; color: var(--ink); }
.card {
  background: var(--oat);
  border-radius: 14px;
  padding: 1.4rem 1.5rem;
  margin: 0 0 1.15rem;
}
.card p:last-child { margin-bottom: 0; }
footer {
  margin-top: 4rem;
  padding-top: 1.6rem;
  border-top: 1px solid var(--rule);
  font: 0.82rem/1.6 ui-sans-serif, -apple-system, "Helvetica Neue", sans-serif;
  color: var(--muted);
}
footer a { color: var(--muted); }
"""

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<meta name="color-scheme" content="light dark">
<style>{style}</style>
</head>
<body>
<div class="wrap">
<header class="masthead">
  <span class="mark"><a href="./">Overeasy</a></span>
  <nav><a href="privacy.html">Privacy</a><a href="support.html">Support</a></nav>
</header>
{body}
<footer>
  <p>Overeasy is made by Chetan Goel. <a href="mailto:{contact}">{contact}</a></p>
</footer>
</div>
</body>
</html>
"""


def inline(text: str) -> str:
    """Escape a run of markdown text and apply the only span markup used."""
    escaped = html.escape(text, quote=False)
    return re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", escaped)


def render_markdown(source: str) -> tuple[str, str, str]:
    """Return (title, effective line, body HTML) for the policy document."""
    lines = source.splitlines()
    title = ""
    effective = ""
    parts: list[str] = []
    buffer: list[str] = []
    items: list[str] = []

    def flush_paragraph() -> None:
        if buffer:
            parts.append(f"<p>{inline(' '.join(buffer))}</p>")
            buffer.clear()

    def flush_list() -> None:
        if items:
            rendered = "".join(f"<li>{inline(item)}</li>" for item in items)
            parts.append(f"<ul>{rendered}</ul>")
            items.clear()

    for line in lines:
        stripped = line.strip()
        if not stripped:
            flush_paragraph()
            flush_list()
            continue
        if line.startswith("# "):
            flush_paragraph()
            flush_list()
            title = stripped[2:]
            continue
        if line.startswith("## "):
            flush_paragraph()
            flush_list()
            parts.append(f"<h2>{inline(stripped[3:])}</h2>")
            continue
        if line.startswith("#"):
            raise ValueError(f"unsupported heading depth: {line!r}")
        if stripped.startswith("- "):
            flush_paragraph()
            items.append(stripped[2:])
            continue
        if items and line.startswith("  "):
            # A wrapped continuation of the bullet above it.
            items[-1] = f"{items[-1]} {stripped}"
            continue
        if stripped.startswith("Effective:") and not effective:
            flush_list()
            effective = stripped
            continue
        flush_list()
        buffer.append(stripped)

    flush_paragraph()
    flush_list()

    if not title:
        raise ValueError("the policy has no top-level heading")
    return title, effective, "\n".join(parts)


def privacy_page() -> str:
    title, effective, body = render_markdown(POLICY.read_text(encoding="utf-8"))
    head = f"<h1>{inline(title)}</h1>"
    if effective:
        head += f'\n<p class="effective">{inline(effective)}</p>'
    return PAGE.format(
        title=f"{title} — Overeasy",
        description="How Overeasy handles your recipes, account, and data.",
        style=STYLE,
        body=f"{head}\n{body}",
        contact=CONTACT,
    )


def support_page() -> str:
    body = f"""<h1>Support</h1>
<p class="effective">Overeasy for iPhone</p>
<p class="lede">Something broken, something confusing, or an import that came out
wrong? Write to a real person and say what happened.</p>
<div class="card">
<p><strong>Email</strong> — <a href="mailto:{CONTACT}">{CONTACT}</a></p>
<p>If a recipe imported badly, include the link you pasted. That is almost always
enough to reproduce it.</p>
</div>
<h2>Things you can do in the app</h2>
<ul>
<li><strong>Fix an import.</strong> Every recipe is editable: open it, tap Edit, and
correct anything the extraction got wrong. Corrections stay on your copy.</li>
<li><strong>Change your name or photo.</strong> Profile, then tap your avatar.</li>
<li><strong>Delete your account.</strong> Profile, then Delete account. It removes
your recipes, imports, sessions, and any photo you uploaded. It cannot be
undone.</li>
</ul>
<h2>Privacy</h2>
<p>What Overeasy collects, why, how long it keeps it, and how to have it deleted
is set out in the <a href="privacy.html">privacy policy</a>.</p>"""
    return PAGE.format(
        title="Support — Overeasy",
        description="How to get help with Overeasy.",
        style=STYLE,
        body=body,
        contact=CONTACT,
    )


def index_page() -> str:
    body = f"""<h1>Overeasy</h1>
<p class="effective">Recipes, kept</p>
<p class="lede">Overeasy turns a recipe video or a wall of text into a recipe you
can actually cook from — ingredients, method, timings — and keeps it on your
phone, yours to edit.</p>
<p>It is in testing on TestFlight.</p>
<h2>Pages</h2>
<ul>
<li><a href="privacy.html">Privacy policy</a> — what is collected, why, and for
how long.</li>
<li><a href="support.html">Support</a> — how to reach a person.</li>
</ul>"""
    return PAGE.format(
        title="Overeasy",
        description="Overeasy turns recipe videos and text into recipes you can cook from.",
        style=STYLE,
        body=body,
        contact=CONTACT,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="build/site", help="output directory")
    parser.add_argument(
        "--cname",
        action="store_true",
        help=(
            f"also write a CNAME for {DOMAIN}. Withhold it until the DNS record "
            "exists: GitHub redirects the github.io URL to the custom domain, so "
            "a CNAME without DNS leaves no working URL at all."
        ),
    )
    args = parser.parse_args()

    out = (ROOT / args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    (out / "index.html").write_text(index_page(), encoding="utf-8")
    (out / "privacy.html").write_text(privacy_page(), encoding="utf-8")
    (out / "support.html").write_text(support_page(), encoding="utf-8")
    if args.cname:
        (out / "CNAME").write_text(f"{DOMAIN}\n", encoding="utf-8")
    else:
        (out / "CNAME").unlink(missing_ok=True)
    # GitHub Pages runs Jekyll unless told not to, and Jekyll hides files it
    # does not recognise.
    (out / ".nojekyll").write_text("", encoding="utf-8")

    print(f"Wrote {out} ({date.today().isoformat()})")


if __name__ == "__main__":
    main()
