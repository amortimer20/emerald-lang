# Tasks and channels

Tasks let independent work make progress while other work waits. No `async`, `await`,
threads, or locks appear in an Emerald program. One task runs Emerald code at a time;
this is concurrency, not multicore execution.

Run [`examples/tasks.em`](../../examples/tasks.em):

```text
10 20
total: 6
cleaning up
```

## Tasks.run(body) -> the block's result type

Calls a block with a `TaskGroup`, then waits for every task started through that group,
including children started while it waits. Returns the block's result. Groups may nest;
no child outlives its group. `Tasks`, `Task`, `TaskGroup`, and `Channel` are in the
implicitly imported `Emerald` namespace.

```emerald
Tasks.run { tasks =>
    const first = tasks.start { => 10 }
    const second = tasks.start { => 20 }
    print(first.result(), second.result())
}
```

Print results in the order wanted, rather than printing inside I/O tasks. File, network,
and input completions can arrive in either order. See
[`conformance/run/task-results.em`](../../conformance/run/task-results.em).

**Callback:** the group block runs once. If it or a child fails, remaining children are
cancelled, cleanup runs, and all children are joined before the first failure propagates.
An owner catching a failing child's `result()` has observed that error; the group does not
raise it again. See [`conformance/run/task-errors.em`](../../conformance/run/task-errors.em)
and [`conformance/run/task-group-cancellation.em`](../../conformance/run/task-group-cancellation.em).

## TaskGroup.start(block) -> Task[T]

Starts work whose result type is `T`: `{ => 42 }` returns `Task[Int]`, and a block with
no result returns `Task[Nothing]`. The block is queued; it runs when the current task
waits or yields, not immediately at `start`. Obtain a group from `Tasks.run`; it cannot
start work after that block has finished.

**Callback:** requires an inline `{ => ... }` block, not a stored lambda or named function.
The block and any lambda nested inside it may name outer `const` bindings and parameters,
but may not directly name an outer `var`, including a module-level `var`. Local `var`s
declared inside the task are allowed. Return results or use a channel instead of sharing
a changeable binding. See [`conformance/diagnostics/task-capture.em`](../../conformance/diagnostics/task-capture.em).

**Raises:** `RuntimeError` if more than 64 child tasks would be live at once across the
execution, or if the group has ended. Completed tasks do not count toward the limit.
See [`conformance/runtime-errors/task-limit.em`](../../conformance/runtime-errors/task-limit.em).

## Task[T]

`result() -> T` waits for completion and returns the result, or raises the task's error.
Repeated result calls work after completion, even outside the group. Values retain their
ordinary copy-on-write behavior; class instances remain shared references.
Joined jobs no longer participate in scheduler scans. After the group finishes, the
handle owns its result and error; an unreachable handle and its record can be reclaimed,
including cycles through a returned closure.
See [`conformance/run/task-lifetime.em`](../../conformance/run/task-lifetime.em).

`wait(timeout: Duration) -> Bool` waits at most that duration: `true` means finished,
including a task that failed; call `result()` to obtain its value or error. `false` leaves
the task running. Zero checks without waiting; a negative timeout raises `RuntimeError`
with `a task timeout cannot be negative`. See
[`conformance/run/task-wait.em`](../../conformance/run/task-wait.em).

`done?() -> Bool` checks completion without waiting. Failure and cancellation also count
as completion.

`cancel() -> Nothing` requests cancellation; it does not wait for cleanup to finish.
Cancelling a finished task does nothing. A task notices the request at its next suspension
point and raises `CancelledError`. Deliberately cancelled children alone do not make a
group fail; their `result()` still raises the cancellation. See
[`conformance/run/task-cancellation.em`](../../conformance/run/task-cancellation.em).

## Tasks.yield() -> Nothing

Lets ready tasks run, then resumes when this task reaches the front of the ready queue.
Use it in a long calculation that should let other tasks make progress. There is no
automatic switching in the middle of pure computation. See
[`conformance/run/task-yield.em`](../../conformance/run/task-yield.em).

Task/channel/yield waits have reproducible scheduling for the same program and input:
ready tasks resume in readiness order. Sleeps resume in deadline order; equal deadlines
use waiting order. Real-clock deadlines mean only clearly different sleep lengths have
reliable ordering. Timed waits also depend on the clock. I/O completions resume in arrival
order, which can vary.

## Channel[T](capacity: Int = 0)

Make a channel with an expected message type, for example
`const numbers: Channel[Int] = Channel(capacity: 2)`. Explicit generic construction
`Channel[Int]()` is not supported. The message type is invariant: a `Channel[Int]` is
not a `Channel[Float]`. Channels are shared identities, not copied queues.
The item type cannot itself be optional: `Channel[Int?]` is a checking error. Wrap an
optional value in a struct, so `receive()` can distinguish a message from closure.
See [`conformance/diagnostics/channel-optional.em`](../../conformance/diagnostics/channel-optional.em).

Capacity zero is a rendezvous: a send waits for a receiver. Positive capacity buffers up
to that many messages; senders and receivers wait FIFO. See
[`conformance/run/channel-fifo.em`](../../conformance/run/channel-fifo.em) and
[`conformance/run/channel-backpressure.em`](../../conformance/run/channel-backpressure.em).

`send(value: T) -> Nothing` waits for space or a receiver. Transmitted lists, dictionaries,
strings, and structs retain value semantics; class instances remain shared references.

`receive() -> T?` waits for a message; returns `nothing` once closed and empty.

`close() -> Nothing` is idempotent. Buffered messages remain available; waiting receivers
wake, and uncommitted sends fail. A send already delivered succeeds.

`for item in channel { ... }` receives until closed and empty. A struct message may
contain optional fields; those fields do not collide with the end-of-stream marker.
See [`conformance/run/channel-closed.em`](../../conformance/run/channel-closed.em).

**Raises:** negative capacity raises `RuntimeError` with `a channel capacity cannot be
negative`; sending after closure raises `RuntimeError` with `cannot send to a closed channel`.
Waiting operations can raise `CancelledError` or `DeadlockError`.

## Cancellation, cleanup, and deadlocks

`CancelledError` extends `Error` directly, not `RuntimeError`; catching `RuntimeError`
does not swallow cancellation. `finally` runs and is protected from cancellation, even
when cleanup itself waits. Nested groups cancel and join their children before their
owner's cleanup finishes. Calling `exit()` also cancels and drains active children.

Standard-input waits cancel immediately. The scheduler keeps the in-flight read and
delivers its line to the next input call; program exit never waits for that reader.
HTTP cancellation uses the request's deadline race. Files are not interrupted: cancellation
arrives after the operation returns. Local files normally return promptly, but a named
pipe or device can delay it. Custom embedding readers have no new cancellation hook.

`DeadlockError` extends `RuntimeError`. When no task can progress and no timer or outside
operation can wake one, its diagnostic names the waits and their source locations,
rather than leaving the program hanging. See
[`conformance/runtime-errors/channel-receive-deadlock.em`](../../conformance/runtime-errors/channel-receive-deadlock.em).

## Current limits

There is no multicore execution, detached task, channel `select`, or general user-defined
iteration. Task and channel built-in member completion remains part of the queued editor
intelligence work; hover types and navigation inside task blocks and element annotations work.

Direct capture checking does not follow calls: a task can call a named function that reads
a module `var`, or a function value whose closure captured a `var` elsewhere. These gaps,
and shared class instances, are safe with the single execution baton but must be addressed
before multicore execution. The task limit bounds live threads, not total tasks over a run.
