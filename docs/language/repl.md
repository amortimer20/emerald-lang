# Trying code in the REPL

Run `emerald repl` to try Emerald without saving a file. The `>` prompt asks for
an entry; `. ` asks for another line while a block, delimiter, multiline string,
or block comment is still open.

```text
> const name = "Ada"
> var count = 0
> count += 1
> count
1
> "Ada".upper()
"ADA"
> func greet(who: String): String {
.     return "Hello, #{who}!"
. }
> greet(name)
"Hello, Ada!"
```

Values persist between entries. Expressions show their results, including calls
such as `greet(name)`. Strings are shown quoted so text is distinguishable from
other values. `print` is unchanged: `print("hi")` shows `hi`, not `"hi"`, and
does not show an extra result. Declarations, assignments, and calls returning
`Nothing` are also silent. An optional result may show `nothing`.

Each entry executes once. Earlier entries are checked again, but their effects
are not repeated. In a directory without `log.txt`, this creates the file and
leaves it holding just `x`:

```text
> File.append("log.txt", "x")
> print(1)
1
> print(2)
2
> File.read("log.txt")
"x"
```

Ordinary binding rules still apply: a `var` can be reassigned, a `const` cannot,
and a name cannot be declared twice. Try a different name, or use `:reset` to
start over. An error points into the entry it describes, not into all the text
entered during the session.

An entry that fails to parse or check runs nothing. If an entry raises while
running, its declarations are removed, but assignments and outside effects
already completed remain. For example:

```text
> var score = 1
> if true {
.     score = 7
.     print("kept")
.     raise RuntimeError("boom")
. }
kept
repl:4:5: RuntimeError: boom
> score
7
```

The diagnostic above is shortened; the actual message also shows the source
line, a caret, and help. The printed output and changed `score` remain. A file
write or request cannot be undone by discarding the entry or resetting the
session. A function value assigned into an earlier binding before an error
also remains usable.

`input` reads the next line you type. It shares its reader with the prompt, so
input belongs to whichever is asking for a line, including inside `Tasks.run`.

| Command | Behavior |
| --- | --- |
| `:help` | Show the commands and explain what a failed entry keeps |
| `:reset` | Clear bindings and interpreter state; external effects remain |
| `:quit` | Leave the REPL |

End of input also exits. Line editing, history, and extra commands are not part
of this milestone. The [transcript cases](../../conformance/repl/) check these
behaviors end to end.
