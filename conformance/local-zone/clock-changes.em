# Section 15.8's local zone, here EST5EDT: five hours behind UTC in winter and
# four in summer. In 2026, clocks go forward at 02:00 on 8 March and back at
# 02:00 on 1 November.
const zone = TimeZone.local
print(zone, zone.offset_at(Instant.parse("2026-01-15T12:00:00Z")), zone.offset_at(Instant.parse("2026-07-15T12:00:00Z")))
print(TimeZone("EST5EDT") == zone, TimeZone.utc == zone)

# Conversions use the local zone unless told otherwise.
const launch = DateTime(2026, 7, 4, 12)
print(launch.to_instant(), launch.to_instant(TimeZone.utc), launch.to_instant().to_date_time())
print(Instant.parse("2026-12-25T00:00:00Z").to_date_time(), Instant.parse("2026-12-25T00:00:00Z").to_date_time(TimeZone.utc))

# Going forward: 01:59:59 is followed by 03:00:00, and 02:30 never happens.
const forward = Instant.parse("2026-03-08T06:59:59Z")
print(forward.to_date_time(), (forward + Duration(seconds: 1)).to_date_time())
print(DateTime(2026, 3, 8, 2, 30).to_instant(), DateTime(2026, 3, 8, 2, 30).to_instant().to_date_time())

# Going back: 01:30 happens twice, and a wall-clock time means the earlier.
const back = Instant.parse("2026-11-01T05:30:00Z")
print(back.to_date_time(), (back + Duration(hours: 1)).to_date_time())
print(DateTime(2026, 11, 1, 1, 30).to_instant(), DateTime(2026, 11, 1, 1, 30).to_instant() == back)

# A day on the calendar is not always 24 hours of clock time.
const saturday = DateTime(2026, 3, 7, 12)
const sunday = saturday.add(days: 1)
print(sunday.to_instant() - saturday.to_instant(), saturday.duration_until(sunday))
print((saturday.to_instant() + Duration(days: 1)).to_date_time())

# Today and now read the machine's clock, so only their agreement is checked,
# allowing for midnight passing between the two readings.
const earlier = DateTime.now().date
const today = Date.today()
print(today == earlier or today == earlier.add(days: 1))
print(Time.now(TimeZone.utc) <= Time(23, 59, 59, 999999999))
