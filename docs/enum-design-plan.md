# Data-carrying enums: design and implementation plan

Status: accepted, 2026-10-15. Codex wrote this plan (proposed 2026-10-13); the user
accepted all nine recommendations as amended below and assigned implementation to
Claude, now the only programming agent.

Amended 2026-10-15 by Claude at the user's request: a data choice is no longer a
value without a call (decision 2), and a binding name that is another position's
data label is an error (decision 3). The reasons are in those sections.

The user liked the declaration, construction, and `case` syntax below after
working through examples from a C# enum starting point. Treat that as the working
direction; the complete behavior and boundaries below are still recommendations.
The source evidence is in [enum-source-review.md](enum-source-review.md), checked
against main `5fb9f92`. Rewrite-context sections 6.3, 8.3, 8.4, 10.5, 12, and
15.9–15.11 remain the current specification until accepted behavior is implemented.

## The feature in plain words

An ordinary enum gives names to a fixed set of choices. A data-carrying enum also
keeps the information that belongs to each choice. A finished download has a saved
path; a failed download has an error message. The program cannot accidentally
represent a finished download without a path.

```emerald
enum Download {
    waiting
    finished(path: String)
    failed(message: String)
}

var download = Download.waiting
download = Download.finished("report.pdf")

case download {
    when Download.waiting {
        print("Waiting to download")
    }
    when Download.finished(path) {
        print("Saved to #{path}")
    }
    when Download.failed(message) {
        print("Download failed: #{message}")
    }
}
```

Every value here has type `Download`. `finished` is a choice, not a separate
subclass or a new public type. In the matching branch, `path` is a new, read-only
local name for the saved path. Outside that branch, it is not available.

**All programs using the new syntax in this plan are proposed examples. They have
not been compiled by today's Emerald.** Intended output is a requirement for the
implementation, not a report of an existing run.

## Recommendations at a glance

| Decision | Recommendation |
| --- | --- |
| 1. Declarations | Keep existing bare choices; add named, typed, required data in parentheses. No defaults or empty parentheses in this milestone. |
| 2. Construction | Use ordinary positional/named calls. A choice with data is not a value until it is called, as a struct type is not; wrap it in a lambda to pass it along. |
| 3. Reading data | Match an explicitly named choice in `case`; introduce positional names or `_`, available only in that branch. A name that is another position's data label is an error. |
| 4. Matching and coverage | Data-choice matches select the choice itself, not equality of its contents. Preserve ordinary expression alternatives and existing exhaustiveness rules. |
| 5. Values and members | Read-only data and bindings, ordinary value/reference semantics, existing enum methods and traits. Recursive data is allowed without new syntax. |
| 6. Equality, keys, and display | Compare choice plus data by default; check every choice's data for key eligibility; display the choice and labelled contents. |
| 7. Saving and tables | Preserve plain enums. Reject data-carrying enum types in automatic JSON/CSV conversion and typed Console tables for now. |
| 8. Editing | Include formatting, navigation, hover, completion, signature help, and rename for declarations and branch bindings. |
| 9. Scope | Deliver this feature independently of generics, general pattern matching, enum reflection, and raw integer/flags enums. |

## 1. Declaration syntax

**Recommendation: data looks like a short parameter list.**

```emerald
enum Action {
    move(x: Int, y: Int)
    say(text: String)
    wait
}
```

- Each data item has a name and an explicit ordinary Emerald type. Inference
  cannot supply a declaration's data types from its later uses.
- Every item is required; no default expressions in this milestone. This avoids
  adding default evaluation, hidden construction work, and all-default choices
  before a program earns them. Ordinary function defaults are unaffected.
  An optional data item still needs an argument; pass `nothing` explicitly when
  it is absent.
- Write a choice without data as `wait`, never `wait()`. A parenthesized
  declaration must contain at least one item.
- Item names are unique within that choice. Different choices may reuse names.
  They are parameter labels, not members shared across the enum: a data name may
  also be used by another choice or by an explicitly declared enum property.
- Choice names remain in the enum's existing member namespace; a choice cannot
  collide with another choice, method, property, type-level member, or nested type.
- Choices still come first, one per line or comma-separated, before other members.
  No `case`, `const`, or `var` keyword is added to a choice declaration.
