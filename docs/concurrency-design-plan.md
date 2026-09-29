# Concurrency: design and implementation plan

Status: proposed, 2026-09-29, awaiting the user's decisions below. Rewrite-context 21 calls
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

These were checked with `emerald format`. Everything parses today except `Channel[Int]` in a
type annotation, which needs the parser to learn two new generic type names (decision 5); the
names `Tasks`, `Task`, and `Channel` are of course not defined yet. A block that takes nothing
is written `{ => ... }`, and one that takes a value is `{ tasks => ... }`.

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
5. **Deterministic by default.** Given the same input and no clock-dependent waits, a program
   prints the same output every time. A student, a test, and a bug report can all rely on it.
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
  would share it with its parent. That is what the capture rule in decision 4 prevents. The
  checker already computes what a block captures (`Checker.capturesOf`).
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

Each has a recommendation; the user decides.

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

A blocking native releases the baton for the length of the wait and takes it back afterward.
The clock (`Program.sleep`, timeouts) and input have to wake tasks: the scheduler owns a timer
list, and the wait for input runs on the reading task's thread.

## Slices

Each slice ends with the full validation below passing, and one commit or a short series of
commits.

### Slice 1: A task's own state

- Move the per-task fields into one `TaskState`, with `save` and `load` operations, and the
  baton with a single task only. No behavior changes. Every existing test passes unchanged.
- Measure with `tools/startup-benchmark.py`: no measurable cost.
- Settled while building: (record here)

### Slice 2: Tasks that return values

- `Task[T]`, `Tasks.run`, `TaskGroup.start`, `Task.result`, `Task.done?()`. The parser knows
  `Task[...]`; the checker has the kind, the block's result type, and the no-`var`-capture rule
  with its diagnostic; the runtime has the scheduler, threads, and hand-off.
- The group semantics of decision 2 and the error rule under "Proposed API".
- A stress test: many tasks allocate cyclic closures and lists while others wait, with the
  collector forced often, to prove the collector is safe across tasks.
- Conformance: results from several tasks in order, an error from one task, an error from two
  (the first wins), a task that returns nothing, and each diagnostic.
- Settled while building: (record here)

### Slice 3: Waiting for time and the outside world

- `Tasks.yield()`, and the baton released around `Program.sleep`, `input`, the filesystem, and
  `Http`. A timer list for sleeping tasks. `Task.wait(timeout)`.
- Deadlock detection for the waits that exist so far, and `DeadlockError` with its message.
- Conformance with deterministic output: tasks that sleep different lengths finish in order of
  their sleeps (using short sleeps), and tasks that only yield interleave in strict rotation.
- Settled while building: (record here)

### Slice 4: Channels

- `Channel[T]`, `send`, `receive`, `close`, capacity, and `for ... in channel`. Deadlock
  detection extended to channel waits, naming each.
- The checker knows `Channel[T]` and the element type; sending a value of the wrong type is an
  ordinary type error.
- Conformance: producer and consumer at several capacities, a closed channel, a send to a closed
  channel, a receive at the end, and a deadlock message.
- Settled while building: (record here)

### Slice 5: Cancellation

- `Task.cancel()`, `CancelledError`, cancellation of siblings and the group's block when a task
  fails, and `finally` blocks running during it.
- Conformance: cancel a sleeping task, a task waiting on a channel, and a task in a `finally`;
  a `catch error: RuntimeError` that must not stop a cancellation; a program that exits with
  tasks cancelled.
- Settled while building: (record here)

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
- Settled while building: (record here)

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
