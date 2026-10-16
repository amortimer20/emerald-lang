# Generics: design plan

Status: proposed, 2026-10-16 (rewritten twice the same day after the user's discussion).
Claude wrote this plan at the user's request. Nothing in it is decided until the user
accepts or changes each recommendation. Nothing is built.

**Every program in this plan is a proposed example, and none compiles today: each uses
generic syntax.** To check the rest of the syntax, each program in section 7 was also run
with its type parameters replaced by concrete types (`T` as `String` or `Int`) on
`Emerald 0.7.0-dev` (main `8477bd4`, 2026-10-16). Two mistakes in the first drafts surfaced
and are fixed below (`empty?` needs parentheses, and an `if` expression's `else` cannot start
a new line); after those, all nine ran and printed what they should. What has not been
tested is anything that depends on the generics themselves: inference, constraints, and the
erased runtime. Intended output is a requirement for any implementation, not a report of a
generic run.

The user's requirement, recorded 2026-10-02: generics must be clean, easy to read, and easy
to work with, and must not make the language messy. The user is apprehensive about adding
them at all, and the rewrite context's principle 6 says generics grow only from demonstrated
needs. On 2026-10-16 the user chose the syntax below and asked whether it had to be any more
complex; it does not. The plan therefore has two parts: **a gate** that decides whether to
build at all (sections 3 and 4), and **the design to build** if the gate is met (section 5).

Rewrite-context 11.3 and 21 (deferred), 8.2 and 4.2 (built-in spellings, not user
generics), 15.13 (`Channel[T]`'s expected-type rule), and 1's principle 6 remain the
specification until this plan is accepted and built.

## Recommendations at a glance

| Decision | Recommendation |
| --- | --- |
| 1. Whether, and when | Decide on evidence by the gate in section 3. Not before 1.0 unless the gate is met; 1.0 ships without user generics otherwise |
| 2. Reserve the syntax now | A bracketed type-parameter list on a declaration, and type arguments on a user type, get a plain "not supported yet" error, so adding generics later breaks no program |
| 3. Syntax | `[T]` and `[T with Trait]` after the name of a `class`, `struct`, `enum`, `func`, or method. Nothing else |
| 4. Constraints | `with` plus an existing trait, one per parameter; compose a trait for more. The built-in scalars count as adopters |
| 5. Unconstrained parameters | Store, pass, return, put in collections, display. No `==`, `<`, hashing, or members |
| 6. Using a generic | Types are written only in annotations and otherwise inferred; never at a call (`Stack[Int]()` is not allowed) |
| 7. Optionals | A type argument may not itself be optional, as for `Channel` |
| 8. Numbers | `Float` type arguments accept `Int` values like `List[Float]`, recorded by the checker; fallback is a teaching error |
| 9. Runtime model | Erased in the interpreter; the language promises nothing a compiler could not do either way |
| 10. Not in the first milestone | Generic traits, generic lambdas, and inheritance involving a generic class |
| 11. Diagnostics | Drafted before the checker (section 6) and part of every slice's gate |

## 1. What goes wrong with generics elsewhere

The goal is to name what makes generics heavy, so each can be refused on purpose.

| What ruins the experience | Where it shows up | This plan's answer |
| --- | --- | --- |
| Angle brackets and `where T : IComparable<T>` clauses | C#, Java, Rust | `[T]` as `List[T]` already is; constraints reuse `with` |
| Variance and wildcards (`? extends T`, `in`/`out`) | Java, C#, Kotlin, Scala | None. `Stack[Int]` is not a `Stack[Float]`, as `Channel` is not |
| Writing type arguments at calls (`Foo<int>(x)`, turbofish) | C#, Rust, Java | None. Types are written in annotations only |
| Errors that appear at the use site, inside the library's body | C++ templates | A body is checked once, at its definition |
| Errors that talk about the machinery (`T`, "bounds", "unify") | all | Plain words, naming the fix |
| Type parameters used as values (`T()`, `T.zero`, `is T`) | C#, Swift | Never. A type parameter is only a type |
| Associated types, higher-kinded types, specialization, overloading | Rust, Haskell, C++ | Never |

Go held out for a decade for the same reasons and shipped a small design in 1.18 (type
parameters in brackets, interfaces as constraints, inferred arguments, no variance, no
generic methods). It is the closest precedent for this plan, and the reason to wait: Go's
programmers got by on built-in generic collections, interfaces, and copy-paste.

## 2. What we would be fixing, and what is already covered

Emerald's built-in `List`, `Dict`, `Set`, `Task`, and `Channel` already carry element types,
and `List` has `map`, `filter`, `sort`, `sort_by`, `min_by`, `reduce`, `group_by`, and dozens
more. Much of what generics are usually wanted for is already there:

- **A pair** is a tuple: `(String, Int)`.
- **A stack or a queue** is a `List`: it has `append`, `remove_last`, and `remove_first`.
- **A result or option** is an optional or a typed error, and data-carrying enums (merged
  2026-10-16) cover the "one of several shapes" cases generics were most wanted for.
- **Behavior shared across types** is a trait, and `List[Describable]` holds mixed values.

What a student cannot write today is **a container or helper of their own that keeps its
element type**: a linked list, a tree, a grid, a history, a cache, a `largest` over anything
with an order. Without `Any`, the workaround in Go (`interface{}` and assertions) does not
exist, so the gap is a wall rather than a verbose detour: one class per element type,
identical except for the type.

```emerald
# Today, one class per element type, identical except for the type:
class IntGrid { var _cells: List[Int] = [] ... }
class StringGrid { var _cells: List[String] = [] ... }
```

That is the whole need. Everything else in this plan is sized to it.

## 3. The gate: when to build

**Recommendation: build only if the evidence below says so, and not before 1.0 otherwise.**

Generics are the one feature a 1.0 compatibility promise cannot take back, and the language
can add them later without breaking anything if the syntax is reserved now (section 4). So
waiting costs nothing, and building early commits the language to rules (inference,
diagnostics, what a body may do) before real programs have argued for them.

**The deciding question for the user:** is Emerald a first-programming-course language, or
does it carry students into a data-structures course? A first course can reasonably say "no
generics yet, write one class per type". A data-structures course (linked lists, trees,
graphs, grids) is exactly where the wall is real.

**The wall log.** Record each time a real program, classroom example, or QA program cannot be
written without copy-paste or a type-specific class. Keep it in `docs/generics-wall-log.md`
(not created yet), one entry each: the program, the container or helper it needed, whether it
needed an order or a hash, and what the workaround cost. Suggested threshold: about a dozen
entries from at least three different shapes (not twelve stacks), or one data-structures
program the user wants to ship in the examples and cannot. If the log stays short at the 1.0
review, 1.0 ships without them, and this plan stays on the shelf.

**Slice 0 (no code).** Independently of the log, the user reads the programs in section 7
cold, without this plan beside them. The feature proceeds only if they read as easier to
understand than the copy-and-paste versions.

## 4. Reserve the syntax now

**Recommendation: yes, a small change on its own, independent of the rest of this plan.**

Two things get a plain message instead of whatever today's parser or checker happens to say,
so no program written before 1.0 can use them, and later generics break nothing:

```emerald
class Stack[T] { }             # error: Emerald does not have generic declarations yet
const stack: Stack[Int] = ...  # error: `Stack` does not take types in brackets
```

Suggested wording (a proposal): "`Stack[T]` declares a type that works with any kind of item,
which Emerald does not support yet." with the help "Write one class for each kind of item,
such as `IntStack`, or keep the items in a `List`."

**What today's parser does (checked 2026-10-16).** Every declaration form is already a syntax
error, so no program can use it and reservation costs nothing; what is wrong is the wording:

| Source | Today's message |
| --- | --- |
| `class Stack[T] {` , `enum Chain[T] {` | `expected `{` after `Stack`, found [` (the hint teaches a class body) |
| `func largest[T](...)`, a method `mapped[U](...)` | `expected `(` after `largest`, found [` (the hint teaches parameters) |
| `const s: Stack[Int] = Stack()` with a user type | `expected the end of the line, found [` |
| `Stack[Int]()` as an expression | `` `Int` is not defined `` (parsed as indexing; a name that exists would be misread) |

The messages blame the wrong thing, and the last is the real hazard for later: `Stack[Int]()`
parses as indexing `Stack`, so a call-site type argument could never be added without
changing its meaning, which supports 5.4's choice to never write one. The reservation
change replaces the four messages above with the proposed wording and adds a `diagnostics/`
case for each. Rewrite-context 11.3 and 21 are updated in the same change to say the syntax
is reserved.

## 5. The design, if the gate is met

### 5.1 Syntax

```emerald
class Stack[T] { ... }
struct Pair[A, B] { ... }
enum Chain[T] { ... }
func largest[T with Ordered](items: List[T]): T? { ... }
class Cache[K with Hashable, V] { ... }
class Box[T] {
    func mapped[U](change: func(T): U): Box[U] { ... }
}
```

The grammar addition is one optional bracket list after the name of a type, function, or
method, and `with` inside it. A type parameter is a PascalCase name; single capitals such as
`T` are legal, and the guide may prefer descriptive names (`Item`, `Key`) since principle 1
asks that a beginner explain every character. Nothing enforces either.

- A type parameter that is also the name of a real type in scope is an error naming both,
  since it would hide the real type inside the body.
- Parameters are unique within a declaration. An unused one is a warning naming it, since it
  is almost always a typo. There are no defaults and no empty `[]`.
- A method may declare its own parameters (`mapped[U]`). If free functions can, a method
  cannot sensibly be the exception; it uses the same inference as a function and may also
  use its type's parameters.
- A generic type may adopt ordinary traits (`struct Pair[A, B] with Textual`). It cannot be a
  trait, a lambda, or part of an inheritance chain in the first milestone (decision 10):
  generic traits are associated types by another name (11.3), a lambda may use but not declare
  parameters, and substituting through a base class with virtual dispatch is the largest cost
  for the least classroom value.

### 5.2 Constraints

`[T with Trait]` says the argument adopts that trait, using 11.2's meaning of `with`. It
needs no new keyword and no `where`.

- **One trait per parameter.** `[T with Ordered, Textual]` is ambiguous against a second
  parameter named `Textual`. A program that needs two traits writes one that composes them,
  as 11.2 already allows: `trait Sortable with Ordered, Textual { }`. The programs below
  decide whether that is ever clumsy.
- **Operators and members.** In a body, `<` needs `Ordered` and `==` needs `Equatable`, since
  their meaning depends on the argument (`==` is structural for a struct, identity for a
  class, custom for `Equatable`). `Hashable` already composes `Equatable` (11.2). A `Dict` key
  or `Set` element needs `Hashable`, because `Equatable` alone does not make a key (8.3).
  A parameter constrained by a trait has that trait's members, and a member that mentions
  `Self` takes and gives `T`: `a.compare(b)` for `T with Ordered` is exactly the opaque `Self`
  the checker already models inside a trait's own defaults (11.4).
- **Built-in scalars count as adopters.** Today `Int`, `Float`, and `String` have an order and
  equality natively, but they do not adopt `Ordered`, and have no `compare`, `equals`, or
  `hash` members (checked against `docs/library/int.md`, `float.md`, `string.md`, and the
  checker's "Ints, Floats, Strings, and types that adopt `Ordered`" wording). Without a
  change, `largest([3, 9, 4])` would be rejected: the constraint would refuse the most common
  arguments. The change is a fixed table of which built-ins satisfy `Ordered`, `Equatable`,
  `Hashable`, and `Textual`, and real `compare`, `equals`, and `hash` members on them, so a
  constrained body that calls `a.compare(b)` works for every argument. The members are small
  and useful on their own, and are written in the three places the built-in-members rule
  names (the checker, the interpreter, and the hint text) plus the docs. The table starts from
  8.3 and 8.4: scalars and strings are keys, and a `Float` is a key except NaN, so whether
  `Float` is `Hashable` (its `hash` refusing NaN at run time) is a question for slice 0, as is
  whether tuples and collections of satisfying types satisfy `Equatable`.
- **A constraint is checked at every use**: `largest(players)` fails with a message naming
  `Player` and the fix (section 6) if `Player` does not adopt `Ordered`.
- **Callbacks stay available.** Nothing stops a body taking a function instead of a
  constraint, as `sort_by` does. Constraints are for the common case where the order belongs
  to the type.

### 5.3 What an unconstrained parameter can do

Only what is true of every type: declare a field, parameter, local, or return of that type;
assign; pass; return; put it in a `List`, a tuple, an optional, or a `Dict` value; display it;
and pass it to another generic that places no constraint on it. It cannot use `==`, `<`, or
member access, cannot be a `Dict` key or `Set` element, and cannot call the built-in list
methods that need equality, order, or hashing (`contains?`, `remove`, `sort`, `min`, `max`,
`unique`, `frequencies`, and the rest the checker already guards for concrete elements).
A generic body is checked once, at its definition; a use is checked against the substituted
types.

**This is the largest implementation cost.** Those requirements are ad hoc checks scattered
through the checker (around `Checker.zig` 7609 to 8126), not one table. Each must become
"requires `Equatable`" or "requires `Ordered`" for a type parameter, and the error names the
missing constraint rather than the method. Slice 0 inventories them.

### 5.4 Writing and inferring uses

Type arguments are written in annotations and inferred from arguments; they are never written
at a call.

```emerald
const board: Grid[String] = Grid(3, 3, ".")    # annotation, as Channel does
const history = History("")                      # inferred from the argument: History[String]
const best = largest([3, 9, 4])                  # inferred: T is Int
const empty: Chain[Int] = Chain.end              # expected type flows in
```

- This is 15.13's rule for `Channel`, extended. It avoids `Stack[Int]()`, whose callee is
  indistinguishable from indexing `Stack` and would need the expression-level type arguments
  15.13 declined. It is the rule most likely to surprise someone who knows C# or Java, so the
  guide states it up front.
- Inference collects what each argument says about each parameter, left to right. An argument
  that says nothing (`[]`, `nothing`, a bare `Chain.end`) is skipped, and the rest or the
  expected type must determine every parameter. Where they do not, the error names the missing
  type and shows the annotation. A block's parameter types come from parameters already
  decided to its left, as for built-in methods today.
- A bare capture of a generic function (`const f = largest`) has the same fate as a bare
  capture of `numbers.map` (7.4): it needs an expected callable type. Emerald does not make
  implicitly generic callables.
- A generic type name without its arguments in an annotation (`var s: Stack`) is an error that
  shows the full spelling.

### 5.5 Optionals

A type argument may not itself be optional, so `Stack[Int?]` is rejected with advice to wrap
the value in a struct or use a different shape. 4.5 forbids nested optionals, and a body
routinely writes `T?` (as a `pop` does); with `T = Int?` it would be a nested optional and an
empty result could not be told from a stored `nothing`. `Channel[T]` made the same choice for
the same reason. The restriction can be relaxed later without breaking any program; the
reverse cannot.

### 5.6 Numbers across type arguments (a real hazard)

The interpreter's `widen` runs from a declared `Value.Kind`, so a field, element, or
parameter declared `Float` converts an `Int` handed to it. An erased `T` has no kind, so
`prices.push(5)` on a `Stack[Float]` would leave an `Int` inside it, and the next division or
display would behave differently. Recommendation: the checker records the target type at each
call that crosses a type argument and the interpreter widens there, matching
`List[Float].append(5)` exactly. The fallback is to reject with a teaching error ("`push`
needs a `Float` here. Write `5.0`"), which is easy to build but a surprise beside
`List[Float]`; if the fallback ships, tell the user, since it is a temporary inconsistency
with the built-in collections.

### 5.7 Runtime model

The interpreter erases: a `Chain[Int]` and a `Chain[String]` run the same code, and a value
keeps its own kind. The language promises nothing that differs between erasure and per-type
copies, which is exactly what the non-goals forbid (a type parameter is never a value, never
tested at run time, never reflected). Consequences:

- `Grid[Int]` and `Grid[Float]` are unrelated types; assigning one to the other is an error
  that suggests converting the contents.
- A struct held by `T` is still copied and a class still shared; the runtime value carries
  which it is. A conformance case checks both, because this is the kind of behavior a host
  can silently get wrong.
- **Operators in a generic body must dispatch on the runtime value**, not the static type.
  `value < item` with `T with Ordered` runs a native comparison for an `Int` and `compare`
  for a struct, and `==` runs structural, identity, or custom equality. If the interpreter
  chooses these from the checker's static type today, a generic body needs a runtime path.
  Slice 0 measures this.
- `is Grid[Int]` cannot be answered once types are erased, so it is rejected for now.
- `case` over a generic enum behaves as today; `when Chain.link(item, rest)` binds `item`
  as `T`.

## 6. Diagnostics (written first)

Wording is product behavior, so these are drafted before the checker and become
`diagnostics/` `.expected` files. They are proposals, not a captured run.

A mistake in a definition:

```
error: `T` has no order
  --> largest.em:9:12
   |
 9 |         if item > best {
   |            ^^^^^^^^^^^
note: `T` could be any type, and not every type can be compared with `>`.
help: write `T with Ordered`:  func largest[T with Ordered](items: List[T])
```

A use that does not satisfy a constraint:

```
error: `largest` needs items that can be put in order, and `Player` cannot
  --> main.em:14:21
   |
14 | const best = largest(players)
   |                      ^^^^^^^
help: add `with Ordered` to `Player` and write a `compare(other: Self): Int` method
```

Inference that cannot decide:

```
error: Emerald cannot tell what kind of item this holds
  --> main.em:3:15
   |
 3 | const stack = History()
   |               ^^^^^^^^^
help: write the type you want:  const history: History[String] = History()
```

Wrong number of types, an optional type argument, a type parameter named like a real type, an
unused type parameter, a second trait in one parameter, and a missing argument list each get a
similar plain message. None uses "bound", "unify", "generic", "instantiate", or "type
variable"; where a word is needed it is "type" or "the kind of item".

## 7. Nine programs to read cold

Read them without this plan beside you. Does each beat the copy-and-paste version? Syntax
follows section 5 and the current language (`case ... when ... then`, `const` members,
`return ... if` guards); with concrete types in place of the parameters, all nine ran (see the
top). Programs 6 and 7 are the stress tests: the
first because it is a constrained, recursive enum with a recursive method, the second because
it has two parameters and a block.

**1. A linked list as an enum**

```emerald
enum Chain[T] {
    end
    link(item: T, rest: Chain[T])

    const length: Int {
        return case self {
            when Chain.end then 0
            when Chain.link(_, rest) then 1 + rest.length
        }
    }
}

const numbers = Chain.link(1, Chain.link(2, Chain.end))
print(numbers.length)
```

**2. A grid of anything** (a game board, a map)

```emerald
class Grid[T] {
    const width: Int
    const height: Int
    var _cells: List[T] = []

    constructor(width: Int, height: Int, fill: T) {
        self.width = width
        self.height = height
        for index in 0..<width * height {
            self._cells.append(fill)
        }
    }

    func get(x: Int, y: Int): T {
        return self._cells[y * self.width + x]
    }

    func set(x: Int, y: Int, cell: T) {
        self._cells[y * self.width + x] = cell
    }
}

const board = Grid(3, 3, ".")        # Grid[String]
board.set(1, 1, "X")
print(board.get(1, 1))
```

**3. An undo history**

```emerald
class History[T] {
    var current: T
    var _undo: List[T] = []

    constructor(start: T) {
        self.current = start
    }

    func record(state: T) {
        self._undo.append(self.current)
        self.current = state
    }

    func undo() {
        return if self._undo.empty?()
        self.current = self._undo.remove_last()
    }
}

const text = History("")
text.record("Hello")
text.undo()
print(text.current)
```

**4. The largest of anything with an order**

```emerald
func largest[T with Ordered](items: List[T]): T? {
    if items.empty?() {
        return nothing
    }
    var best = items[0]
    for item in items {
        best = item if item > best
    }
    return best
}

print(largest([3, 9, 4]), largest(["pear", "fig"]))
```

**5. A cache keyed by anything hashable**

```emerald
class Cache[K with Hashable, V] {
    var _entries: Dict[K, V] = []

    func get(key: K): V? {
        return self._entries[key]
    }

    func put(key: K, value: V) {
        self._entries[key] = value
    }
}

const ages: Cache[String, Int] = Cache()
ages.put("Ava", 12)
```

**6. A binary search tree**

```emerald
enum Tree[T with Ordered] {
    empty
    branch(left: Tree[T], item: T, right: Tree[T])

    func inserted(value: T): Tree[T] {
        case self {
            when Tree.empty {
                return Tree.branch(Tree.empty, value, Tree.empty)
            }
            when Tree.branch(left, item, right) {
                return Tree.branch(left.inserted(value), item, right) if value < item
                return Tree.branch(left, item, right.inserted(value))
            }
        }
    }
}

var words: Tree[String] = Tree.empty
words = words.inserted("pear").inserted("fig")
```

**7. A method with its own type, and a block**

```emerald
class Box[T] {
    const value: T

    func mapped[U](change: func(T): U): Box[U] {
        return Box(change(self.value))
    }
}

const name = Box("Ava")
print(name.mapped { text => text.count }.value)
```

**8. A user-defined result**

```emerald
enum Outcome[T] {
    success(value: T)
    failure(message: String)
}

func half(number: Int): Outcome[Int] {
    return Outcome.failure("odd") if number % 2 != 0
    return Outcome.success(number // 2)
}
```

(Typed errors remain the recommended way to fail; this shows what a student could build, not a
preference over the built-in way.)

**9. Floats through a type argument** (the widening hazard)

```emerald
const readings: Grid[Float] = Grid(2, 2, 0)    # 0 widened to 0.0, like List[Float]
readings.set(0, 0, 5)                           # 5 widened to 5.0
```

## 8. Permanent non-goals

Decided now so they never need re-arguing: variance and wildcards; type arguments written at a
call or construction; `where` clauses and more than one trait per parameter in the bracket
list; default type parameters and value parameters (`Matrix[3]`); generic lambdas; associated
types and higher-kinded types; specialization and overloading; using a type parameter as a
value (`T()`, `T.zero`, `x is T`) or reflecting on it; a built-in generic `Result` or `Option`.
Needing one is the signal that the feature is growing past its size.

Deferred rather than refused: generic traits and inheritance involving a generic class
(decision 10), each needing its own argument and program.

## 9. Build order, if the gate is met

Each slice ends runnable, with conformance cases, `docs/handoff.md`, and the journal updated in
the same commit. Branch `claude/generics`, worktree under `~/.cache/emerald-worktrees/`.

**Slice 0: no code.** The wall log, the cold reading of section 7, and an inventory of every
checker rule that depends on equality, order, or hashing for a type parameter (section 5.3),
each written as "`T` could be any type". Decide the built-in conformance table (5.2), measure
whether operator dispatch in an erased body needs a runtime path (5.7), and measure the effort
of recording widening at a call (5.6). Update this plan with what is found and mark it
`accepted` or shelve it.

**Slice 1: generic structs and classes, unconstrained.** Parser (`[T]` on declarations and in
types), AST, resolver (type-parameter scope), `Type` (a parameter kind and a type's
arguments), checker substitution through fields and members, construction by annotation and by
argument inference, the erased interpreter and its widening, formatter. Programs 2, 3, and 9
run. The rules of 5.3 are enforced before constraints exist, so an unconstrained `==` is
already an error.

**Slice 2: generic functions and methods.** Inference from arguments and expected type, a
block's parameter types, the "cannot tell" diagnostic, and the bare-capture rule. Programs 7
and 8 (function) run.

**Slice 3: constraints.** `with` on a parameter, the built-in conformance table, `compare`,
`equals`, and `hash` on the built-ins (three places plus docs), constraint checks at uses, and
runtime operator dispatch in generic bodies. Programs 4 and 5 run.

**Slice 4: generic enums.** Programs 1, 6, and 8, with `case` over generic data enums and the
recursive cases.

**Slice 5: editor support, teaching, fuzzing.** Hover, completion, signature help, go to
definition, and rename for a type parameter and a generic type, and completion of a
constraint's members inside a body (`item.compare(...)` for `T with Ordered`); one guide page
after traits, because a constraint is a trait (it starts from `List[Int]` already being a
generic with one parameter, then `Grid`, then `largest`, and says in a sentence that Emerald has
no wildcards and never asks you to write a type argument at a call); `examples/generics.em`;
fuzz templates; and `bash tools/check-doc-examples.sh`. The known gap (named labels at call
sites are untracked) is unrelated and stays open. Built-in members that gain `compare`,
`equals`, or `hash` are documented with the rest of their pages.

Each slice's review reads the whole diff, runs real programs, and uses `/code-review` at high
effort, per `AGENTS.md`. The large files (`Checker.zig`, `Interpreter.zig`, `Parser.zig`,
`Lsp.zig`) repeat patterns, so every scripted edit has its diff checked.

## 10. What this plan deliberately leaves out

- Anything in section 8.
- A generic rewrite of `List`, `Dict`, `Set`, `Task`, or `Channel`: they keep their built-in
  spellings (8.2), per rewrite-context 23, item 5.
- User-defined iterables, a separate deferred feature (11.3).
- `@operator` annotations on a generic type, until a program needs them.
- The compiler decision: this plan constrains it and does not make it.

## Open questions for the user

1. **The deciding question:** is Emerald a first-course language, or does it carry students into
   data structures? This sets how seriously to take the wall.
2. **Reserve the syntax now** (section 4), independent of everything else? Recommendation: yes.
3. **Gate:** is "a dozen wall-log entries across three shapes, or one program you want to ship"
   the right bar, and who keeps the log?
4. **One trait per parameter,** composing a trait for more (5.2). Recommendation: yes.
5. **Optional type arguments:** reject (recommended) or allow with the dictionary-style collapse?
6. **Float widening:** record it (recommended) or reject for now?
7. **Names in the guide:** `T` as written, or descriptive (`Item`)? Recommendation: teach
   descriptive names, allow either.

## Settled while building

(Empty until accepted and built.)