- All currently permitted ordinary parameter types are allowed, including
  optionals, collections, tuples, functions, classes, traits, tasks, and channels.
  No source-visible `Any`, nested optionals, or user generics are introduced.
- `Self` keeps its existing restriction to method/function signatures; a recursive
  data declaration writes its enum's name explicitly.
- Existing namespace, alias, nested-type, privacy, naming, and nesting rules apply.
  A leading `_` on a choice retains member privacy. Data labels follow parameter
  rules; they do not become private fields merely because of their spelling.

**Reason:** students can read the information each choice needs directly from its
declaration, without learning field bodies, constructors, or extra punctuation.

## 2. Construction

**Recommendation: use Emerald's existing call rules, including the rule that a
type's constructor is not a value.**

```emerald
const first = Action.move(2, 3)
const second = Action.move(y: 3, x: 2)
const third = Action.say("Hello!")
const pause = Action.wait
```

The same positional-before-named, unknown-name, duplicate-argument, arity, and
type rules apply as in an ordinary declared call. Named arguments do not change
evaluation order: evaluate argument expressions once in source order, then store
their values in declaration order. Apply expected types to literals/lambdas and
the existing Int-to-Float widening. Construction returns the enum type; it does
not return a choice-specific public type. Type-level setup keeps existing
first-use ordering and diagnostics.

`Action()` remains invalid. Calling `Action.wait()` is invalid and should suggest
removing the parentheses. Writing a data choice without a call is an error, as
writing a struct type without a call is today (`const make = Point` reports
"`Point` is a type, not a value"). A program that needs to pass construction
along writes a lambda:

```emerald
const say: func(String): Action = { text => Action.say(text) }
print(say("Hello!"))
```

Function-valued data may be supplied through the existing trailing-block call
syntax when it is the final parameter. That remains an ordinary argument, not an
enum-specific body or initializer. No partial application, overloads, user-written
choice constructors, or validation blocks are added. A program needing validation
can write a normal function that returns the enum.

**Reason:** the construction call is the same shape as a struct's, so it follows the
struct's rule. A choice that could be stored without a call while a struct cannot
would be the inconsistency. No teaching program needs it, and a lambda already says
the same thing. Allowing it later is a small addition; removing it after 1.0 would
break programs (principle 7).

## 3. Branch bindings

**Recommendation: introduce one name, or `_`, for each data position.**

```emerald
case action {
    when Action.move(destination_x, destination_y) {
        print("Move to #{destination_x}, #{destination_y}")
    }
    when Action.say(text) {
        print(text)
    }
    when Action.wait {
        print("Wait here")
    }
}
```

The names can differ from the declaration's labels. Their types come from the
choice declaration, and their values come from the already-evaluated subject.
No call is executed to produce a comparison value for these alternatives.

- Exactly one name or `_` per position; no names, types, or labels are optional.
- `_` discards that position and declares nothing. It may occur more than once.
- Named arguments, type annotations, `var`/`const`, literals, nested patterns,
  guards, and arbitrary expressions inside a binding list are not supported.
- Names act as ordinary `const` locals. Ordinary duplicate/shadowing rules apply;
  sibling branches may reuse names. A match does not create a function boundary
  or an exception to the existing rule against shadowing a visible local within
  the same function.
- The scope includes the selected block's statements or its `then` expression,
  and closures created there. It excludes the subject, other alternatives,
  sibling arms, `else`, and everything after the case.
- A binding is always new. It never assigns an outer variable with the same name,
  or treats that name as a value to compare. A duplicate name such as `move(x, x)`
  is an error.
- A binding name that is the declared label of a *different* position in the same
  choice is an error. With `move(x: Int, y: Int)`, `when Action.move(y, x)` would
  otherwise put the `x` value in a name called `y`, silently, since both are `Int`.
  The name of a position's own label, any name that is no label of this choice,
  and `_` are all accepted, so `move(x, y)`, `move(destination_x, destination_y)`,
  and `move(_, y)` are fine. This is a check on names only; no labelled-binding
  syntax is added.
- A data-choice match is the only alternative in its `when` arm, even if every
  position is `_`. Separate branches avoid rules for merging different bindings.
  Existing comma-separated ordinary alternatives remain supported.
