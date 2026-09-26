#!/usr/bin/env bash
# Downloads Nicolas Seriot's JSONTestSuite (MIT-licensed), 318 small files
# that say by name whether a strict RFC 8259 parser must accept or reject
# them: docs/json-design-plan.md's slice 1 checks against them, the way
# slice 1 of the Unicode work checked against a full database download.
# They are not committed; run `zig build json-conformance` after fetching.
#
#   bash tools/json/fetch.sh .jsontestsuite
#   zig build json-conformance -Doptimize=ReleaseSafe -- .jsontestsuite/test_parsing
set -euo pipefail

directory="${1:?usage: fetch.sh <directory>}"

# The GitHub REST API and codeload.github.com are scoped to repositories this
# session has added; the plain git smart-HTTP protocol is not, and neither is
# raw.githubusercontent.com, so a shallow clone is what reaches the files.
rm -rf "$directory"
git clone --quiet --depth 1 https://github.com/nst/JSONTestSuite.git "$directory"
echo "JSONTestSuite downloaded to $directory/test_parsing"
