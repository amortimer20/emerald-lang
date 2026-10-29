#!/bin/sh
# For every zone file under the system's zoneinfo, runs local-vs-named.em
# with TZ set to that zone's name and prints only the zones where the
# system's rules and Emerald's built-in rules disagree.
#   sh sweep-zones.sh EMERALD PROBE ZONEINFO_DIR
EM=$1; PROBE=$2; DIR=$3
cd "$DIR" && find . -type f ! -name '*.tab' ! -name '+VERSION' ! -name '*.zi' ! -name 'leap*' ! -name 'tzdata*' ! -name '*.list' | sed 's|^\./||' | sort | while read -r zone; do
  case "$zone" in posix/*|right/*|posixrules|Factory|SECURITY|iso3166.tab|zone.tab) continue;; esac
  TZ="$zone" "$EM" run "$PROBE" -- "$zone" 2>&1
done | tee "${TMPDIR:-/tmp}/zone-sweep.all" | grep -v "differences: 0 *$"
echo "zones checked: $(wc -l < "${TMPDIR:-/tmp}/zone-sweep.all")"