- Even if every choice happens to declare `path`, this does not create a common
  `.path` field. Explicitly declared enum methods/properties remain accessible
  in the usual way; they can use `case` internally to read the data.

Both current case forms work:

```emerald
func describe(download: Download): String {
    return case download {
        when Download.waiting then "Waiting"
        when Download.finished(path) then "Saved to #{path}"
        when Download.failed(message) then "Failed: #{message}"
    }
}
```

**Reason:** "choose the possibility, then use its information" is one rule. No
new optional access operator, unchecked extraction operation, or subtype test is
needed. Bindings are positional, so the swapped-label check catches the one
positional mistake whose result has the right types and the wrong values, which
nothing else in the checker would report.

## 4. Choice matching, ordinary alternatives, and coverage

**Recommendation: make the contextual meaning precise while retaining existing
case behavior.**

In a subject case, a call-shaped alternative whose callee resolves directly to a
data-carrying enum choice is a binding match. For example,
`when Download.finished(path)` checks the enum identity and choice, then binds
the stored path. Grouping parentheses do not turn that syntax into construction.
Recognition uses resolved declarations, never capitalization or raw string keys.
Existing aliases of the enum type and qualified/nested paths must work.

All other alternatives retain their ordinary expression behavior. To compare
with a particular already-created enum value, name it:

```emerald
const wanted = Download.finished("report.pdf")
case download {
    when wanted {
        print("Exactly the result wanted")
    }
    else {
        print("Something else")
    }
}
```

An ordinary function call such as `when expected_download()` still evaluates and
compares its result by `==`. A call through a stored lambda that builds a choice is
also an ordinary expression, not binding syntax; its arguments must refer to
existing values. Only an explicitly resolved choice selects the binding form. A subjectless
case still requires Bool conditions and provides no choice-binding form.

This adds one deliberate exception to section 6.3's equality-based alternatives:
**data-choice binding matches select by choice identity**, regardless of carried
values or custom `Equatable`. Ordinary alternatives, including existing bare
data-free enum constants, keep their equality semantics. Do not change old enums'
matching behavior under a custom equality trait as part of this feature.

Coverage rules:

- A data-choice binding match covers that entire choice. A bare data-free choice
  continues to count as it does today. A variable or ordinary call comparing one
  value does not prove coverage of every value of its choice.
- Preserve subject evaluation once, left-to-right alternatives, first match,
  no fall-through, and no evaluation of unchosen bodies.
- Preserve errors for incomplete value cases and warnings for incomplete statement
  cases without `else`. An explicit `else` accepts the remainder as today.
- An optional enum subject additionally needs `when nothing` or `else`. Data that
  is itself optional stays optional when bound; matching the choice does not
  prove that an optional item is present. Binding matches give types to the new
  names, not a choice-specific type to the subject. Preserve today's subject-case
  narrowing behavior; use a normal presence guard before accessing a still-optional
  subject's common members.
- Two binding matches for the same choice are an error, since the first handles
  every value of that choice. Existing duplicate-known-alternative rules remain.
  Do not add speculative warnings for unknown dynamic alternatives.
- Exhaustive cases continue to establish definite assignment, return coverage,
  and unreachable-code facts. `then` arms retain expected types, branch-result
  unification, numeric widening, and optional result behavior.

Further checks of data use ordinary `if` inside the selected branch. They do not
make a later match for the same choice reachable: the first branch already ran.

**Reason:** simple whole-choice matching is sufficient for the examples and makes
exhaustiveness explainable without introducing a general pattern language.

## 5. Values, references, members, and recursion

**Recommendation: follow the value rules already taught for structs and parameters.**

Data items cannot be reassigned through an enum value. Extracted collections and
structs are read-only local values; an explicit `var` copy can be changed without
changing the enum's stored value:

```emerald
enum Guests {
    named(names: List[String])
}

const guests = Guests.named(["Ada"])
case guests {
    when Guests.named(names) {
        var updated = names
        updated.append("Grace")
        print(updated)
    }
}
print(guests)
```

Intended output:

```text
["Ada", "Grace"]
Guests.named(names: ["Ada"])
```

