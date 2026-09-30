# Concurrency: design and implementation plan

Status: accepted, 2026-09-29. The user answered "I'll trust your judgement" to the design
discussion, which is taken as accepting all nine recommendations below; if that was not meant,
the status goes back to proposed. All six slices are implemented and locally validated.
Review and green Windows PR CI remain required before the milestone is fully done.
The user accepted the scheduling clarification in principle 5 on 2026-09-29.
Rewrite-context 21 calls
concurrency "the nearest major post-runtime design pass" and says that until it is done,
"Emerald callbacks obey the single-threaded language model". 15.7 says the same of "threads,
fibers, and any other concurrency primitive". The user's notes list *concurrency* and
*multicore processing* as separate big features. This plan is the first: tasks that make
progress independently and wait for each other. It keeps the second possible, and does not
design it (see "Later: multicore").

The executor makes the remaining judgement calls within a slice and records each one under that
slice's "Settled while building" note. At the start of each slice, reread `git status`, the
recent `git log`, and docs/handoff.md.

## What beginner programs need

Each of these should read naturally, and a mistake in one should say what went wrong and where.

```emerald
# Fetch two pages at the same time, and wait for both.
Tasks.run { tasks =>
    const weather = tasks.start { => Http.get("https://api.example.com/weather").text }
    const news = tasks.start { => Http.get("https://api.example.com/news").text }
    print(weather.result())
    print(news.result())
}
```

The requests may finish in either order. Printing from their results in the order wanted
keeps the output fixed: weather first, then news. Printing from inside the tasks would show
the order in which the network replies arrived, which can vary. A channel can also arrange
the order in which results are printed.

```emerald
# One task makes numbers and another uses them, through a channel.
const numbers: Channel[Int] = Channel(capacity: 3)
Tasks.run { tasks =>
    tasks.start { =>
        for n in 1..5 {
            numbers.send(n)
        }
        numbers.close()
    }
    tasks.start { =>
        for n in numbers {
            print("got #{n}")
        }
    }
}
```

```emerald
# Give up on a slow task. Its cleanup still runs.
Tasks.run { tasks =>
    const slow = tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 60))
            return "finished"
        }
        finally {
            print("cleaning up")
        }
    }
    Program.sleep(Duration(seconds: 1))
    slow.cancel()
}
```

That prints `cleaning up` after about a second and returns, rather than waiting a minute.

Before implementation these were checked with `emerald format`; `Channel[Int]` and the
task/channel names needed the additions in slices 2 and 4. They are now implemented.
A block that takes nothing is written `{ => ... }`, and one that takes a value is
`{ tasks => ... }`.

Waiting a limited time for a task, and giving up on it, reads:

```emerald
Tasks.run { tasks =>
    const download = tasks.start { => Http.get("https://example.com/big").text }
    if download.wait(Duration(seconds: 5)) {
        print(download.result())
    }
    else {
        print("too slow")
        download.cancel()
    }
}
```

## Principles

1. **Tasks and channels, not threads and locks.** A student learns "do these things at the
   same time, and pass results through a channel". There is no lock, no mutex, no atomic, and no
   thread identity to teach.
2. **No function coloring.** There is no `async`/`await`. Any function may wait for a task or a
   channel, and the caller does not have to know. This is what lets a beginner move a
   sequential program into a task without rewriting its functions.
3. **A task cannot corrupt another.** A task's block may not capture a `var`, so tasks share
   only values they were given and channels. This is checked before the program runs, with a
   diagnostic that names the variable and the fix.
4. **Structured.** A task can only be started inside a `Tasks.run` block, which does not return
   until every task it started has finished. No task is left running, and no task's error goes
   unseen.
5. **Defined scheduling order.** When tasks wait only on each other (`result`, `wait`), on
   channels, or on `Tasks.yield()`, the same program with the same input produces the same
   output every time. Ready tasks resume in the order they became ready.
   A task whose sleep ends earlier resumes earlier; sleeps that end at the same moment
   resume in the order the tasks started waiting. Deadlines come from the real clock, so
   only sleeps of clearly different lengths have a reliable order. A timed `wait` that
   expires also involves a real-clock deadline.
   File, network, and input completions resume their tasks in the order they arrive, which
   can vary from run to run. To print in a fixed order, print from the tasks' results in the
   order wanted, or send through a channel, rather than printing inside I/O tasks.
6. **Room for multicore.** Nothing in the semantics may require tasks to share memory. Running
   tasks on several cores later must not change what a correct program means.
7. **Library over keywords.** No new statement syntax. `Tasks`, `Task[T]`, and `Channel[T]` are
   built-ins, written the way `List[T]` and `Json` are.

## Verified constraints (checked against source, 2026-09-29)

- **The interpreter is one recursive tree-walker with one mutable state.** A task that waits in
  the middle of an expression needs its own native stack, so each task is an OS thread. The
  per-execution state a task must have its own copy of includes at least `scopes`, `file`,
  `call_stack`, `return_value`, `taken_fields`, `raised_value`, `caught_value`,
  `caught_failure`, `stack` (the recursion budget, measured against the native stack), and
  `steps_remaining` (`src/Interpreter.zig`). The rest is either read-only program data (the
  checker's facts) or caches (`regex_cache`, `literal_texts`, `zone_cache`, `random_engine`,
  `file_handles`).
