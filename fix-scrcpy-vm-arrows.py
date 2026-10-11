#!/usr/bin/env python3
"""Replace visible Unicode directional glyphs in scrcpy VM site HTML with SVG icons.

Run from any directory with the repository root as the argument. The default is
an inspection-only dry run; pass --apply to update site/index.html,
site/404.html, and site/styles.css.
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path

MARKER = "/* Font-independent directional icons */"
PROTECTED_TAGS = {"code", "pre", "script", "style", "textarea", "title"}

# Characters are mapped to simple, consistent Lucide-like strokes. Tree branch
# glyphs such as ├─ and └─ are intentionally not included.
ARROWS: dict[str, tuple[str, str]] = {
    "↗": ("up-right", "M7 17 17 7 M8 7h9v9"),
    "↘": ("down-right", "M7 7 17 17 M8 17h9V8"),
    "↖": ("up-left", "M17 17 7 7 M16 7H7v9"),
    "↙": ("down-left", "M17 7 7 17 M7 8v9h9"),
    "→": ("right", "M5 12h14 M13 6l6 6-6 6"),
    "←": ("left", "M19 12H5 M11 6l-6 6 6 6"),
    "↑": ("up", "M12 19V5 M6 11l6-6 6 6"),
    "↓": ("down", "M12 5v14 M6 13l6 6 6-6"),
    "↔": ("horizontal", "M4 12h16 M8 8l-4 4 4 4 M16 8l4 4-4 4"),
    "↕": ("vertical", "M12 4v16 M8 8l4-4 4 4 M8 16l4 4 4-4"),
    "⇐": ("left", "M19 12H5 M11 6l-6 6 6 6"),
    "⇒": ("right", "M5 12h14 M13 6l6 6-6 6"),
    "⇑": ("up", "M12 19V5 M6 11l6-6 6 6"),
    "⇓": ("down", "M12 5v14 M6 13l6 6 6-6"),
    "⇔": ("horizontal", "M4 12h16 M8 8l-4 4 4 4 M16 8l4 4-4 4"),
    "⇕": ("vertical", "M12 4v16 M8 8l4-4 4 4 M8 16l4 4 4-4"),
    "⇠": ("left", "M19 12H5 M11 6l-6 6 6 6"),
    "⇢": ("right", "M5 12h14 M13 6l6 6-6 6"),
    "⇡": ("up", "M12 19V5 M6 11l6-6 6 6"),
    "⇣": ("down", "M12 5v14 M6 13l6 6 6-6"),
    "⟵": ("left", "M19 12H5 M11 6l-6 6 6 6"),
    "⟶": ("right", "M5 12h14 M13 6l6 6-6 6"),
    "⟷": ("horizontal", "M4 12h16 M8 8l-4 4 4 4 M16 8l4 4-4 4"),
    "⤴": ("up-right", "M7 17 17 7 M8 7h9v9"),
    "⤵": ("down-right", "M7 7 17 17 M8 17h9V8"),
    "↩": ("left", "M19 12H5 M11 6l-6 6 6 6"),
    "↪": ("right", "M5 12h14 M13 6l6 6-6 6"),
    "↰": ("up-left", "M17 17 7 7 M16 7H7v9"),
    "↱": ("up-right", "M7 17 17 7 M8 7h9v9"),
    "↲": ("down-left", "M17 7 7 17 M7 8v9h9"),
    "↳": ("down-right", "M7 7 17 17 M8 17h9V8"),
    "↴": ("down-right", "M7 7 17 17 M8 17h9V8"),
    "↵": ("down-left", "M17 7 7 17 M7 8v9h9"),
    "⌄": ("chevron-down", "M6 9l6 6 6-6"),
    "⌃": ("chevron-up", "M6 15l6-6 6 6"),
}


def icon_markup(glyph: str) -> str:
    direction, path = ARROWS[glyph]
    return (
        f'<svg class="icon-arrow icon-arrow--{direction}" '
        'viewBox="0 0 24 24" aria-hidden="true" focusable="false">'
        f'<path d="{path}"/></svg>'
    )


class VisibleTextArrowRewriter(HTMLParser):
    """Collect source-preserving edits only for HTML text nodes, not attributes/code."""

    def __init__(self, source: str):
        super().__init__(convert_charrefs=False)
        self.source = source
        self.line_offsets = [0]
        for match in re.finditer("\n", source):
            self.line_offsets.append(match.end())
        self.protected: list[str] = []
        self.edits: list[tuple[int, int, str]] = []
        self.counts: Counter[str] = Counter()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in PROTECTED_TAGS:
            self.protected.append(tag)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        return

    def handle_endtag(self, tag: str) -> None:
        if tag in PROTECTED_TAGS:
            for index in range(len(self.protected) - 1, -1, -1):
                if self.protected[index] == tag:
                    del self.protected[index:]
                    break

    def handle_data(self, data: str) -> None:
        if self.protected:
            return
        line, column = self.getpos()
        start = self.line_offsets[line - 1] + column
        for offset, glyph in enumerate(data):
            if glyph in ARROWS:
                absolute = start + offset
                self.edits.append((absolute, absolute + 1, icon_markup(glyph)))
                self.counts[glyph] += 1

    def rewritten(self) -> str:
        result = self.source
        for start, end, replacement in reversed(self.edits):
            result = result[:start] + replacement + result[end:]
        return result


def arrow_css() -> str:
    return f"""
{MARKER}
/* Inline SVG arrows keep a consistent shape across font stacks and platforms. */
.icon-arrow {{
  display: inline-block;
  width: 0.95em;
  height: 0.95em;
  flex: 0 0 auto;
  overflow: visible;
  vertical-align: -0.08em;
  color: inherit;
}}
.icon-arrow path {{
  fill: none;
  stroke: currentColor;
  stroke-width: 1.9;
  stroke-linecap: round;
  stroke-linejoin: round;
}}
""".lstrip()


def transform_html(source: str) -> tuple[str, Counter[str]]:
    parser = VisibleTextArrowRewriter(source)
    parser.feed(source)
    parser.close()
    return parser.rewritten(), parser.counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "repo",
        nargs="?",
        default=".",
        type=Path,
        help="repository root (default: current directory)",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="write changes; default is dry run")
    mode.add_argument("--diff", action="store_true", help="print unified diffs without writing")
    args = parser.parse_args()

    root = args.repo.resolve()
    targets = [root / "site" / "index.html", root / "site" / "404.html", root / "site" / "styles.css"]
    missing = [path for path in targets if not path.is_file()]
    if missing:
        print("Error: expected repository files were not found:", file=sys.stderr)
        for path in missing:
            print(f"  {path}", file=sys.stderr)
        print("Run this tool from the scrcpy_vm repository root or pass its path.", file=sys.stderr)
        return 2

    html_updates: dict[Path, tuple[str, str, Counter[str]]] = {}
    for path in targets[:2]:
        old = path.read_text(encoding="utf-8")
        new, counts = transform_html(old)
        html_updates[path] = (old, new, counts)

    css_path = targets[2]
    old_css = css_path.read_text(encoding="utf-8")
    new_css = old_css if MARKER in old_css else old_css.rstrip() + "\n\n" + arrow_css()
    css_changed = new_css != old_css

    total = 0
    for path, (old, new, counts) in html_updates.items():
        amount = sum(counts.values())
        total += amount
        summary = ", ".join(f"{glyph} × {count}" for glyph, count in sorted(counts.items())) or "none"
        print(f"{path.relative_to(root)}: {amount} arrow glyph(s) found ({summary})")
        if args.diff and old != new:
            print("".join(difflib.unified_diff(
                old.splitlines(keepends=True), new.splitlines(keepends=True),
                fromfile=str(path.relative_to(root)), tofile=str(path.relative_to(root)) + " (updated)",
            )))
    print(f"site/styles.css: {'icon styles will be added' if css_changed else 'icon styles already present'}")

    changes = [(path, old, new) for path, (old, new, _) in html_updates.items() if old != new]
    if css_changed:
        changes.append((css_path, old_css, new_css))
    if not changes:
        print("No changes needed; the fix is already applied or no mapped arrow glyphs were found.")
        return 0

    if args.diff:
        if css_changed:
            print("".join(difflib.unified_diff(
                old_css.splitlines(keepends=True), new_css.splitlines(keepends=True),
                fromfile="site/styles.css", tofile="site/styles.css (updated)",
            )))
        return 0

    if not args.apply:
        print("\nDry run only; no files were changed. Add --apply to write the update.")
        return 0

    # Validate all outputs before writing any of them.
    for path, _, new in changes:
        path.write_text(new, encoding="utf-8", newline="")
    print(f"\nApplied {total} arrow replacement(s) and updated {len(changes)} file(s).")
    print("Review with: git diff --check && git diff -- site/index.html site/404.html site/styles.css")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