Read-only is not deep freezing. A class object remains shared, exactly as it does
inside a struct or through a const parameter. Calling its changing methods can
change the shared object. A carried closure, channel, or task keeps its existing
identity, capture, and ownership rules. No additional task-sharing promises arise.

Enums retain existing methods, computed properties, type-level members, nested
types, and trait adoption. They still have no ordinary stored instance fields,
inheritance, or enum-wide custom constructor. This plan does not enable arithmetic
operator annotations on enums. Existing type tests test the enum, not a choice;
`download is Download.finished` is invalid because the choice is not a type.

Recursive data uses ordinary type names:

```emerald
enum Chain {
    end
    link(number: Int, next: Chain)
}

const numbers = Chain.link(1, Chain.link(2, Chain.end))
```

Self-reference and mutual reference are allowed after type registration, as for
existing compound types. Optionals and empty containers may also end a chain.
Do not add an analysis proving that every declared recursive type can have a
finite value, and do not introduce a new public recursion limit. Existing source,
runtime, and traversal limits continue to apply and must fail safely. Test modest
recursive values, including a recursive enum inside a struct and vice versa.

## 6. Equality, dictionary keys, and display

**Recommendation: extend existing structural behavior.**

Default equality requires the same enum, the same choice, and pairwise equal data:

```emerald
print(Download.finished("a.pdf") == Download.finished("a.pdf")) # true
print(Download.finished("a.pdf") == Download.finished("b.pdf")) # false
print(Download.finished("a.pdf") == Download.failed("a.pdf"))   # false
```

Contained values use their existing equality rules, including normalized strings,
custom equality, and class identity. Existing explicit `Equatable`/`Hashable`
contracts remain available; this plan does not impose a new rule requiring custom
equality to preserve choice identity. Binding matches still identify the actual
choice, as decision 4 specifies. Declaration order creates no ordering; use
`Ordered` as today.

An enum is eligible as a dictionary/set key only when **every data item of every
choice** passes the current key rules, along with the existing equality/hash trait
requirements. Eligibility belongs to the enum type, not to the currently stored
choice. A data-free choice of an enum with a List-carrying choice does not turn
that enum type into a valid key. Recursion, optionals, functions, mutable class
objects, and collections retain the same conservative rejection as corresponding
stored fields do today. Custom hashing does not waive those existing field checks.
Ordinary data-free enums keep their current eligibility.

Default display includes the enum's existing display name, choice, and labelled
data in declaration order:

```text
Download.waiting
Download.finished(path: "report.pdf")
Action.move(x: 2, y: 3)
```

Nested contents use existing quoting and display rules. `Textual` still replaces
ordinary display when explicitly adopted. Diagnostic rendering never calls user
code. Cyclic object graphs and excessive recursive display must retain existing
safe behavior; no new printing convention or public identity is invented.

## 7. JSON, CSV, and Console tables

**Recommendation: do not design a saved-data format in this milestone.**

Today's JSON/CSV conversion represents an enum as its choice name. That cannot
represent a path or error message. For an enum with any data-carrying choice:

- Reject automatic `Json.encode`/typed `Json.decode` at checking time, including
  nested occurrences in lists, dictionaries, and records.
- Reject that enum as a CSV record field in typed `Csv.encode`/`Csv.decode`.
- Reject it as a field of a typed `Console.table` row, since table eligibility
  currently shares CSV's scalar-field rules. Text rows remain available.
- Check the entire static enum type, even when the particular value is a
  data-free choice. Neither `Textual` nor custom equality bypasses this rule.
- Preserve every existing plain enum representation, decoder, and native use,
  including `Json.Kind`, `Console.Color`, and `Weekday`.

A program can explicitly map an enum into a supported plain record or text using
`case`, or build a JSON document with the existing `Json` API. Text is useful for
display, but do not suggest it as an automatic lossless decoder format.

The diagnostic explains that saving only the choice name would lose its data and
suggests explicit conversion. A future automatic representation needs a separate
small design covering tags, data names, missing fields, and compatibility. This is
a visible limitation to accept or change before implementation, not a silent
implementation shortcut.

## 8. Formatting and editor support

**Recommendation: editing support is part of the feature.**

