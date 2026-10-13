"""Generate CHANGELOG.md from Conventional Commits (ROADMAP 17.81).

    pixi run changelog                 # all history -> CHANGELOG.md
    pixi run changelog -- --since v0.1.0 --stdout

Sections are the release tags (newest first) plus "Unreleased" for commits
after the newest tag. Inside a section, commits group by Conventional Commit
type; the older `pkg: subject` form (no type) groups under "Other". Merge
commits are skipped: the merged commits are listed themselves.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# type -> heading, in output order
TYPES = [
    ("feat", "Features"),
    ("fix", "Fixes"),
    ("perf", "Performance"),
    ("refactor", "Refactoring"),
    ("test", "Tests"),
    ("docs", "Documentation"),
    ("build", "Build"),
    ("ci", "CI"),
    ("style", "Style"),
    ("chore", "Chores"),
]
HEADINGS = dict(TYPES)
CC = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]+)\))?(?P<bang>!)?: (?P<desc>.+)$")


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=ROOT, check=True, capture_output=True, text=True, encoding="utf-8"
    ).stdout


def tags_newest_first() -> list[str]:
    out = git("tag", "--list", "v*", "--sort=-creatordate")
    return [t for t in out.splitlines() if t.strip()]


def commits(rev_range: str) -> list[tuple[str, str]]:
    """(short hash, subject) for non-merge commits in `rev_range`."""
    out = git("log", "--no-merges", "--format=%h%x09%s", rev_range)
    rows = []
    for line in out.splitlines():
        h, _, subj = line.partition("\t")
        rows.append((h, subj))
    return rows


def classify(subject: str) -> tuple[str, str]:
    """(heading, rendered line) for one subject."""
    m = CC.match(subject)
    if m and m.group("type") in HEADINGS:
        scope = m.group("scope")
        desc = m.group("desc")
        text = f"**{scope}**: {desc}" if scope else desc
        if m.group("bang"):
            text = "BREAKING: " + text
        return HEADINGS[m.group("type")], text
    return "Other", subject


def render_section(title: str, rows: list[tuple[str, str]]) -> str:
    groups: dict[str, list[str]] = {}
    for h, subj in rows:
        heading, text = classify(subj)
        groups.setdefault(heading, []).append(f"- {text} ({h})")
    order = [h for _, h in TYPES] + ["Other"]
    parts = [f"## {title}\n"]
    for heading in order:
        if heading in groups:
            parts.append(f"### {heading}\n")
            parts.extend(groups[heading])
            parts.append("")
    return "\n".join(parts)


def build(since: str | None) -> str:
    tags = tags_newest_first()
    sections = []
    head = tags[0] + "..HEAD" if tags else "HEAD"
    if since and not tags:
        head = since + "..HEAD"
    rows = commits(head)
    if rows:
        sections.append(render_section("Unreleased", rows))
    for i, tag in enumerate(tags):
        if since and tag == since:
            break
        rng = f"{tags[i + 1]}..{tag}" if i + 1 < len(tags) else tag
        sections.append(render_section(tag, commits(rng)))
    header = (
        "# Changelog\n\n"
        "Generated from Conventional Commit subjects by `scripts/changelog.py`"
        " (`pixi run changelog`); do not edit by hand.\n"
    )
    return header + "\n" + "\n".join(sections)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", help="stop at this tag (exclusive)")
    ap.add_argument("--stdout", action="store_true", help="print instead of writing CHANGELOG.md")
    ap.add_argument("--allow-shallow", action="store_true", help="run on a shallow clone (history is cut off)")
    a = ap.parse_args()
    if git("rev-parse", "--is-shallow-repository").strip() == "true" and not a.allow_shallow:
        print("changelog: shallow clone -- history is incomplete; run `git fetch --unshallow` first", file=sys.stderr)
        return 2
    text = build(a.since)
    if a.stdout:
        sys.stdout.write(text)
    else:
        (ROOT / "CHANGELOG.md").write_text(text, encoding="utf-8")
        print(f"changelog: wrote CHANGELOG.md ({text.count(chr(10))} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
