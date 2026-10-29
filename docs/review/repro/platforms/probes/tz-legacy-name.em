# Run with TZ=GB (or US/Eastern). The built-in database knows the name, but
# TimeZone.local only looks for a system zoneinfo file, which Ubuntu 24.04
# no longer ships for backward names (they moved to tzdata-legacy).
const t = Instant.parse("2026-07-01T12:00:00Z")
print(TimeZone.local, TimeZone.local.offset_at(t), TimeZone("GB").offset_at(t), TimeZone("US/Eastern").offset_at(t))