- Format typed data declarations, calls, and match bindings with existing spacing
  and project brace style. Preserve comments, required grouping, and multiline
  parameter syntax. Preserve the formatter's existing list-layout rule: a plain
  comma-separated run written on one line stays on one line; multiline runs and
  comments use the existing separated layout. Extend full choice spans and data
  printing rather than changing old enum formatting goldens.
- Enum outline symbols retain enum-member identity. Their source ranges include
  the full data declaration; hover shows its signature and attached `##` comment.
- Construction completion offers the declared choices and their signatures.
  Inside a matching header, completion/signature help describes binding positions
  and their types, not values to evaluate as arguments.
- Hover on a bound name shows its inferred type and read-only status. Local
  completion includes it only in its branch, including a `then` expression.
- Go to definition and references work for the enum, choices, written data-type
  annotations, named construction labels, and branch bindings.
- Renaming a choice updates its construction and matching uses.
  Renaming a declaration's data label updates named construction argument labels;
  it does not rename independently chosen branch names. Renaming a branch binding
  updates only that binding's uses and captures.
- Unfinished declarations/calls/matches return helpful partial information where
  the existing LSP permits it, and never panic. Preserve ordinary call signature
  help and dynamic-alternative navigation.
- User-declared choice metadata belongs to source/checker facts, not the native
  `builtins.json` catalog. Keep source spans and resolver targets explicit.

Assess the sibling extension's lexical grammar/snippets with its own instructions
before changes. Keep syntax colouring lexical; do not add compiler logic to the
extension. Update the website's enum/case lessons and JSON/CSV/table eligibility
descriptions once the implementation is reviewed.

## 9. Boundaries

This milestone adds data to existing enums. It does not add:

- user generics or a built-in generic Result/Option type;
- nested, literal, range, class, or user-defined patterns, pattern guards,
  destructuring outside `case`, or subjectless choice matching;
- choice subtypes, checked casts to a choice, or optional direct data properties;
- choice-data defaults, overloads, custom constructors, setters, or annotations;
- a data choice used as a value without a call;
- integer backing, flags, implicit integer conversion, automatic choice lists,
  enum iteration, or automatic text parsing;
- automatic data-carrying enum serialization, a package system, a new backend,
  or multicore rules.

These need their own demonstrated use, rather than extra machinery in this plan.

## Diagnostics contract

Wording below is proposed. Preserve Emerald's primary-error-first behavior,
source spans, severity/exit rules, and existing close-name suggestions. Golden
tests must cover both the explanation and correction; avoid cascades from a
malformed declaration or binding.

| Mistake | Primary explanation and correction |
| --- | --- |
| `finished(path)` in a declaration | “The data item `path` needs a type. Write `path: String`, or another type.” |
| `waiting()` in a declaration | “This choice carries no data. Write `waiting` without parentheses.” |
| A default such as `move(x: Int = 0)` | “Enum data items need a value when the choice is created. Remove the default and pass `x`, or write a normal factory function.” |
| `Download.finished()` | “`Download.finished` needs a value for `path`. Supply a String, such as `Download.finished("report.pdf")`.” |
| `Action.move("left", 3)` | “This is String, but `x` of `Action.move` needs Int.” Point at the argument and suggest a whole number. |
| `Download.waiting()` at a use | “`Download.waiting` is a value, so it takes no parentheses. Remove `()`.” |
| `const say = Action.say` | “`Action.say` needs its data before it is a value. Call it, as in `Action.say("Hello!")`, or wrap it: `{ text => Action.say(text) }`.” |
| Unknown/duplicate named arguments | Reuse the ordinary declared-call diagnostic, naming the choice and its data label. |
| `download.path` with no declared property | “A Download does not always have a path. Handle `Download.finished(path)` in a `case` to read its data.” |
| `when Download.finished` | “This choice carries data. Write `Download.finished(path)`, or `Download.finished(_)` to ignore it.” |
| Wrong binding count | Name the choice, the required number of names, and the number provided; suggest names or `_` for every position. |
| `when Action.move(0, y)` | “This position introduces a name, but `0` is a value. Use a name or `_`; check the value with `if` inside the branch.” |
| `when Action.move(x, x)` | “`x` is already introduced by this match. Use different names, or `_` to ignore a position.” |
| `when Action.move(y, x)` | “`y` is the second item of `Action.move`, but here it names the first. Write `Action.move(x, y)` in declaration order, or choose names that are not its labels.” Point at each misplaced name. |
| A binding shadows a visible local | Retain the existing shadowing rule and recommend a different new name; do not silently treat it as assignment. |
| Mixing a data match with comma alternatives | “A choice carrying data needs its own `when` arm. Give each choice a separate branch.” |
| Reassigning/mutating a bound value | Explain that the name is read-only; suggest a `var` working copy for collection/struct changes. Class-object mutation retains ordinary behavior. |
| A repeated whole-choice match | “An earlier arm already handles every Action.move. Remove this arm, or make the additional decision inside the earlier branch.” |
| An enum with unsuitable key data | Identify the choice and item, such as `Guests.named.names`, whose List type cannot be a key. Do not say that every enum value is an eligible key. |
| Missing choice/absence | Keep the existing case diagnostics, listing missing choices and `nothing`; suggest a matching arm or the appropriate `else` form. |
| Binding name used after the case | Explain branch-local scope in the undefined-name help when the name's matching declaration is known; never offer a fix making it accidentally global. |
| Automatic serialization/table field | Identify the enum and nested field path, explain that it carries data, and suggest explicitly producing supported records or text. |

