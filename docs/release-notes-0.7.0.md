Emerald 0.7.0 lets several pieces of work wait at once, adds a REPL you can explore in, and teaches your editor what you can write next. It also explains many more mistakes in plain words and says what to write instead.

## Install

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/amortimer20/emerald-lang/main/install.ps1 | iex
```

macOS (Apple silicon) and Linux (x86-64):

```bash
curl -fsSL https://raw.githubusercontent.com/amortimer20/emerald-lang/main/install.sh | sh
```

If you installed an earlier version with these scripts, running the command again updates it. Mise users can run `mise use -g "github:amortimer20/emerald-lang@latest"`. For the editor features below, also install the Emerald extension for Visual Studio Code, version 0.3.0 or newer.

## Tasks and channels

- **Tasks.** `Tasks.run` makes a group, and `tasks.start { => ... }` begins a task whose block's value is its `result()`. Tasks overlap their waiting, so a program that fetches four pages takes about as long as the slowest one. There is no `async`, `await`, thread, or lock to look after, and `Tasks.run` doesn't return until every task it started has finished.
- **Channels.** A `Channel[T]` is a first-in, first-out queue that one task sends into and another receives from, waiting for each other as needed.
- **Timed waits and cancellation.** `task.wait(timeout:)` waits for a limited time, `task.cancel()` stops work you no longer need, and a cancelled task still runs its cleanup. When one task fails, the others in its group are cancelled, so a failure never leaves work half running.
- **Deadlocks explain themselves.** If every task is waiting and nothing can ever wake one, Emerald raises `DeadlockError` instead of hanging.

Tasks take turns: they overlap their waiting, not their calculating, so this is not yet use of several processor cores.

## A REPL to explore in

`emerald repl` starts a session where each entry runs once, so reading a file, making a request, or drawing a random number happens exactly one time. A call shows its result, and a string shows in quotes. `print` and other statements that give nothing back add no extra line.

```text
> 1 + 1
2
> "hi"
"hi"
> const a = 5
> a * 2
10
```

An entry that doesn't check changes nothing. An entry that fails while running loses its declarations but keeps the assignments, output, and effects that had already happened. Errors point inside the entry you typed. `:help` explains all of this, `:reset` clears the session, and `:quit` leaves.

## A smarter editor

With the Emerald extension for VS Code (0.3.0 or newer), your editor now understands more of what you are writing:

- **Completion** offers the members of built-in types and libraries, such as `String`, `List`, `File`, and `Math`, each with its signature and a one-line description. Choosing a method writes its parentheses.
- **Hover** shows a member's signature, a plain description, whether it can raise an error, and a link to its page on the Emerald website. Your own declarations show their `##` comments.
- **Signature help** marks the parameter you are writing, after `(` and after each `,`, including named arguments, default values, and constructors.
- **Quick fixes** offer one-click corrections for a few mistakes: `push` becomes `append`, `this` becomes `self`, and a misspelled annotation such as `@overide` becomes `@override`.

## Terminal programs

`Console.table` and `Console.panel` lay out text in boxes, and six prompts ask the person at the keyboard: `ask`, `ask_int`, `ask_float`, `confirm`, `choose`, and `choose_many`. A prompt that reaches the end of the input raises `InputError`, which is a kind of `RuntimeError`, so code that catches `RuntimeError` keeps working.

## Mistakes explained

Emerald now answers more of the habits people bring from other languages:

- `&&` and `||` suggest `and` and `or`. `++` and `--` explain `+= 1` and `-= 1`. `condition ? a : b` shows `if condition then a else b`, and `??` shows `.or(...)`.
- A condition written with `=` suggests `==`, including in guards, inline `if`, `assert`, and `case` arms.
- A struct that supplies everything a trait needs but never says `with Trait` is told so, with the fix and the list of methods involved.
- A bare nested type such as `Size` inside `Pizza` is corrected to `Pizza.Size`.
- A name that ends in `?` must return `Bool`, and Emerald says so when it doesn't.
- A `##` documentation comment separated from its declaration by a blank line now warns, and names that don't follow `snake_case` or `PascalCase` get a gentle warning with the corrected spelling.
- A private name in another file says whose it is, instead of saying it is undefined.
- `break` or `continue` in a one-line block explains that a function cannot exit the caller's loop, and a missing expression no longer buries the real mistake under a cascade of brace errors.
- Console table errors name the header, number data rows from 1, and say "1 cell" for one.

## Fixes and care

- Excessive recursion raises a catchable `RecursionError` instead of ending the program. It is a `RuntimeError`, so existing catches still work.
- An HTTP request made after a timed-out one could receive the timed-out request's reply. It can't any more, and requests now send Emerald's own `User-Agent`, or yours if you set one.
- `File.read_lines` and `FileHandle.read_line` drop the carriage return from Windows line endings, matching `String.lines`, and `File.append` creates the file if it is missing.
- `Range.step()` without its argument, and `Math.pi()` or `Math.e()` with parentheses, now give clear errors instead of crashing the checker or the interpreter.
- A callback that belongs to a list operation, such as an ordering method, can read the list it is working on but can no longer change it. Trying raises a catchable `RuntimeError` instead of touching freed memory.
- A project's own `math/` declarations win over the built-in `Math` members, with a warning, and `Emerald.Math` still reaches the built-ins. A method of yours named `times`, `up_to`, or `down_to` takes precedence over the built-in counting forms.
- The formatter keeps required parentheses around trailing-block calls in `when` headers and keeps comments where you put them, and a file that starts with blank lines before a comment now formats the same way every time.

## Upgrading from 0.6.0

- `chunks`, `windows`, and `pairs` now give nested lists and pairs, as their names promise. Code that relied on the old, wrong type needs fixing.
- A callable whose name ends in `?` must return exactly `Bool`. Rename it, or change its result.
- `File.append` on a missing file creates it. It used to raise `FileError`.
- `input` at the end of the input raises `InputError`, a `RuntimeError`, where it used to raise a plain `RuntimeError`.
- Built-in `Math` functions cannot be stored as values; call them, or wrap the call in a block. Math constants such as `Math.pi` still can.
- Names that don't follow the casing convention now produce warnings. They never stop a program.