- **Zig 0.16's fiber-based `std.Io.Evented` has no Windows backend** (`std/Io.zig`: Linux
  `Uring`, the BSDs `Kqueue`, Apple `Dispatch`, everything else `void`). Tasks cannot depend on
  it, and Windows is where most of the user's students are. Threads are the portable choice.
- **The heap's reference counts are plain integers, not atomic** (`src/Heap.zig`). That is fine
  while exactly one task runs Emerald code at a time (decision 3), and it is why true
  parallelism is a separate design.
- **The collector is safe across tasks by construction.** It works from counts: a value held
  in flight during evaluation is a counted reference, and the collector frees only what nothing
  outside the heap holds (`Heap.collect`). It does not enumerate roots, so a suspended task's
  temporaries are not at risk. Slice 2 must still prove this with a stress test.
- **Closures capture variables by reference** (7.4), so a task block that captured a `var`
  would share it with its parent. That is what the capture rule in decision 4 prevents.
  Correction found during slice 2: `Checker.capturesOf` does **not** compute a lambda's local
  captures. It walks transitive module reads for a named declaration. `Resolver.lambda_reads`
  contains only module-level variables, while `Resolver.local_captures` records local captures
  for nested named functions, not lambdas. The checker's existing scope stack and binding
  mutability allow the direct-capture rule to be enforced at name resolution, without new
  resolver facts; see slice 2's settled note.
- **Blocking natives block everything today.** `Program.sleep` ("nothing else in the program
  runs meanwhile"), `input`, the filesystem, and `Http` are all synchronous. `Http` runs its
  request on its own threaded `std.Io` and waits for it (`Http.Client.request`).
- **`try/catch/finally`, `raise`, and typed errors** already give cancellation somewhere to
  run cleanup: a `finally` block runs when an error unwinds through it.
- **Type kinds are a closed list** (`Type.Kind`: `list`, `tuple`, `dictionary`, `set`,
  `function`, `struct_value`, and the scalars). There is no user-declared generic, and the
  spec defers them (21). `Task[T]` and `Channel[T]` therefore need two new built-in kinds, as
  `List[T]` has, plus parser support for their names in a type annotation.
- **Editor support depends on the queued editor-intelligence work** (handoff). If its built-in
  member table exists by then, `Task` and `Channel` members are declared there from the start;
  if not, add them the old way and migrate them with that work.

## Proposed API

All of it is in the `Emerald` namespace.

```emerald
# Grouping
Tasks.run(body: func(TaskGroup): T): T             # waits for every task started inside
TaskGroup.start(block: func(): T): Task[T]
Tasks.yield()                                       # let other tasks run now

# One task
Task[T].result(): T                                 # waits; raises the task's error
Task[T].wait(timeout: Duration): Bool               # waits up to timeout; whether it finished
Task[T].done?(): Bool
Task[T].cancel()

# Channels
Channel[T](capacity: Int = 0)                       # 0: a send waits for a receiver
Channel[T].send(value: T)                           # waits when full; raises if closed
Channel[T].receive(): T?                            # waits; nothing once closed and empty
Channel[T].close()
for item in channel { ... }                         # until closed and empty

class CancelledError extends Error { }
class DeadlockError extends RuntimeError { }
```

- **`Tasks.run`** calls its block with a `TaskGroup`, then waits for every task started through
  it. Its result is the block's result. When a task's block raises, that error is remembered as
  the group's first error; every other task, and the group's own block, is cancelled at its
  next suspension point; and once all have stopped, `Tasks.run` raises the first error. An
  error is never dropped, and never raised twice.
- **A task's result type is its block's result type.** `tasks.start { => 42 }` is a
  `Task[Int]`; a block with no result is a `Task[Nothing]`.
- **`Channel` values move by copy.** A list, struct, dictionary, or string sent is the value;
  the receiver's copy is independent. A class instance is sent as the reference it is (10: a
  class value is shared by design), which is safe while one task runs at a time and is the one
  rule to revisit for multicore (decision 4).
- **`for n in channel`** is a built-in form, as `for` over a list or range is. General
  user-defined iteration stays deferred (21).
- **`Task.wait(timeout)`** returns `false` when the time runs out and leaves the task running,
  so a caller can wait again or cancel it. Emerald has no overloading (21), so `result()` and
  a timed wait are two methods, and `wait` composes with `result`.
- **A deadlock is an error, not a hang.** When every task is waiting and none can be woken by
  a clock or by input (a receive on a channel nobody can send to, a `result` waiting on a task
  that is waiting on this one), `Tasks.run` raises `DeadlockError` naming what each task is
  waiting for, with the line where it is waiting.

## Decisions

All nine were accepted as recommended on 2026-09-29. The alternatives are kept for the record.

1. **The model is structured tasks and channels (recommended),** as above. Alternatives:
   `async`/`await` (familiar from C# and JavaScript, but it splits every function into two
   colors and needs `await` sprinkled through beginner code); threads and locks (what Java
   students meet, but data races and deadlocks are the hardest thing to teach); actors
   (isolation by construction, but a new kind of object and a mailbox protocol to learn).
2. **A task can only be started inside `Tasks.run` (recommended),** so nothing outlives its
   block and no error is lost. Alternative: also a detached `spawn` for fire-and-forget work,
   which brings orphan tasks, unobserved errors, and program-exit questions. It can be added
   later if a real program needs it.