## Implementation approach

The source review supplies the entry points. The following are implementation
constraints, not public syntax choices:

1. Record explicit choice declarations (name, full span, data labels/types, stable
   choice position) and explicit checked match metadata. Do not simulate data
   choices as ordinary stored fields or user class hierarchies. Preserve enum
   choice declaration targets and existing type-level setup facts.
2. Register enum identities before resolving data types. Keep per-choice data
   types separate from `Type.User.fields`, which describes common instance fields.
   Key eligibility and serializer guards must inspect those per-choice types,
   after their resolution is complete. Forward declarations must not pass a check
   merely because their metadata is still empty; include later-file and mutually
   referring declarations in the tests.
3. Reuse the shared argument binder and expected-type checker. A data choice
   resolves only as a call's callee; it must not acquire user-visible generic or
   native machinery.
4. The parser must preserve ordinary expression alternatives without consulting
   symbol tables. Resolution distinguishes direct choice-match candidates from
   real calls before resolving the candidate names as variable reads. Checked
   choice identity, data positions/types, and binding targets survive to execution.
5. Evaluate a case subject once and retain it through selection and binding.
   Transfer/retain stored data into a branch environment before releasing the
   subject. Manage scopes in both block and value arms, including returns,
   exceptions, cancellation, and escaping closures.
6. Reuse managed enum storage where sound, with one enum identity and per-choice
   metadata. The collector must see every data value; arrays of metadata must not
   be confused with arrays of managed references. Allocation failure must not
   double-release values after ownership transfers to the heap.
7. Update every relevant AST walker: height/nesting checks, mutation and capture
   analysis, case completion/flow, formatting, LSP traversal, and prelude AST
   serialization through its generator. Preserve AST-node keyed typed-call facts.
8. Choices are type-level `const` fields today (`StructDeclaration.TypeField` with
   `enum_value`), each initialized once to a shared value by `evaluateEnumValue`.
   A data choice has no single value, so it cannot reuse that initializer. Do not
   model it on `type_functions` either: a type-level function is already a value
   (`const f = V.origin` runs on main `3e2d2bf`), which would let `Action.say`
   through silently. A data choice read without a call must reach its own error
   in `typeOfMember`, next to the existing "is a type, not a value" diagnostic.
9. The swapped-label check belongs where binding names are first known: the
   resolver's `walkCase`, which today walks every alternative as an ordinary
   expression and opens no scope for a `then` arm. Coverage needs no new key:
   record the choice's existing `Resolver.methodKey(enum, choice)` in
   `checkAlternative`'s `covered` set, which `caseCoverage` already lists from.
   The heap copies an instance's own `fields` length (`Heap.uniqueStruct`), so
   per-choice data lengths need no layout change; the JSON and CSV guards are the
   single `user.enumeration` acceptances in `Checker`'s two eligibility functions.
10. Preserve REPL descriptor/code origins, captures escaping failed entries, and
    existing native enum choice numbers. Test channel transmission with managed
    and optional data. No scheduler changes are a prerequisite.

