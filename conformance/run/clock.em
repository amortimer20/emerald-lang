# Section 15.8's clocks. The time is different on every run, so this checks
# only how readings relate to each other.
const now = Instant.now()
print(now > Instant.parse("2026-01-01T00:00:00Z"), Instant.now() >= now)

# A Stopwatch reads the monotonic clock; Program.sleep pauses the program.
const watch = Stopwatch.start()
Program.sleep(Duration(milliseconds: 20))
const taken = watch.elapsed()
print(taken >= Duration(milliseconds: 20), taken < Duration(seconds: 30))
watch.restart()
print(watch.elapsed() < taken, watch.elapsed().negative?())
Program.sleep(Duration())
print("#{watch}".starts_with?("Stopwatch("))
