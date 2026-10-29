# Review area 4: tasks and cancellation

Scope: `Tasks.run`, `tasks.start`, `Task.result`/`wait`/`cancel`/`done?`, `Channel`
`send`/`receive`/`close`, `Tasks.yield`, `Program.sleep` and `input` inside tasks, deadlock
detection and `exit()`, checked against rewrite-context 15.13 (and 15.2 for `exit`) and
[`docs/library/tasks.md`](../library/tasks.md).

Reviewed at `d580f40` on branch `claude/review-tasks`. Zig 0.17.0. Binaries: Debug (which
runs on the leak-checking debug allocator) and ReleaseSafe, built on macOS (arm64), plus a
ReleaseSafe build of the same source in the Linux container `emerald-review` (aarch64).
The macOS host was heavily loaded by other review work during the runs (load average
around 200-250), which made the timing perturbation larger than usual.

Everything to reproduce this is in [`repro/tasks/`](repro/tasks/):

- `stress.py`: runs a program N times, J at a time, with a 20 s timeout; tallies each
  distinct (exit status, stdout+stderr) and compares with the `.expected` file if there
  is one, otherwise with the most common outcome. A Debug-allocator leak report, a panic,
  or a hang shows up as its own outcome.
- `stdin_stress.py`: the same with a held-open standard-input pipe that writes lines after
  a delay.
- `run-all.sh`: the whole sweep below.
- `edge/e*.em`: 51 edge-case programs written for this review.
- `f0*.em`: one reduced reproduction per finding.

## What was run

| Corpus | Programs | macOS ReleaseSafe | macOS Debug | Linux ReleaseSafe |
| --- | --- | --- | --- | --- |
| Conformance task/channel cases in `run/` and `runtime-errors/`, `examples/tasks.em`, `tools/task-*.em` (8 at once) | 46 | 1,000 each | 200 each | 200 each |
| The same, cases that write fixed file names (serial): `task-file-operations`, `task-file-stream`, `tools/task-io-order-probe` | 3 | 1,000 each | 200 each | 200 each (first two) |
| `run/task-cancel-input-live.em` with a held-open stdin pipe | 1 | 1,000 | 200 | 200 |
| Edge programs `edge/e01`-`e51` without stdin (8 at once) | 46 | 1,000 each | 200 each | 200 each (e01-e49) |
| Edge programs with a held-open stdin pipe (`e32`, `e33`, `e34`, `e43`) | 4 | 1,000 each (e43: 200) | 200 each (e43: 100) | 200 each |
| `edge/e45-throughput.em` (100,000 rendezvous messages), 120 s timeout | 1 | 50 | 20 | 200 |
| `tools/task-benchmark.em` with 100,000 one-task groups / 20,000 in Debug | 1 | 1 | 1 | - |

That is roughly 100,000 ReleaseSafe and 20,000 Debug runs on macOS, and 20,000 on Linux.
HTTP task cases (`conformance/http/task-http*.em`) were not run: they need the in-process
test server that only `zig build test` starts.