## Runnable implementation slices

Build on `claude/enum-data`, one focused commit per slice with its validation in
the message. Update the plan's “Settled while building” notes, handoff, and
journal in each implementation commit. If the plan disagrees with the source,
record the mismatch here; decide routine matters by Emerald's philosophy and ask
when accepted language behavior would change. Self-review the whole branch as
AGENTS.md describes before its pull request. Complete the milestone before
presenting it as generally available.

### Slice 1: Data declarations, construction, and value safety

- Add choice declarations, type metadata, direct construction (and the error for
  a data choice used without a call), all ordinary allowed data types, ownership, display, equality,
  hashing checks, and JSON/CSV/Console eligibility guards.
- Extend enum declaration/call formatting and all traversals sufficiently that
  tools can consume these programs safely. Preserve existing plain enum behavior,
  members, namespaces, aliases, private/nested choices, and prelude generation.
- Until slice 2, diagnose direct data-choice matching as not yet supported on
  this implementation branch; do not temporarily give it equality-call semantics.
- Runnable result: construct/print/compare `Download.finished("report.pdf")`,
  build one through a stored lambda, and prove collection copy semantics through a
  separately held source list. No extraction or future subsystem scaffolding.
- Tests: argument ordering/names/widening/expected types, managed and recursive
  values, shared objects, equality/display, keys across every choice, serializer
  rejection at nested paths, native/plain enum compatibility, failed allocations,
  REPL persistence of enum declarations, and malformed declaration diagnostics. Include
  user choices whose names resemble native operations; dispatch must follow the
  resolved declaration rather than a spelling collision.
- Record the implemented part of accepted semantics in the rewrite context in
  this change, clearly marking branch binding as the next slice.
- Settled while building (Claude, 2026-10-15):
  - A data choice stays an enum `TypeField` (keeping its position, key, symbol,
    and coverage entry) with its items in `TypeField.data`. Type setup skips it;
    `Interpreter.choices` builds it by member key, ahead of struct construction.
    `Type.User.choice_data` holds the resolved item types, parallel to the
    choices, and runtime `StructType.value_data` their names for display.
  - Argument mistakes reuse the struct constructor's wording with the noun
    "data item" (`` `Action.say` takes 1 argument, but this call passes 0 ``),
    instead of the plan's "needs a value for `path`", so building a struct and
    building a choice teach one rule.
  - The formatter prints choice data on one line, as it prints every parameter
    list, rather than preserving a multiline layout; no program needs one yet.
  - Data item names get the same snake_case warning as parameters.
  - "`Action` is an enum" style suggestions name a choice without data, or a
    data choice as a call (`Shape.circle(...)`), never a data choice as a value.
  - The dictionary-key refusal names the first ineligible item, as
    `Guests.named.names`.
  - Until slice 2, the resolver reports `when Download.finished(path)` as not yet
    supported, instead of misreporting `path` as undefined.

### Slice 2: Case extraction and control flow

- Add resolved choice-match alternatives, read-only bindings and `_`, both arm
  forms, coverage/duplicates, branch scopes, and correct lifetime transfer.
- Preserve ordinary expression alternatives, optional absence, dynamic calls,
  source evaluation order, expected types, returns and definite assignment.
- Format match syntax and update source/navigation walkers; any remaining editor
  omissions must return safely rather than interpreting bindings as calls.
- Runnable result: all three teaching programs below, plus escaped closures over
  bound values and a Channel carrying an enum with optional data.
- Tests: diagnostics matrix for matching; namespace/type aliases; data names versus
  outer names; nonselected branches; reassignment of the subject during alternatives;
  value arms; custom equality versus choice selection; recursive contents; cleanup
  on raises/returns/cancellation; managed data/closure cycles under the test allocator.
- Complete the accepted enum/case specification and decision-table notes.
- Settled while building: pending.

### Slice 3: Editor experience

- Complete choice signatures/docs, declaration ranges, construction and matching
  completion/signature help, branch-local hover/completion, and navigation/rename.
- Cover data-type references and named labels separately from independent branch
  names. Avoid adding user enum signatures to the built-in catalog.
- Tests: real framed LSP requests, complete/unfinished source, block and `then`
  scopes, named construction arguments, and rename across a multi-file project;
  repeat the new protocol cases 50 times under the testing allocator.
