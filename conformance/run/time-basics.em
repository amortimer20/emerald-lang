# Section 15.8's Time: a time on the clock with no date or zone.
const alarm = Time(7, 30)
print(alarm, Time(0), Time(23, 59, 59, 999999999))
print(alarm.hour, alarm.minute, alarm.second, alarm.nanosecond)

# A fraction of a second shows only when there is one, in groups of three.
print(Time(14, 30, 0, 250000000), Time(1, 2, 3, 4000), Time(1, 2, 3, 5))

# Moving a Time wraps around midnight.
print(Time(23, 0).add(hours: 2), Time(0, 15).subtract(minutes: 30), alarm.add(hours: 48))
print(alarm.add(milliseconds: 1500), alarm.subtract(nanoseconds: 1))

# Values: ordered, compared, and usable as dictionary keys.
print(alarm < Time(8), [Time(12), Time(9, 5)].sort(), [alarm: "wake"][Time(7, 30, 0)])

# HH:MM, HH:MM:SS, or HH:MM:SS.fraction, and what a Time prints reads back.
print(Time.parse("07:30") == alarm, Time.parse("14:30:05.25"), Time.parse(" 00:00:00.000000001 "))
print(Time.parse(Time(1, 2, 3, 4000).to_string()) == Time(1, 2, 3, 4000))
print(Time.parse_maybe("24:00"), Time.parse_maybe("7:30"), Time.parse_maybe("07:30:00."))
