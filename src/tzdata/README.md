# Built-in time-zone data

Emerald carries its own copy of the IANA time zone database, so that a named zone such as
`TimeZone("America/New_York")` gives the same answer on every operating system, Windows
included (rewrite-context 15.8). Both files here are generated; do not edit them by hand.

| File | Contents |
| --- | --- |
| `zones.zlib` | Every IANA zone's compiled TZif file, stored once per distinct file behind a sorted name index, zlib-compressed. `src/TimeZone.zig` decompresses it the first time a program names a zone. |
| `tzdata.zig` | The IANA release number, and CLDR's IANA name for each Windows zone key name, which the local zone uses on Windows. |

## Updating

```bash
python3 tools/update-tzdata.py
zig build test
```

The script downloads the latest `tzdata` release from PyPI (IANA's own releases, compiled by
`zic` and published by the Python project) and CLDR's `windowsZones.xml` from the
`unicode-org/cldr` repository. `--wheel` and `--windows-zones` read local copies instead.
Only Python's standard library is needed, and the same inputs always produce the same files.
`zig build test` checks that the data loads, that known historical and future offsets come
out right, and that every Windows name maps to a zone the database has. IANA publishes
several releases a year; updating before each Emerald release keeps recent rule changes.

## Sources and terms

- **IANA time zone database**, release recorded in `tzdata.zig`. Public domain.
  <https://www.iana.org/time-zones>
- **Unicode CLDR `windowsZones.xml`** (the Windows-to-IANA names only). Copyright © 1991-2013
  Unicode, Inc. CLDR data files are interpreted according to the LDML specification
  (<http://unicode.org/reports/tr35/>). For terms of use, see
  <http://www.unicode.org/copyright.html>.
