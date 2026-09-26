#!/usr/bin/env bash
# Downloads the Unicode Character Database files Emerald's tables are built
# from. Section 19.1: the tables are regenerated deliberately, never implicitly.
#
#   bash tools/unicode/fetch.sh 17.0.0 .unicode/17.0.0
#   zig run tools/unicode/generate.zig -- 17.0.0 .unicode/17.0.0 > src/unicode/tables.zig
#   zig fmt src/unicode/tables.zig
#   zig build unicode-conformance -Doptimize=ReleaseSafe -- .unicode/17.0.0
#
# Then refresh src/unicode/test/ from the same download (see its header lines),
# run `zig build test`, and record the new version in docs/rewrite-context.md.
set -euo pipefail

version="${1:?usage: fetch.sh <unicode version> <directory>}"
directory="${2:?usage: fetch.sh <unicode version> <directory>}"
# UCD_BASE overrides the source, for machines that cannot reach unicode.org:
# Unicode's own tools repository serves the same files, for example
#   UCD_BASE=https://raw.githubusercontent.com/unicode-org/unicodetools/main/unicodetools/data/ucd/17.0.0
base="${UCD_BASE:-https://www.unicode.org/Public/${version}/ucd}"

mkdir -p "$directory"
for file in \
    UnicodeData.txt \
    DerivedCoreProperties.txt \
    DerivedNormalizationProps.txt \
    PropList.txt \
    SpecialCasing.txt \
    CaseFolding.txt \
    NormalizationTest.txt \
    auxiliary/GraphemeBreakProperty.txt \
    auxiliary/GraphemeBreakTest.txt \
    emoji/emoji-data.txt
do
    curl --fail --silent --show-error --output "$directory/$(basename "$file")" "$base/$file"
done
echo "Unicode $version database downloaded to $directory"