- Check the sibling extension grammar and integration suite. Any extension changes
  use that repo's instructions and a separate branch/review. Record concrete
  companion work in the handoff.
- Settled while building: pending.

### Slice 4: Teaching material and milestone integration

- Add a runnable, fixed-input enum-data tour under `examples/`, with download,
  shapes, game actions, and one explicit working-copy example. Link it from the
  language guide; update enum/trait, collection-key, JSON/CSV, and Console reference
  statements that currently assume all enums are data-free.
- Add bounded fuzz templates for valid construction/matches and malformed inputs,
  including formatter idempotence and unfinished editor examples. Do not assert
  interpreter-specific representation, timing, or exact recursion depths.
- Run all proposed teaching programs as conformance cases with carefully read
  output/diagnostic goldens. Close every diagnostic-matrix row and boundary case.
- Update handoff and journal, and the website pages whose claims changed.
  Keep automatic serialization and generics deferred rather than silently expanding
  this milestone.
- Settled while building: pending.

## Teaching acceptance programs

The download program at the start prints `Saved to report.pdf`. The other two
programs are deliberately small and have fixed input.

### Shapes: different choices need different data

```emerald
enum Shape {
    circle(radius: Float)
    rectangle(width: Float, height: Float)
}

func area(shape: Shape): Float {
    return case shape {
        when Shape.circle(radius) then Math.pi * radius * radius
        when Shape.rectangle(width, height) then width * height
    }
}

print(area(Shape.rectangle(width: 4.0, height: 3.0)))
```

Intended output: `12.0`. A circle has no unused width or height fields, and a
rectangle has no unused radius. Missing either branch is a checking error.

### Game actions: one list, choices with zero, one, or two items

```emerald
enum Action {
    move(x: Int, y: Int)
    say(text: String)
    wait
}

const actions = [Action.move(2, 3), Action.say("Hello!"), Action.wait]
for action in actions {
    case action {
        when Action.move(x, y) {
            print("Move to #{x}, #{y}")
        }
        when Action.say(text) {
            print(text)
        }
        when Action.wait {
            print("Wait here")
        }
    }
}
```

Intended output:

```text
Move to 2, 3
Hello!
Wait here
```

The teaching sequence is plain enum → choice with data → create a value → handle
each choice with `case` → functions/lists → read-only data and working copies.
Do not lead with recursion, custom hashing, or pattern
terminology in beginner material.

## Validation

Planning validation: the source review's pinned Zig smoke probe, native build,
twelve focused output/diagnostic checks, and full Debug suite passed on unchanged
language source. The suite required localhost access outside the sandbox. This
plan introduces no executable feature; its code examples are not claimed to run.
Check new/changed Markdown links, own-line `else`/`catch`/`finally` layout, and
`git diff --check` before handing it back. A Markdown commit requires the local
Debug gate under AGENTS.md. Committing the proposed plan does not accept its
decisions or authorize implementation; pushing is a separate action.

Implementation validation for every slice, on pinned Zig 0.16.0 and with `-j1`:

- Debug and ReleaseSafe `zig build test -j1`;
- native `zig build -j1` and the slice's end-to-end examples/diagnostics;
- `bash tools/check-doc-examples.sh` after the native build when docs add/edit
  executable links, and as part of the full milestone gate;
- formatting checks on changed Zig files and `git diff --check`;
- Windows x86_64 and macOS aarch64 cross-builds with output prefixes outside
  `zig-out`, preserving the native executable;
- normal CI green before review/merge, with no retries hiding intermittent failures.

Slice 3 additionally runs the extension's real integration tests and 50-repeat
new LSP cases. Slice 4 runs a recorded fixed-seed bounded execution/formatting fuzz
campaign and the documentation-example check. Measure a startup comparison only
if constructor/metadata registration changes introduce a concrete performance
concern; this is not an interpreter-optimization milestone.

## Acceptance and next step

Accepted 2026-10-15: all nine recommendations as amended, including required data
without defaults, no data choice as a value without a call, small positional
binding matches with the swapped-label check, and deferred automatic
serialization. Routine implementation choices belong to the implementer within
these rules. Next: slice 1 on `claude/enum-data`.
