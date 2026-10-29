# Finding Z2. TimeZone.local takes its name from whatever follows the last
# "zoneinfo/" in the TZ path or /etc/localtime's link, unnormalized.
# Run with TZ=/usr/share/zoneinfo//Europe/London on Linux or macOS.
print(TimeZone.local, TimeZone.local == TimeZone("Europe/London"))
