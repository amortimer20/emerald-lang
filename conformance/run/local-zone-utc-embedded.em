# Section 15.8: `TimeZone.local` is UTC for tests and embedded runs, which is how the
# conformance runner runs this program. (The CLI resolves the machine's zone instead.)
print(TimeZone.local.name, TimeZone.local == TimeZone.utc)