3. **Another task runs only when the current one waits (recommended).** A task keeps running
   until it waits on a task, a channel, `Program.sleep`, input, the network or a file, or calls
   `Tasks.yield()`. One task runs Emerald code at a time, in first-come-first-served order.
   This makes output reproducible, makes every interleaving visible in the source, and lets the
   heap stay non-atomic. The cost: a task that computes for a long time without waiting keeps
   the others waiting, which the docs say and `Tasks.yield()` answers. Alternative: switch tasks
   every N evaluation steps (fairer, still deterministic, but a switch can land between any two
   statements, which is what makes real threads hard).
4. **A task block may not capture a `var` (recommended).** It may capture `const` bindings, and
   communicate through channels and results. The diagnostic names the variable and suggests
   returning a value or using a channel. Class instances stay shareable while one task runs at
   a time; when multicore arrives they will need a rule (most likely: only values cross into a
   parallel task, and a class instance crosses only as a copy). Alternative: also forbid
   capturing class instances now, which is stricter than a single-core language needs and would
   make the first programs awkward.
5. **`Task[T]` and `Channel[T]` are new built-in generic types, made by annotation
   (recommended):** `const numbers: Channel[Int] = Channel(capacity: 3)`, the same way an empty
   list takes its type from its annotation. This adds two type kinds and teaches the parser
   their names. Alternatives: `Channel[Int]()` with explicit type arguments (a new expression
   syntax, used nowhere else); or an untyped `Channel` of `Json`-like dynamic values (loses the
   checker's help, which is the point of the language).
6. **Cancellation raises `CancelledError` at the task's next wait (recommended),** so a
   `finally` block runs and resources close. `CancelledError` extends `Error`, not
   `RuntimeError`, so `catch error: RuntimeError` does not swallow a cancellation. Alternative:
   cancel by killing the thread, which skips `finally`, leaks open files, and is unsafe.
7. **A blocking call waits only its own task (recommended).** `Program.sleep`, `input`, the
   filesystem, and `Http` let other tasks run while they wait. Alternative: leave them
   blocking, which makes `Program.sleep` in a task freeze every other task and defeats the
   first program in this plan.
8. **A deadlock raises `DeadlockError` (recommended),** with each task's wait spelled out,
   instead of hanging. Alternative: hang, as most languages do. A hang is the worst thing a
   beginner can meet, and the scheduler knows enough to say why.
9. **Multicore is a separate later plan (recommended).** This plan only promises what keeps it
   possible: values-only communication, no shared `var`, and deterministic results.
   Alternative: design both now, which doubles the decisions before a line is written.

## How it is built

Each task runs on its own OS thread, with a *baton*: exactly one thread holds it, and only the
holder runs Emerald code. A task passes the baton at a wait (decision 3) and takes it back when
it is woken, in first-come-first-served order. No two threads ever run the interpreter at once,
so the heap, the caches, and the output stream need no locks, and a hand-off is the only place
a task switch can happen.

A task's own state is the list in "Verified constraints". Rather than thread a context through
the interpreter's thousands of uses of `self.scopes` and friends, the baton hand-off saves the
outgoing task's copies of those fields and loads the incoming task's. That keeps slice 1 small
and behavior-preserving.

Each task thread records its own recursion budget (`StackLimit.here`) at its base, and its stack
size is chosen deliberately (a large virtual reservation, committed only as used), so the
recursion limit means the same thing in a task as at the top level.

**Threads now, fibers possibly later.** A fiber would be cheaper (thousands or millions of tasks,
no thread per task), but Zig 0.16's fiber-based `std.Io.Evented` is experimental and has no
Windows backend, so it cannot be the language's foundation. The hand-off is the whole interface
between the scheduler and the interpreter: park this task, run that one. Because only one task
runs at a time and switches happen only there, a program cannot tell threads from fibers. A
fiber backend (Windows has its own fiber API, and Zig's may grow one) can therefore replace
the threads later without touching the language. Slice 2 measures what the threads cost.

**Keeping the seam.** Adding a fiber backend later must not be a breaking change: no program,
conformance case, or documented behavior may change, and the tasks cap in slice 2 may only rise.
That holds if these stay true from the first slice:

- All thread-specific code lives in one file, `src/Scheduler.zig`, behind a few operations (start
  a task, park the current one, wake another, switch to the next). Nothing else in the
  interpreter names a thread or a condition variable.
- Blocking natives go through the runtime's own `std.Io`, not a hard-coded one. Today
  `callFilesystem`, the file closes, `clockNanoseconds`, and `callSleep` in `src/Interpreter.zig`
  each reach for `Io.Threaded.global_single_threaded`. A fiber-aware `Io` can suspend one task
  where a blocking call would stall every task on the same thread, so slice 1 replaces those
  with one `Interpreter.io` field. `Http` already owns a threaded `Io`; as settled in
  slice 3, the calling task releases its baton while waiting for the request.
- The per-task state swap (slice 1) never depends on which kind of task is being switched.
- The conformance suite stays backend-neutral (section 19.6): no case depends on thread
  identity, real timing beyond the ordering of different sleeps, or the exact recursion depth at
  which a task overflows its stack (assert the error, not the depth).
- Both backends run the whole suite. Windows keeps the thread backend as long as Zig has no
  fiber backend for it, so the honest picture is two backends behind one interface, not a
  replacement.

A blocking native releases the baton for the length of the wait and takes it back afterward.
The clock (`Program.sleep`, timeouts) and input have to wake tasks: the scheduler owns a timer
list. As settled in slice 5, standard input uses a scheduler-owned reader thread, while its
callers wait cooperatively; custom borrowed readers keep their existing host-read path.

## Slices

Each slice ends with the full validation below passing, and one commit or a short series of
commits.

### Slice 1: A task's own state

- Move the per-task fields into one `TaskState`, with `save` and `load` operations, and the
  baton with a single task only. No behavior changes. Every existing test passes unchanged.
- Replace the hard-coded `Io.Threaded.global_single_threaded` in the interpreter's natives with
  one `Interpreter.io` field, as "Keeping the seam" says. It is a mechanical change that keeps
  behavior and makes a later backend a swap.
- Measure with `tools/startup-benchmark.py`: no measurable cost.
- Settled while building: `TaskState(State)` owns the listed execution fields as one typed
  value; interpreter caches and resource registries remain on `Interpreter`. In particular,
  `file_handles` and `file_writers` are live resource registries rather than caches: they stay
  interpreter-owned so a class handle retains its identity when passed between tasks. The
  single-task `Baton` records its owner and whether it is held; `save` and `load` enforce the
  one-task hand-off invariant in `Scheduler.zig`. `Streams.io` defaults to the existing
  single-threaded backend and is passed into `Interpreter.run`, preserving callers while
  removing every hard-coded global-Io lookup from `Interpreter.zig`. `clockNanoseconds` takes
  the interpreter's `Io` explicitly. No source/API mismatch blocked this slice. An alternating
  30-run ReleaseSafe startup comparison on Linux found no measurable cost: `print(1)` was
  3.88 ms on main and 3.97 ms here; all five samples were between 98.5% and 102.2% of main.

### Slice 2: Tasks that return values

- `Task[T]`, `Tasks.run`, `TaskGroup.start`, `Task.result`, `Task.done?()`. The parser knows
  `Task[...]`; the checker has the kind, the block's result type, and the no-`var`-capture rule
  with its diagnostic; the runtime has the scheduler, threads, and hand-off.
- The group semantics of decision 2 and the error rule under "Proposed API".
- A stress test: many tasks allocate cyclic closures and lists while others wait, with the
  collector forced often, to prove the collector is safe across tasks.
- A measurement, recorded here and in the journal, on Linux and on Windows CI: the time to create
  1,000 and 10,000 tasks that each return a number, the time for two tasks to hand the baton
  back and forth 100,000 times, and the peak memory of each. A limit on live tasks, chosen from
  those numbers and documented, with a clear error (`Tasks.run` cannot start more than N tasks
  at once) instead of an operating-system failure. The numbers decide whether a fiber backend is
  worth building later.
- Conformance: results from several tasks in order, an error from one task, an error from two
  (the first wins), a task that returns nothing, and each diagnostic.
- Settled while building: `Checker.capturesOf` records transitive module reads for named
  declarations, not lambda-local captures, contrary to the verified-constraints claim. The
  checker's existing `block_scopes`, lexical scope stack, and binding mutability suffice:
  while checking an inline task block, a name resolved to an outer `var` is rejected at that
  name, including in nested lambdas and assignments. No new resolver facts are needed. The
  user approved requiring `tasks.start` to receive an inline `{ => ... }` block in this
  milestone; a stored lambda, named function, or any other function value is rejected at its
  argument with a wrapping example. That restriction makes direct captures checkable without
  introducing an effect type for function values. Two indirect-call gaps remain for the
  multicore plan: a task block may call a named function that reads a module `var`, or call a
  captured function value whose own closure holds a `var`. Neither creates a race while one
  task runs Emerald code at a time; both must be closed before multicore execution.
  The scheduler uses OS threads behind one baton and a global cap of 64 live children. On
  Linux ReleaseSafe, 1,000 sequential tasks took 0.21 s and 11 MiB peak RSS; 10,000 took
  2.62 s and 52 MiB; 64 live tasks took 0.02 s and 24 MiB; 100,000 scheduler-only baton
  handoffs took 1.63 s and 1 MiB. A 64-bit host reserves up to 128 MiB of virtual stack per
  live task. The original claim that Windows committed pages only as used was wrong:
  Zig 0.16 passes this as commit size there; slice 6's review notes correct it.
  Windows runtime measurements remain for CI.
  Slice 2 drains all children and propagates the first unobserved task error; automatic
  sibling cancellation is implemented with cancellation in slice 5.

### Slice 3: Waiting for time and the outside world

- `Tasks.yield()`, and the baton released around `Program.sleep`, `input`, the filesystem, and
  `Http`. A timer list for sleeping tasks. `Task.wait(timeout)`.
- Deadlock detection for the waits that exist so far, and `DeadlockError` with its message.
- Conformance with deterministic output: tasks that sleep different lengths finish in order of
  their sleeps (using short sleeps), and tasks that only yield interleave in strict rotation.
- Settled while building: timers, `Tasks.yield`, `Task.wait(timeout)`,
  `DeadlockError` with wait locations, and native I/O baton release are implemented and the
  full local gate passes. The scheduler starts its sorted timer list's worker lazily. Native
  operations return to the baton before touching the Emerald heap; input and each file
  handle have FIFO resource gates, so reads and close cannot race. Closed handle records
  stay until interpreter teardown so a queued operation never refers to freed native state.
  Task executions wrap their backing allocator because native I/O can allocate while another
  task evaluates; programs that do not reach `Tasks.run` keep their existing allocator.
  HTTP's host request runs on the already-existing calling task thread while its baton is
  released; it needs no additional helper thread. Deadlock detection runs at every handoff,
  including when the last runnable task finishes, not just when a task begins waiting.
  It snapshots wait locations before waking participants so group unwinding cannot replace
  the original diagnostic locations. Focused cases cover caught and late-visible deadlocks.

  **Scheduling clarification accepted by the user, 2026-09-29.** With the baton
  released, two `File.read` operations can finish in either order. A standalone probe with
  two tasks reading the same unchanged 1,000,000-byte file, then printing `a` or `b`, produced
  `a, b` 94 times and `b, a` 6 times in 100 runs. It uses no timer, and its input is identical.
  `tools/task-io-order-probe.em` preserves the reproduction. This is not a conformance case
  whose output was retried until passing: it explicitly tested the plan's original promise.
  A FIFO ready queue preserves the order of readiness, but cannot determine when host I/O
  completes. Publishing all external completions in submission order would make output
  reproducible, but can hold a completed network/file task behind another task still waiting
  for interactive input. The accepted rule is reproducible scheduling when tasks wait only
  on each other, channels, or yield; ready tasks resume in readiness order. Sleep deadlines
  resume in deadline order, with equal deadlines ordered by when waiting began; only clearly
  different sleep lengths have a reliable real-clock order. File, network, and input
  completions publish readiness in arrival order, which may vary. The first example teaches
  printing from results in the wanted order (or sending through a channel). Conformance
  prints file-task results in explicit order and never depends on I/O completion order;
  every task-using case still requires 50 matching runs before commit.

  Validation: Zig 0.16.0, sequential `-j1` Debug and ReleaseSafe tests, native build,
  documentation examples, changed-Zig formatting, whitespace, and Windows x86_64/macOS
  aarch64 cross-builds passed. Eleven new or changed task-running conformance cases each
  passed 50 consecutive runs (550 total), including HTTP against a loopback-only server.
  Every expected file was read by hand. Windows execution remains for green PR CI.

### Slice 4: Channels

- `Channel[T]`, `send`, `receive`, `close`, capacity, and `for ... in channel`. Deadlock
  detection extended to channel waits, naming each.
- The checker knows `Channel[T]` and the element type; sending a value of the wrong type is an
  ordinary type error.
- Conformance: producer and consumer at several capacities, a closed channel, a send to a closed
  channel, a receive at the end, and a deadlock message.
- Settled while building: `Channel[T]` is invariant and takes its message type from the
  expected type, including annotations, parameters, returns, and collection literals. A call
  without that context reports the annotation example. The runtime reuses the opaque class
  handle pattern behind `Task`, with a new static type kind, rather than a new runtime value
  tag. Both `Channel()` and `Emerald.Channel()` route to native construction, but a locally
  shadowing callable stays an ordinary call. Native arguments are bound by name.

  Senders and receivers wait FIFO. Zero capacity is a rendezvous; positive buffers grow on
  demand, reuse consumed slots, and never retain an entire stream's previous messages. Values
  in native buffers and waiters are explicitly retained, preserving collection/struct
  copy-on-write semantics and the collector's external roots; class instances remain shared.
  Function messages keep existing closure semantics, including the indirect captured-`var`
  gap already recorded for multicore. A cyclic captured-closure stream tests their lifetime.
  All thread details remain in `Scheduler.zig`; the interpreter owns message values.

  `close()` is idempotent, preserves buffered messages for draining, wakes pending receivers
  with end-of-stream, and wakes undelivered senders with RuntimeError. A send committed before
  closure remains successful. Negative capacity raises RuntimeError with `a channel capacity
  cannot be negative`; sending after closure uses `cannot send to a closed channel`.
  No new error subclass is needed. Originally `receive()` obeyed optional flattening: with optional
  messages, a message of `nothing` and end-of-stream both return `nothing`. Built-in iteration
  tracks end-of-stream separately, so `for` still visits actual `nothing` messages and is the
  unambiguous companion. The user's slice 6 review supersedes this: optional item types
  are now rejected; wrap optional contents in a struct. Destructuring, break, and continue
  use ordinary loop behavior.

  Deadlocks name each channel by its creation-order number, the send/receive direction, and
  the original wait location. A root outside an active group is called `the program`, not
  `the group`. Review found that a caught deadlock could continue before another participant
  removed its waiter: those already-readied waiters must not accept new messages. Scheduler
  readiness checks discard them before a new send/receive; a focused recovery case protects
  this. No accepted decision or source constraint required a design change.

  The full local gate and seven scheduler unit tests pass. Sixteen new or changed running
  cases each passed 50 consecutive runs (800 total), including prelude reach, closed-channel
  errors, and deadlocks. Expected files were read by hand. Validation used pinned Zig 0.16.0,
  sequential `-j1` Debug and ReleaseSafe tests, native build, documentation examples,
  changed-Zig formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds with
  prefixes outside `zig-out`. Windows execution remains for green PR CI.

### Slice 5: Cancellation

- `Task.cancel()`, `CancelledError`, cancellation of siblings and the group's block when a task
  fails, and `finally` blocks running during it.
- Conformance: cancel a sleeping task, a task waiting on a channel, and a task in a `finally`;
  a `catch error: RuntimeError` that must not stop a cancellation; a program that exits with
  tasks cancelled.
- Settled while building: source inspection first paused implementation for a native-I/O
  decision (2026-09-30). `Interpreter.blocking` runs host work on the
  calling task's raw scheduler thread. The default `Streams.io` is
  `std.Io.Threaded.global_single_threaded`; Zig 0.16 explicitly documents that backend
  as not supporting cancellation. More importantly, `Streams.in` is an arbitrary
  `*std.Io.Reader`, whose interface has no cancellation hook and whose backing I/O is
  supplied by the caller. Replacing `Interpreter.io` alone cannot make that reader
  cancellable. `Http.Client.request` has a private request/deadline race, but exposes
  no scheduler cancellation handle.

  A bounded local probe started an `input` task, yielded to it, then raised
  `RuntimeError("stop the group")` in the group body. With its stdin pipe open and no
  data, the existing binary was still running after two seconds; closing stdin let
  it exit, reporting the child's InputError instead of the group's original error.
  This demonstrates the current gap, not a test of an implemented `cancel()`.
  Waking an externally blocked task without stopping and joining its host operation
  would allow that operation to keep accessing the reader, allocator, and resources
  during cleanup. Killing the task thread or detaching its borrowed host operation
  is not an acceptable workaround.

  **Narrower scope approved by the user, 2026-09-30.** Do not add a general host-I/O
  cancellation contract or a cancellation hook for custom readers. Standard input
  uses one scheduler-owned reader thread in `Scheduler.zig`. Tasks wait for a line
  like a channel receive; cancelling that wait raises CancelledError immediately
  and runs cleanup. The in-flight host read continues, and its line is retained
  for the next input call, never discarded. Program exit must not join a blocked
  stdin reader. Fixed in-memory readers used by tests and `.input` cases follow
  the same delivery semantics and finish at EOF without allocator leaks.
  HTTP cancellation uses the existing request/deadline race, not a new mechanism.
  File operations are not interrupted: cancellation is delivered when the operation
  returns. Local files normally return promptly, but a named pipe or device may
  delay cancellation. Add coverage for a failing group with another task waiting
  on unavailable input: the first error wins promptly, and a later line reaches
  the next input call. These rules replace the broader extension proposed above.

  Implementation choices: the CLI marks its standard-input source explicitly; the
  scheduler's single stdin service owns a file reader, buffer, and process-lifetime
  allocations, so a detached, blocked reader never refers to an interpreter's stack
  or allocator. Fixed-reader services own a copy, advance the caller's fixed reader
  only on delivery, and join/free at teardown. Other borrowed custom readers keep
  their existing host-read path; no generic cancellation hook was introduced.
  Runtime/job pointers are registered only for the length of a wait and removed
  under the reader mutex before the task returns. A pending line is reserved for
  the oldest waiting caller; abandoning that reservation passes it to the next
  caller without consuming the line. The existing two-task input case exposed
  a later caller stealing an already-promised line; reservation fixes that bug.

  CancelledError extends Error directly. Requests are consumed at suspension
  boundaries, not during ordinary computation. Cleanup and group draining mask
  cancellation so waits in `finally` still finish. Deliberately cancelled children
  do not fail an otherwise successful group; their result calls still raise their
  CancelledError. A real task failure triggers sibling/owner cancellation once.
  The group remains in cancellation while draining: children started by another
  child before it reaches its checkpoint inherit that request. A regression
  catches the first error in the owner and still verifies prompt late-child cleanup.
  Normal implicit group joins remain cancellation points, including nested groups.
  They become protected draining only after an error/cancellation; cancelling a
  parent then cancels and joins its nested children before its own cleanup runs.
  The group remembers that first failure. Directly asking for that failing task's
  result in the owner observes its actual error, preserving existing typed catches
  and avoiding a second raise during draining. Other owner suspension points raise
  CancelledError, so a RuntimeError catch cannot swallow automatic cancellation.
  Repeated cancellation must not remove a protected cleanup's channel waiter;
  readiness checks keep those waiters matchable. A regression case cancels again
  while `finally` is sending its second message, then receives that message and
  lets cleanup finish. Group draining consumes pending cancellation before
  restoring an original error, so a late cleanup request cannot replace it.
  Two existing deadlock expectations now name the group's original failure site,
  rather than replacing it with a child's later failure during draining.

  HTTP's deadline worker can be signalled early; the same Select race stops and
  joins the request, retaining the transport's connection cleanup. Cancellation
  frees a response that finished concurrently before raising CancelledError.
  The same signal applies to a group's owner waiting on HTTP when its child fails,
  not only to explicitly cancelled child requests; the HTTP case checks both.
  No host HTTP cancellation machinery was duplicated. File/resource waits are
  allowed to return before cancellation is delivered. Live held-open-pipe checks
  are in `tools/task-input-cancellation.py` and the CI matrix; they exercise prompt
  group exit and preservation of a line supplied only after cancellation.
  Managed file helpers check cancellation after opening and before invoking their
  user block, closing the new handle on that path. A tmpDir-backed Zig test checks
  both helpers, absence of user-block output, and subsequent reuse of the file.
  Validation: pinned Zig 0.16.0, sequential `-j1` Debug and ReleaseSafe tests,
  native build, documentation examples (23 executed, 113 linked conformance files),
  changed-Zig formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds
  outside `zig-out` passed. Fifteen new, changed, or directly affected task cases
  each passed 50 consecutive runs (750 checks), including HTTP against a loopback-only
  server. The live stdin driver passed 50 prompt-exit and 50 retained-line checks;
  a local-file cancellation probe passed 50 runs. All expected files were read by
  hand. Nine scheduler unit tests pass. Windows execution remains for green PR CI.

### Slice 6: Documentation and integration

- `docs/library/tasks.md` (`Tasks`, `Task`, `Channel`, the errors), `errors.md`, `inventory.md`,
  and an `examples/tasks.em` built from the programs at the top of this plan, using short sleeps
  and no network.
- Rewrite-context: a new section records the settled design and decisions, 21 and 15.7 mark
  concurrency as designed and implemented for tasks, and section 22 gets a row for each
  alternative that this closes.
- The formatter, and the language server's hover and go to definition, understand the new
  syntax; a valid-program fuzz template for tasks and channels; `run/prelude-reach` lines.
- An alternating ReleaseSafe startup comparison against `main`: no measurable cost for a
  program that uses none of this.
- The handoff and journal.
- Settled while building: `docs/library/tasks.md` covers every public task/channel
  operation, callback/capture rules, ordering, errors, cleanup, and the accepted I/O
  cancellation distinctions. `examples/tasks.em` demonstrates ordered results, a buffered
  producer/consumer, and cancellation using a 20 ms sleep, with no network. Its output was
  verified with the binary and repeated 50 times. The existing prelude-reach case now also
  reaches done/cancel/yield without changing its expected output; it passed 50 runs.
  Rewrite-context 15.13 is the normative home for the completed design; sections 15.7 and
  21 no longer defer structured tasks, and section 22 records all nine accepted choices.
  `Program.sleep` documentation now correctly describes pausing only its calling task.

  The formatter already handled task/channel flags and nested elements; a focused test
  protects their canonical output. LSP traversal already handled element types and task
  bodies, but the outer generic names have empty AST `name` fields. Definition and
  reference handling now maps the Task/Channel flags to their prelude declarations, using
  Resolver's namespace keys. Tests cover outer names, element annotations, values' hover
  types, and navigation inside task blocks. Built-in member completion/signature help
  remains part of the queued editor-intelligence work, not a second table added here.

  Two valid fuzz templates exercise yielded task results and channel rendezvous/buffers,
  without clocks or external I/O. The generator's selection range also makes its existing
  inline-if fallback reachable (it had been excluded by the old upper bound). The fixed
  ReleaseSafe campaign passed seed 12648430, 1,000 cases, 136 executions.
  Windows ReleaseSafe CI now runs the existing creation/live-cap/handoff probes and logs
  timings plus sampled peak physical memory with a bounded PowerShell driver. That script
  cannot be executed on this Linux host; its Windows results remain a review/CI gate.
  No accepted API decision needed changing.

  Final validation: pinned Zig 0.16.0, sequential `-j1` Debug and ReleaseSafe tests,
  native build, documentation examples (24 executed, 124 linked conformance files),
  changed-Zig formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds
  outside `zig-out` passed. The standalone scheduler benchmark also cross-compiled
  for Windows. Both its root and scheduler modules now explicitly use ReleaseSafe.
  A final 60-run alternating ReleaseSafe comparison against main `ef14a72` measured
  `print(1)` at 3.67 vs. 3.76 ms; all five medians were 100.2%–102.3% of main.
  These small observed differences do not establish zero overhead, but show no
  material startup regression for programs using no concurrency. The journal has
  both comparisons and the host details. The branch is ready for Claude's review;
  Windows runtime and measurement results remain pending CI.

### Slice 6 review corrections (required by the user, 2026-09-30)

- **Windows command arguments:** quote both `-M` arguments and `-femit-bin` so
  PowerShell passes each as one native argument. The previous CI command failed
  before measuring anything.
- **Windows stack commit:** source inspection confirms Zig 0.16's Windows spawn
  passes `stack_size` as committed size to `NtCreateThreadEx`, not reservation.
  `Scheduler.zig` now starts task threads with `CreateThread` and
  `STACK_SIZE_PARAM_IS_A_RESERVATION`, retaining the same 128 MiB recursion budget
  on 64-bit hosts. No smaller stack limit is substituted. The Windows driver logs
  `PeakPagedMemorySize64` (commit) as well as `PeakWorkingSet64`, requires the
  `started: 64` marker emitted before any child runs, and compares one versus 64 live
  children, requiring less than 64 MiB additional commit rather than about 8 GiB.
  The first corrected CI run reached the measurements: 1,000/10,000 sequential
  tasks committed 1032.74/1032.81 MiB; all 64 live tasks started and committed
  1035.38 MiB. Its absolute 1 GiB check failed because the existing main interpreter
  thread in `emerald.zig` commits a 1 GiB stack, not the 128 MiB assumed by that
  check's comment. The corrected baseline uses the same live-task program with
  one child to isolate task-thread costs, without changing the interpreter's
  pre-existing stack policy or increasing a timing margin. Final CI remains pending.
- **Completed lifetimes:** joining unlinks a job from `Runtime.all`. A group's
  final drain joins even if a cancellation checkpoint interrupted the ordinary
  result wait after completion but before joining. After the group ends, completed
  results/errors are managed edges of the Task handle; its native finalizer removes
  the task record. Group records and task execution buffers are freed then.
  Active groups root their handles; escaped handles remain usable; cycles through
  completed results are collectible. Native finalizers never release managed values
  during sweeping. A heap-cycle test, a scheduler unlink test, and `task-lifetime`
  cover those invariants. `tools/task-scaling.py` compares 2,000 and 20,000 one-task
  groups on Linux; Windows CI runs the same comparison for time, physical memory,
  and commit. Both reject greater than 15x time or 2x peak memory for 10x tasks.
  Source inspection and measurements also found that the task allocator was never
  activated: it looked for a method key although reachability stores top-level type
  keys. Activation now looks for `Emerald.Tasks` via Resolver, with a reachability
  test. The existing allocator mutex also protects nine shared small-allocation
  pools (16–4,096 bytes, alignment up to 16), so new OS threads can reuse buffers
  freed by other tasks instead of growing ReleaseSafe's thread-local freelists.
  Larger or over-aligned allocations still use the caller's allocator. Pool
  backing storage is freed at outcome teardown; tests cover cross-thread reuse,
  alignment, and refusal to resize across pooled/unpooled storage classes.
- **Optional channel items:** reject an optional element at its type annotation
  with `a channel's items can't be optional` and `Wrap the value in a struct.`
  This is the user's accepted change, not optional flattening with a workaround.
  The closed-channel case now sends structs containing optional fields; its output
  stays unchanged. A dedicated diagnostics case protects the error and help.

Linux ReleaseSafe scaling passed (three alternating samples per count): 2,000 tasks
0.36 s / 7.19 MiB peak RSS; 20,000 tasks 3.57 s / 7.19 MiB. Time is 9.92x and
peak memory 1.00x. Before allocator activation/pooling, time was already linear
but ReleaseSafe RSS rose from about 8 MiB to 18 MiB (about 62 MiB at 100,000).
Debug with reclaimed records was flat at 19,868 vs. 19,884 KiB, confirming the
remaining growth was allocator retention rather than live task state.
The corrected local gate passed: Debug and ReleaseSafe tests with pinned Zig 0.16.0
and `-j1`, native build, documentation examples (24 executed, 126 linked conformance
cases), changed-Zig formatting, whitespace, Windows x86_64/macOS aarch64 cross-builds
outside `zig-out`, and the standalone Windows ReleaseSafe scheduler probe cross-build.
All 33 task/channel run cases passed 50 runs each. The live-input driver passed 50
prompt-exit and 50 retained-line checks. ReleaseSafe fuzz seed 12648430 passed 1,000
cases, 136 executed. Windows runtime CI and commit measurements
remain pending; no cross-build result is presented as a Windows runtime measurement.

## Validation

Every slice must pass, on the pinned Zig 0.16.0 with `-j1`:

- Debug and ReleaseSafe `zig build test -j1`;
- `zig build -j1`;
- `bash tools/check-doc-examples.sh`;
- `zig fmt --check` on changed Zig files;
- `git diff --check`;
- Windows and macOS cross-builds with `--prefix` outside `zig-out`, so the native binary is not
  overwritten.

Concurrency needs more than the usual care from tests:

- Run each new conformance case that uses tasks at least 50 times in a loop before committing
  it. A case whose output ever differs is a bug in the scheduler or the case, and is fixed, not
  retried.
- CI runs Windows, where thread creation, stack size, and timing differ; a slice is not done
  until its pull request is green there.
- Debug tests run under the testing allocator, so a leaked task, thread, or channel fails them.

## Later: multicore

Running tasks on several cores at once is a separate plan, and this one should not be bent
toward it. What this design leaves open, so that plan starts from a good place:

- **Values-only communication** means a parallel task can be given a copy of its input and can
  return a copy of its output.
- **The interpreter's shared state is mostly read-only** (the checker's facts and the syntax
  tree), so a parallel worker can be a second interpreter with its own heap over the same
  program, and the non-atomic reference counts never cross a thread. The caches (`regex_cache`,
  `literal_texts`, the zone cache) become per-worker.
- **The likely first form** is data parallelism over a list, such as a `parallel_map` whose
  block captures only `const` values and whose results come back in order. It teaches the idea
  without asking a student to reason about interleaving.
- **Open for that plan:** whether module-level `var`s may be touched from a parallel task
  (likely not), and what a class instance means when it crosses (likely a copy).

## Out of scope

These are deliberately not in this plan:

- locks, mutexes, atomics, semaphores, and condition variables (a channel is the tool);
- detached tasks, thread pools, task priorities, and thread or task identity;
- `async` and `await` keywords, futures that escape a group, and callbacks;
- running Emerald code on more than one core at once;
- a `select` over several channels, which is a natural follow-up once one real program wants it;
- concurrency inside the REPL beyond what one line's `Tasks.run` gives;
- networking servers (`Http` stays a client).
