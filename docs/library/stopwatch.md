# Stopwatch

A `Stopwatch` measures how long something takes. It reads the machine's monotonic clock,
which only moves forward, so a change to the system clock partway through cannot make a
measurement wrong or negative. Run [`conformance/run/clock.em`](../../conformance/run/clock.em).

```emerald
const watch = Stopwatch.start()
var total = 0
for number in 1..100000 {
    total += number
}
print("Added up to #{total} in #{watch.elapsed()}")   # for example, Added up to 5000050000 in 0.03s
```

A `Stopwatch` is a class rather than a value, since it is a running thing: `Stopwatch()` is
an error that points to `Stopwatch.start()`.

## Stopwatch.start() -> Stopwatch

A stopwatch that starts now.

## elapsed() -> Duration

The time since the stopwatch started or last restarted, read fresh each call. It is a method
rather than a property because its answer changes on its own.

## restart() -> Nothing

Starts measuring again from now.

## Display

`Stopwatch(1.25s)`, showing the elapsed time.

To pause a program rather than measure it, see `Program.sleep` on the
[`Program`](program.md) page.
