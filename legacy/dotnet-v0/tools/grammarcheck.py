#!/usr/bin/env python3
"""Checks §9's grammar against the compiler, so the one page that would show the
language growing cannot quietly stop describing it.

Three questions, all cheap:

  * does every keyword the scanner knows appear in the grammar?
  * is every production it mentions defined?
  * is every production it defines reachable from `file`?

The third is what caught try_stmt, which had been written down and never wired into
`statement` — a rule the parser had and the grammar could not reach.
"""
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Terminals the grammar names but does not define. Each is a lexical class, described
# in §9.1 rather than spelled out in productions.
TERMINALS = {"Ident", "Keyword", "NEWLINE", "Number", "String", "digits"}


def grammar_text() -> str:
    page = (ROOT / "docs" / "design.html").read_text(encoding="utf-8")
    start = page.index("file            = block_free_file")
    end = page.index("</pre>", start)
    return html.unescape(page[start:end])


def productions(text: str) -> dict[str, str]:
    """Name to right-hand side. A continuation line begins with whitespace."""
    found: dict[str, str] = {}
    name = None
    for line in text.splitlines():
        # Per line, before continuations are joined: a trailing comment would otherwise
        # swallow every alternative written underneath it.
        line = re.sub(r"--.*$", "", line)
        head = re.match(r"^(\w+)\s*=\s*(.*)$", line)
        if head:
            name = head.group(1)
            found[name] = head.group(2)
        elif name and line.strip():
            found[name] += " " + line.strip()
    return found


def referenced(rhs: str) -> set[str]:
    """Bare words on a right-hand side, with quoted terminals and comments removed."""
    rhs = re.sub(r"--.*$", "", rhs)
    rhs = re.sub(r'"[^"]*"', " ", rhs)
    return set(re.findall(r"\b[A-Za-z_]\w*\b", rhs))


def keywords() -> set[str]:
    source = (ROOT / "src" / "Emerald" / "Scanner.cs").read_text(encoding="utf-8")
    block = source[source.index("Keywords"):]
    block = block[:block.index("};")]
    return set(re.findall(r'"([a-z_?]+)"', block))


def main() -> int:
    text = grammar_text()
    rules = productions(text)
    problems: list[str] = []

    # Every keyword has to appear somewhere a reader can find it. §9.1 is a legitimate
    # home for the ones that are lexical rather than syntactic.
    page = (ROOT / "docs" / "design.html").read_text(encoding="utf-8")
    notes = html.unescape(page[page.index("9.1</span>"):])
    for word in sorted(keywords()):
        if f'"{word}"' not in text and f"<code>{word}</code>" not in notes:
            problems.append(f"keyword not in the grammar: {word}")

    # Every name used has to be defined, or be a declared terminal.
    for name, rhs in sorted(rules.items()):
        for used in sorted(referenced(rhs)):
            if used not in rules and used not in TERMINALS:
                problems.append(f"{name} mentions {used}, which nothing defines")

    # And every rule has to be reachable from the start symbol.
    reachable, edge = set(), ["file"]
    while edge:
        current = edge.pop()
        if current in reachable or current not in rules:
            continue
        reachable.add(current)
        edge.extend(referenced(rules[current]))

    for name in sorted(set(rules) - reachable):
        problems.append(f"{name} is defined but nothing reaches it")

    for problem in problems:
        print(f"  {problem}")

    print()
    print(f"{len(rules)} productions, {len(keywords())} keywords, "
          + ("no problems" if not problems else f"{len(problems)} problem(s)"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
