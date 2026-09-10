# -*- coding: utf-8 -*-
"""Runs every snippet in docs/tour.html and compares it against the output printed beside it.

The tour claims every program on the page was run by the compiler before the page was
written. That was true when written and nothing kept it true: a language change reaches
the .em corpus through the test suite and reaches the tour only through somebody
remembering. This is the thing that remembers.

Two of the page's conventions have to be understood to run it the way a reader reads it:

  * a snippet whose first line is `# name.em` is one file of a multi-file program, and the
    files of a section belong to one project
  * a snippet can continue the one above it, using what it declared

So a section is run as a whole, once, and its output is compared against every "prints"
block in it joined together -- which is what a reader would see typing the page in. A
snippet with no output beside it is a fragment being discussed rather than a claim about
behavior; those are counted so the skips stay visible.

    python3 tools/tourcheck.py            check
    python3 tools/tourcheck.py --list     name every section and what it ran
"""
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGE = os.path.join(ROOT, "docs", "tour.html")
DLL = os.path.join(ROOT, "src", "Emerald", "bin", "Debug", "net10.0", "Emerald.dll")

UNIT = re.compile(
    r'<pre class="code">(?P<code>.*?)</pre>(?P<between>.*?)(?=<pre class="code">|<h2|\Z)',
    re.S)

# Only a "prints" block is a claim about what a program does. The others on the page are
# transcripts of the tools -- emerald fmt, explain, test, the repl -- which have their own
# suites and are not programs to run.
OUT = re.compile(
    r'<div class="out"><span class="lab">prints</span><pre>(?P<out>.*?)</pre>', re.S)

# A snippet shown with a diagnostic is a program that is meant to fail. It is checked on
# its own and kept out of its section's program, which it would otherwise break -- which
# is exactly what it is on the page to do.
DIAG = re.compile(
    r'<div class="diag"><span class="lab">emerald run</span><pre>(?P<out>.*?)</pre>', re.S)
SECTION = re.compile(r'<h2><span class="n">(\d+)</span>\s*([^<]*)</h2>')
FILENAME = re.compile(r'^#\s*(\w+\.em)\b')


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def sections():
    """The page grouped into sections, each a list of (code, expected-or-None)."""
    page = read(PAGE)
    marks = [(m.start(), "%s %s" % (m.group(1), m.group(2).strip()))
             for m in SECTION.finditer(page)]

    grouped = {}
    order = []
    for m in UNIT.finditer(page):
        name = "0 preamble"
        for start, title in marks:
            if start < m.start():
                name = title
        if name not in grouped:
            grouped[name] = []
            order.append(name)
        out = OUT.search(m.group("between"))
        diag = DIAG.search(m.group("between"))
        grouped[name].append((
            html.unescape(m.group("code")),
            html.unescape(out.group("out")) if out else None,
            html.unescape(diag.group("out")) if diag else None))

    return [(name, grouped[name]) for name in order]


def project(snippets):
    """The files a section describes, and the output they should produce together."""
    files = {}
    main = []
    wanted = []

    for code, expected, failing in snippets:
        if failing is not None:
            continue
        named = FILENAME.match(code.strip())
        if named:
            files[named.group(1)] = code
        else:
            main.append(code)
        if expected is not None:
            wanted.append(expected.strip())

    if main:
        files.setdefault("main.em", "")
        files["main.em"] = "\n".join(main)

    return files, "\n".join(w for w in wanted if w)


def run(files):
    box = tempfile.mkdtemp()
    try:
        for name, code in files.items():
            with open(os.path.join(box, name), "w", encoding="utf-8", newline="\n") as f:
                f.write(code if code.endswith("\n") else code + "\n")
        entry = os.path.join(box, "main.em" if "main.em" in files else list(files)[0])
        # One stream, so a warning printed before the program runs stays before the
        # program's own output. Concatenating them put every diagnostic last.
        done = subprocess.run(["dotnet", DLL, "run", entry],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, cwd=box)
        return trim(done.stdout.replace("\r\n", "\n").strip())
    finally:
        shutil.rmtree(box, ignore_errors=True)


def trim(output):
    """Drops a trailing `emerald explain` offer, so both sides are compared without it.

    The page carries it on some transcripts and not others, which is a choice about the
    page rather than about the compiler -- so it is removed from the expected text too,
    and neither side can fail on it.
    """
    lines = output.split("\n")
    while lines and (not lines[-1].strip() or lines[-1].strip().startswith("emerald explain")):
        lines.pop()
    return "\n".join(lines)


def diff(want, got):
    want_lines, got_lines = want.split("\n"), got.split("\n")
    for i in range(max(len(want_lines), len(got_lines))):
        w = want_lines[i] if i < len(want_lines) else "(nothing)"
        g = got_lines[i] if i < len(got_lines) else "(nothing)"
        if w != g:
            yield "page says: " + w
            yield "ran as:    " + g


def main():
    listing = "--list" in sys.argv
    checked = skipped = bad = 0

    for name, snippets in sections():
        # the programs the page shows failing, each on its own
        for code, _, failing in snippets:
            if failing is None:
                continue
            checked += 1
            actual = run({"main.em": code})
            if actual == trim(failing.strip()):
                if listing:
                    print("  OK     %-38s (shown failing)" % name)
                continue
            bad += 1
            print("FAIL   %s   (shown failing)" % name)
            for line in diff(trim(failing.strip()), actual):
                print("         " + line)

        files, wanted = project(snippets)
        if not wanted:
            skipped += sum(1 for _, _, failing in snippets if failing is None)
            if listing:
                print("  skip   %-38s %d fragment(s)" % (name, len(snippets)))
            continue

        checked += 1
        actual = run(files)
        if actual == wanted:
            if listing:
                print("  OK     %-38s %s" % (name, ", ".join(sorted(files))))
            continue

        bad += 1
        print("FAIL   %s" % name)
        for line in diff(wanted, actual):
            print("         " + line)

    print()
    print("%d section(s) checked, %d failed, %d fragment(s) skipped"
          % (checked, bad, skipped))
    return 1 if bad else 0


sys.exit(main())
