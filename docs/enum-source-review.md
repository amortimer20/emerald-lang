# Data-carrying enums: focused source review

Reviewed: 2026-10-13, main `5fb9f92`, pinned Zig 0.16.0.

Superseded as a status record: the plan this fed was accepted on 2026-10-15 and is
implemented on `claude/enum-data`. Read [the plan](enum-design-plan.md) for what was
decided and built; this file is kept for the evidence below.

This is implementation evidence for the forthcoming design plan, not an accepted
language specification. The user authorized Codex to write this plan despite the
usual division of roles. No language implementation changed during this review.

The discussion established a readable working direction: a choice such as
`finished(path: String)`, construction as `Download.finished("report.pdf")`, and
extraction as `when Download.finished(path)`. Ordinary enum values retain their
existing spelling. The complete behavioral recommendations still need a proposed
plan and acceptance. Rewrite-context sections 6.3 and 12 remain authoritative today.

## Findings by subsystem

| Area | Current implementation | Consequence for the plan |
| --- | --- | --- |
| Syntax tree and parsing | `Ast.StructDeclaration` represents enums; choices are synthetic `TypeField` constants with `EnumValue` initializers. `Case.Arm.alternatives` contains ordinary expressions. `Parser.parseEnumValues` accepts bare names only. | Give choices explicit data declarations and source spans. A branch binding cannot be treated as an ordinary evaluated call. Keep plain enum and ordinary case syntax working. |
| Resolution | `Resolver.hoistStruct` gives choices qualified keys, declaration targets, and type-member identities. `walkCase` resolves alternatives as reads and opens a scope only for a block body. | Resolve the choice identity separately from the names introduced by a match. Both block and `then` arms need branch-local scope, declaration targets, capture tracking, and duplicate-name checks. |
| Static types and calls | `Type.User` records common fields, with no per-choice data. `Checker.typeOfCall` rejects construction of an enum type and treats existing choices as values. `arguments.bind` shares positional/named argument matching between checking and execution. | Register all choice signatures before checking uses; resolve their annotations against the ordinary type system. Reuse argument binding and expected-type checking for construction, without exposing data as common instance fields. |
| Case analysis | `Checker.checkCase` compares alternatives by the ordinary equality rules. `knownAlternative` recognizes literal values and resolved enum constants; `caseCoverage` lists choices, and also absence for optional subjects. Coverage participates in returns and definite assignment. | Record whole-choice coverage for binding matches. Preserve dynamic expression alternatives, optional absence, result-type inference, flow analysis, missing-choice diagnostics, and subjectless cases. |
| Execution | `Interpreter.chooseArm` evaluates the subject once, compares evaluated alternatives through `Value.equals`, releases the subject, and returns only a body. Statement and value cases then execute the selected body separately. | A match must retain the subject/data until branch bindings own their values. Both execution paths need binding scope and cleanup, including errors, returns, and closures escaping a branch. |
| Runtime representation | Enums already use `Heap.StructValue`, with a `variant` number and a managed `fields` slice. Their type descriptor currently has only choice names and a common field layout. | The existing managed storage is a plausible home for data. Add per-choice metadata while retaining one enum identity. Do not pretend that choice-specific data is accessible through ordinary field lookup. |
| Equality, hashing, printing | `Value.equals` checks the descriptor, optional custom equality, class identity, variant, and stored values. Hashing includes type identity, variant, and stored values. Printing returns immediately after the enum choice name. | Default equality already has useful structure. Printing needs choice-specific labels and contents. Keep custom traits, normalized strings, nested display, and diagnostics' safe rendering consistent. |
| Dictionary keys | `Type.eligibleKeyInner` checks stored field types and existing trait rules. Enums currently have no fields, so ordinary enums pass this check. | Check every choice's data types, not an empty common-field list. Read-only data does not automatically make lists, class objects, or functions valid keys. Recursive types need a deliberate rule. |
| JSON and CSV | Checker eligibility accepts enums unconditionally. JSON writes a choice name as text and reconstructs an empty enum value when decoding. CSV enum cells also contain only a choice name. Console struct tables use CSV's field eligibility. | Existing behavior cannot safely accept data-carrying enums unchanged: encoding would discard data and decoding could construct an incomplete value. Explicitly preserve plain enum interchange and either design a data format or reject the new enum types with useful diagnostics, including when nested in records/collections. |
| Formatter | Enum formatting prints just the bare choice name; member-end calculations use its name span. Cases print ordinary alternative expressions. | Include full choice declarations and binding patterns, comments, multiline data, both brace styles, reparsing, and idempotence. |
| Editor support | LSP treats choices as enum-member fields. It skips their synthetic type annotations when finding references. Signature help selects call expressions and resolves ordinary functions/constructors; local completion finds case-body declarations but no match bindings. | Add choice signatures, annotation navigation, binding hover/definition/references/rename/completion, and completion/signature help on unfinished source. Matching syntax must not accidentally offer construction arguments as expressions. |
| Prelude, REPL, tasks | The prelude AST serializer is generic over AST fields. Runtime descriptors and closures carry REPL code origins; scopes survive when captured. Tasks transmit values using the existing ownership system. | Regenerate the prelude AST through the build. Test new declarations and carried values across REPL entries, failed entries, escaping closures, and channels. No new task-sharing semantics should be inferred from this feature. |