Edge programs cover: cancellation at every await point (`result`, `wait(timeout:)`,
`send`, `receive`, `Program.sleep`, `Tasks.yield`, `input`, a group's implicit join);
cancelling done, failed, and never-started tasks; nested groups; a child raising while
siblings and the group block wait on it; channels closed with blocked senders and
receivers, buffered and unbuffered, including at capacity; 5,040 tasks in 80 groups, 64
concurrent sleepers, 62 tasks cancelled together across five wait kinds; the 64-task cap
across nested groups; deadlock cycles through channels and results, in cleanup, and with
no task at all; `exit()` from the group block, from a child, from a child's cleanup, and
while another task is blocked on standard input; result-waiter and channel-waiter order;
and sleep-deadline order.

## Findings, by severity

### F1 (high). `exit(code)` inside a task always exits with status 0

Reproduction: [`repro/tasks/f01-exit-status-lost-in-task.em`](repro/tasks/f01-exit-status-lost-in-task.em);
also `edge/e16`, `e22`, `e43`, `e51`.

```emerald
Tasks.run { tasks =>
    tasks.start { => exit(4) }
}
```

Frequency: every run (1,000 of 1,000 ReleaseSafe, 200 of 200 Debug, macOS and Linux;
`e43`, where the group block is blocked in `input()`, 200 of 200). `exit(5)` from the group
block itself correctly exits 5 (`e23`).

Decisive output: nothing is printed and the process status is `0`.

Spec: 15.2, "`exit(code)` uses a process status from `0` through `255`", and 18.1, "An
explicit `exit(code)` from a running program uses the requested valid code." 15.13: "Program
exit cancels and drains active children."

Cause (for the fixer): `exit` stores the code in `self.task.state.exit_code`
(`Interpreter.zig:4773`), the *child's* task state. The run result is read from the root
task's state (`Interpreter.zig:753`, `:1080`), which never received it.

### F2 (high). `exit()` in a child reaches the group block as a catchable `CancelledError`, and the program keeps running

Reproduction: [`repro/tasks/f02-exit-in-task-caught-as-cancellation.em`](repro/tasks/f02-exit-in-task-caught-as-cancellation.em) (`edge/e37`).

```emerald
Tasks.run { tasks =>
    tasks.start { =>
        Tasks.yield()
        exit(6)
    }
    try {
        Program.sleep(Duration(seconds: 30))
    }
    catch error: CancelledError {
        print("main caught cancellation after exit()")
    }
    print("main still running after exit()")
}
```

Frequency: every run, macOS and Linux.

Decisive output (status 0, see F1):

```text
main caught cancellation after exit()
main still running after exit()
```

Spec: 15.2, "`exit` unwinds pending `finally` blocks but is not caught as an error."
After `exit()`, only `finally` blocks should run. Here the child's exit is treated as a
child failure (`taskMain` stores `error.Exited` in `task.ended` and calls `cancelGroup`, `Interpreter.zig:4222-4227`),
so the group block receives an ordinary cancellation, can catch it, and runs arbitrary
code (it could print, start more work, or wait) before the group finally re-raises the exit.

### F3 (high). `exit()` called during a failing group's drain is discarded; the earlier failure is reported instead

Reproduction: [`repro/tasks/f03-exit-in-cleanup-overridden.em`](repro/tasks/f03-exit-in-cleanup-overridden.em) (`edge/e38`).

```emerald
Tasks.run { tasks =>
    tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 30))
        }
        finally {
            print("cleanup exits")
            exit(7)
        }
    }
    tasks.start { =>
        Tasks.yield()
        raise AssertionError("trigger")
    }
}
```

Frequency: every run, macOS and Linux.

Decisive output (status 2):

```text
cleanup exits
f03-exit-in-cleanup-overridden.em:15:9: AssertionError: trigger
```

Spec: 15.2, `exit(code)` uses the requested code and "is not caught as an error"; it should
end the program with status 7. The group keeps only its "first failure" (`first_error`), and
a sibling's `Exited` from cleanup is not a failure, so it is dropped.

### F4 (high). A cancelled receiver silently loses a message whose send already succeeded

Reproduction: [`repro/tasks/f04-cancelled-receiver-loses-message.em`](repro/tasks/f04-cancelled-receiver-loses-message.em)
(`edge/e01`; buffered variant `edge/e44`).

```emerald
const numbers: Channel[Int] = Channel()
Tasks.run { tasks =>
    const receiver = tasks.start { => numbers.receive() }
    Tasks.yield()
    numbers.send(42)        # returns normally: handed straight to the parked receiver
    receiver.cancel()       # before the receiver has resumed
    try {
        print("received: #{receiver.result()}")
    }
    catch error: CancelledError {
        print("receiver cancelled; message 42 was sent but nobody received it")
    }
}
```

Frequency: every run (1,000 of 1,000 ReleaseSafe, 200 of 200 Debug, Linux 200 of 200). The
buffered variant `e44` (`Channel(capacity: 4)`) also loses it: after `close()` the channel is
empty (`left in channel: nothing`). `edge/e31` shows it at scale: when 13 senders pair with
13 parked receivers and all are then cancelled, all 13 messages per round are lost.

Decisive output: `receiver cancelled; message 42 was sent but nobody received it`.

Spec: 15.13 makes channels FIFO with committed sends ("sends not already committed raise");
the library reference says "A send already delivered succeeds." A delivered message must
either reach the receiver or not count as sent. Here the sender sees success and the value is
released: `receiveChannel` -> `waitChannel` runs `cancellationPoint` after `parkChannel`
before checking `waiter.delivered`, and the `defer` releases `waiter.value`
(`Interpreter.zig:4548-4550`, `:4619-4622`). This is the same race the conformance case
`run/task-cancel-send.em` ("no lost message") guards on the sending side.

### F5 (medium). A sender whose value was already delivered still raises `CancelledError`

Reproduction: [`repro/tasks/f05-delivered-send-raises-cancelled.em`](repro/tasks/f05-delivered-send-raises-cancelled.em) (`edge/e02`).

A parked rendezvous sender's value is taken by `receive()`, then the sender is cancelled
before it resumes.

Frequency: every run, macOS and Linux.

Decisive output:

```text
main received: 7
sender cancelled after its value was delivered
```

The `print("sender: send returned")` after `send` never runs, although the value arrived.

Spec: the library reference, "`close()` ... uncommitted sends fail. A send already delivered
succeeds." 15.13 uses the same commit rule. A cancelled task that reacts to the cancellation
by retrying or compensating will duplicate a message it did deliver. `sendChannel` checks
`waiter.delivered` only after `waitChannel`'s second `cancellationPoint` (`Interpreter.zig:4580-4581`).
This is the mirror image of F4; one fix (check delivery before raising) likely covers both.

### F6 (high). A sibling that observes the failing child in its cleanup turns the group's failure into `CancelledError`

Reproduction: [`repro/tasks/f06-sibling-observation-turns-failure-into-cancel.em`](repro/tasks/f06-sibling-observation-turns-failure-into-cancel.em) (`edge/e35`).

```emerald
try {
    Tasks.run { tasks =>
        const failing = tasks.start { =>
            Tasks.yield()
            raise AssertionError("child failed")
        }
        tasks.start { =>
            try {
                Program.sleep(Duration(seconds: 30))
            }
            finally {
                try {
                    failing.result()
                }
                catch error: AssertionError {
                    print("sibling observed: #{error.message}")
                }
            }
        }
    }
    print("group returned normally")
}
catch error: AssertionError {
    print("group raised: #{error.message}")
}
```

Frequency: every run, macOS and Linux.

Decisive output (status 2, uncaught):

```text
sibling observed: child failed
f06-sibling-observation-turns-failure-into-cancel.em:4:5: CancelledError: this task was cancelled
      Tasks.run { tasks =>
```

Spec: 15.13, "A failing child cancels its siblings and the group's block, then the group
joins all children and propagates its first failure once. An *owner* catching the failing
child's `result()` observes that failure, so draining does not raise it again." Here the
observer is a sibling, not the owner, so the group should raise `AssertionError: child
failed` (caught by the program's handler). Instead the program dies with a `CancelledError`
that nobody requested. `propagateTaskError` marks `observed_error` for any caller
(`Interpreter.zig:4252`), and the drain then falls through to the owner's own cancellation.

### F7 (low, spec gap). A task cancelled before it ever ran executes its whole body and returns normally

Reproduction: [`repro/tasks/f07-cancelled-unstarted-task-completes.em`](repro/tasks/f07-cancelled-unstarted-task-completes.em) (`edge/e07`).

```emerald
Tasks.run { tasks =>
    const queued = tasks.start { =>
        print("queued task body ran")
        return 1
    }
    queued.cancel()
    print(queued.done?())
    ...
    print(queued.result())   # prints 1, no CancelledError
}
```

Frequency: every run. Output: `false`, `queued task body ran`, `1`, `finished`.

This is consistent with the letter of 15.13 ("cooperative cancellation at the next
suspension point"; the body never suspends), but surprising next to the library's
"Deliberately cancelled children ... their `result()` still raises the cancellation" and
the group rule that new children of a cancelling group are cancelled at start. A body with
side effects but no wait runs in full after `cancel()`. The spec should say which is meant;
no conformance case covers a cancel before first run.

## Not findings

- `run/channel-local-shadow.em` differs from its `.expected` under the CLI in every run, only
  because `emerald run` also prints the snake_case *warning* (and exits 1, per 17.1); the
  conformance runner ignores warnings. Not task-related.
- `tools/task-io-order-probe.em` prints `a b` or `b a` (729/271 of 1,000): by design, it is
  the documented I/O-arrival nondeterminism.
- `edge/e28-sleep-order.em`: under load average ~250, a 10 ms sleep started before five
  1 ms sleeps sometimes finished first (10 of 1,000). Each task computes its deadline when it
  runs, so with a starved host these are not "clearly different" deadlines; deadline order was
  never violated (30/50/70/90 ms and the 1 ms group never reordered among themselves).
- Throughput of a rendezvous channel was latency-bound under host load (100,000 messages in
  3-13 s wall clock, 0.2 s CPU). Each hand-off is an OS-thread condition-variable switch.
  Not a hang: with the default 20 s timeout, 48 of 50 macOS runs timed out while the
  Debug sweep ran alongside; with 120 s, 50 of 50 (and 20 of 20 Debug, 200 of 200 Linux)
  finished correctly, each in about 10 s with 8 at once. Noted for a future fiber backend.

## What came out clean

Across all runs above, on both platforms: no crash, panic, assertion, Debug-allocator leak
report, or timeout in any program, and every conformance task/channel case matched its
`.expected` output in every run. In particular:

- Cancellation at `result`, `wait(timeout:)`, `send`, `receive`, `Program.sleep`,
  `Tasks.yield`, `input`, and a nested group's implicit join raises `CancelledError` and
  runs `finally` (`e03`-`e05`, `e25`, conformance). Cancellation requested during a
  normally-running `finally` is delivered at the next wait (`e26`). Very long sleeps
  (`Int` max seconds) cancel cleanly (`e47`, `e48`).
- Cancelling a done or failed task does nothing; `result()` keeps returning its value or
  error (`e06`).
- Nested groups: cancelling a parent cancels and joins its children before its own cleanup
  finishes (`e08`, `e25`).
- A child failing while others wait on it, or while the block waits on a channel: siblings
  and the block are cancelled, and the first failure propagates once (`e09`, `e19`, `e27`,
  `e46`).
- `close()` with blocked senders and receivers, unbuffered and buffered at capacity:
  delivered sends succeed, the rest raise `cannot send to a closed channel`, receivers get
  `nothing`, buffered items remain (`e10`, `e11`).
- 5,040 tasks in 80 groups; 64 concurrent sleepers; 1,240 mass cancellations; 100,000
  one-task groups (RSS ~8.6 MB). The 64-task cap holds across nested groups and frees up as
  tasks complete (`e12`, `e13`, `e30`, `e31`, `e39`).
- Deadlock detection: two-channel cycles, result/channel three-party cycles, cleanup that
  blocks forever, and channel waits with no task at all all raise `DeadlockError` naming each
  wait and its source line; a pending timed wait is correctly not a deadlock (`e14`, `e15`,
  `e18`, `e24`, `e40`-`e42`).
- Ordering: result waiters and channel receivers resume in waiting order, and interleaved
  yields/channels between tasks and the main program printed identically in every run
  (`e17`, `e49`, conformance).
- Standard input: cancellation interrupts a blocked read immediately, its line goes to the
  next `input()` call, two concurrent readers get lines in order, and `exit()` with a task
  blocked on a held-open pipe returns at once without joining the reader (`e32`-`e34`,
  `task-cancel-input-live`).
- `exit()` from the group block cancels and drains children and keeps its status (`e23`);
  `exit()` while a child's cleanup would block forever still exits with its status (`e50`).
