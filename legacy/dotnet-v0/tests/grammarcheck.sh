#!/usr/bin/env bash
# docs/design.html §9 — the grammar, checked against the compiler it describes.
#
# §9 is the one artifact that would show the language growing, and it had quietly
# stopped describing it: enum, assert, break, continue, dictionary literals and the
# unless modifier were all missing, and try_stmt was written down and never wired into
# `statement`. A document nobody can check is a document that stops being true.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$root/tools/grammarcheck.py"