## Source entry points

These are starting points for implementation, not an exhaustive change list.

- [Ast.zig](../src/Ast.zig): `Case`, `EnumValue`, `StructDeclaration.TypeField`.
- [Parser.zig](../src/Parser.zig): `parseEnumValues`, `startsEnumValue`,
  `parseCaseArms`, and the expression-height traversal.
- [Resolver.zig](../src/Resolver.zig): `hoistStruct`, `walkCase`, ordinary
  declaration/capture tracking, and enum name diagnostics.
- [Checker.zig](../src/Checker.zig): `registerStruct`, `typeOfCall`,
  `checkArguments`, `checkCase`, `knownAlternative`, `caseCoverage`,
  `caseChangesSelf`, and JSON/CSV eligibility.
- [Type.zig](../src/Type.zig): `User`, `eligibleKeyInner`.
- [Interpreter.zig](../src/Interpreter.zig): `registerStruct`,
  `evaluateEnumValue`, `chooseArm`, both case execution paths,
  `pushScope`/`popScope`, `methodCallable`, and typed serializers.
- [Value.zig](../src/Value.zig): `StructType`, enum display, `equals`, `hashInto`.
- [Heap.zig](../src/Heap.zig): `createStruct`, `uniqueStruct`, reference-counting
  and collector traversal of stored values.
- [Formatter.zig](../src/Formatter.zig): `Member.end`, `printTypeField`,
  enum formatting runs, `printCase`.
- [Lsp.zig](../src/Lsp.zig): symbols, hover, signature help, type/reference
  traversal, declaration lookup, and local/type-member completion.
- [arguments.zig](../src/arguments.zig): shared argument binding.
- [tools/prelude_ast.zig](../tools/prelude_ast.zig): generic AST serialization.

## Questions the proposed plan must answer

1. **What counts as a binding match?** A call-shaped alternative currently
   evaluates a function. Identify an enum choice by resolution, not capitalization
   or spelling alone. Preserve aliases, nested types, namespaces, and calls to
   ordinary functions. Specify how to reject literal/nested patterns and how a
   program compares against an already-created enum value.
2. **What can a branch introduce?** Specify positional names, `_`, shadowing,
   duplicate names, scope in a `then` arm, and whether binding alternatives can
   share a comma-separated arm. Existing alternatives that introduce no names
   should retain their behavior.
3. **What does read-only mean?** Extracted names should follow ordinary `const`
   rules. A carried class object remains shared and its mutable contents remain
   mutable, as for classes in structs. Do not promise deep immutability that
   Emerald's existing value rules do not provide.
4. **Which parameter features apply?** Decide required annotations, named
   construction arguments, defaults, empty parentheses, function-valued data,
   and whether choice constructors can be held as callable values. The discussed
   examples do not settle all of these.
5. **How do existing traits and members interact?** Preserve enum methods,
   properties, traits, qualified names, privacy, and namespace rules. State how
   choice matching relates to custom equality, while ordinary comparisons retain
   the existing equality contract. Enums currently cannot register arithmetic
   operators; that is not a prerequisite for this feature.
6. **What happens outside case statements?** Settle dictionary eligibility,
   recursive carried types, optional enum subjects, default printing, JSON/CSV
   eligibility, and table diagnostics before implementation.

None of these findings requires abandoning the proposed syntax. They make the
scope concrete and prevent a superficially working implementation from silently
losing data or changing existing programs.

## Validation and implementation test outline

The native build on Zig 0.16.0 passed. Direct CLI runs matched the existing golden
output for eight cases: enums, case, the enum project, case trailing blocks, JSON
encoding/decoding, and CSV encoding/decoding. These are current-behavior checks;
the proposed syntax was not run or claimed to work.

Four diagnostic checks also matched their existing goldens after removing the
CLI-only diagnostic codes: enums, enum syntax, enum names, and case. The first
Debug suite run reached 560/562 passing tests; the two HTTP-related failures
occurred when the sandbox denied localhost socket creation (`EPERM`). The suite
passed when rerun outside that restriction. The rerun was justified by the
specific socket-denial failure, not by an unexplained intermittent failure.

`zig build test -j1` passed in Debug with localhost socket access. No
ReleaseSafe suite, cross-build, or fuzz campaign was required for this source-only
review. No source, prelude, expected output, or website content changed.

The implementation gate should add coverage for:

- construction, argument errors, evaluation order, expected collection/lambda
  types, and numeric widening;
- binding and discarded data in block and value arms, nonmatching choices,
  coverage, duplicate matches, optional absence, returns, and definite assignment;
- scope, captures, escaping closures, error cleanup, failed allocations,
  copy-on-write data, shared objects, REPL persistence, and channel transmission;
- structural and custom equality, hashing eligibility across every choice,
  nested printing, and explicit serializer/table handling;
- qualified/aliased/private/nested choice resolution, formatter stability,
  complete and unfinished editor requests, and declaration/reference navigation.

Existing plain enum, dynamic-alternative case, JSON/CSV, and prelude examples
must continue passing unchanged unless a separately accepted design explicitly
requires a compatibility change.
