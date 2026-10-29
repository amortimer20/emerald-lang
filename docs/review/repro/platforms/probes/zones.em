# Probe: local zone and named zones around DST edges, past and far future.
const local = TimeZone.local
print("local:", local)
const moments = ["1883-11-18T17:00:00Z", "1970-01-01T00:00:00Z", "2007-03-11T06:59:59Z", "2007-03-11T07:00:00Z", "2026-03-08T06:59:59Z", "2026-03-08T07:00:00Z", "2026-03-29T00:59:59Z", "2026-03-29T01:00:00Z", "2026-10-25T00:59:59Z", "2026-10-25T01:00:00Z", "2026-11-01T05:59:59Z", "2026-11-01T06:00:00Z", "2037-11-01T06:00:00Z", "2038-01-19T03:14:08Z", "2050-07-01T00:00:00Z", "2100-03-14T07:00:00Z", "2100-07-01T00:00:00Z", "2500-07-01T00:00:00Z"]
const zones = [local, TimeZone("America/New_York"), TimeZone("Europe/London"), TimeZone("Australia/Lord_Howe"), TimeZone("Asia/Kolkata"), TimeZone("America/Sao_Paulo"), TimeZone("Africa/Casablanca"), TimeZone("Pacific/Apia"), TimeZone("EST5EDT"), TimeZone("US/Eastern")]
for text in moments {
    const instant = Instant.parse(text)
    var line = text
    for zone in zones {
        line = line + " | " + instant.to_date_time(zone).to_string() + " " + zone.offset_at(instant).to_string()
    }
    print(line)
}
print(DateTime(2026, 3, 8, 2, 30).to_instant(), DateTime(2026, 11, 1, 1, 30).to_instant(), DateTime(2100, 7, 1, 12).to_instant())
print(local == TimeZone("America/New_York"), local == TimeZone.utc)
