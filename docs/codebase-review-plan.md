# Whole-codebase review: plan

Status: accepted by the user, 2026-10-28. Roadmap item 10, the last item before the
compiler. Started 2026-10-28, once item 8 merged and the user moved item 6 after 1.0.

The review's job is to make the interpreter's behavior trustworthy enough to be the compiler's
contract. The compiler (item 12) will be checked against the conformance suite, so every rule the
suite misses, and every crash or wrong answer it does not catch, would be carried into the
compiler or rediscovered there at greater cost. The method was agreed on 2026-10-03 and is kept
here; this plan fills in when, who, how each area is searched, how findings are judged, and when
the review is done.

## Decisions at a glance

| # | Decision | Recommendation |
| --- | --- | --- |
| 1 | When | After the Zig 0.17 upgrade (item 8) and the playground (item 6) merge, so the review sees the code the compiler will be checked against |
| 2 | What counts | Only a failing test or a reproducing program, never "this looks wrong" (agreed 2026-10-03) |
| 3 | Shape | Measure first; then eight areas searched in parallel by subagents, report-first and time-boxed; one triage pass; then fix batches |
| 4 | Corpus of student mistakes | Built from published studies of novices' errors, since there is no class to collect from |
| 5 | Done when | Every finding is fixed, accepted as deferred by the user, or shown wrong; every spec rule has a case or a recorded reason; the mutation campaign finds no crash |
| 6 | Out of scope | Style, the generated tables, interpreter performance, and rewriting working code (agreed 2026-10-03) |

## 1. When

The review should look at the code the compiler will be held to, so it comes after the last
change that touches most of the interpreter: the Zig 0.17 upgrade (item 8, merged 2026-10-28,
with item 9 confirmed in it). The browser playground (item 6) was planned before it too, but the
user moved it after 1.0 (2026-10-28), so its WebAssembly build and I/O are reviewed when it is
built. Item 11 is a design plan, not code, and runs alongside.

## 2. What counts as a finding

A finding is a program, or a test, that fails on main and should not:

- **a crash**: a panic, an assertion, a leak under the testing allocator, or a hang;
- **a wrong answer**: output that contradicts rewrite-context or the reference docs;
- **a wrong or misleading diagnostic**: an error at the wrong place, a help that does not fix the
  problem, or a false positive or negative from the checker;
- **an untested rule**: a rule in rewrite-context with no conformance case that exercises it;
- **a platform difference**: the same program behaving differently on Linux, macOS, and Windows.

Each finding is reported with its reproduction (an `.em` file or a test), what it does, what it
should do and the section that says so, and the platforms it was seen on. "This code looks
fragile" is not a finding until a program shows it.

## 3. Measure first

Two measurements, before any area is searched, so the search goes where the suite is thin:

- **Coverage.** `kcov` on Linux (in Docker, which is now set up for this machine) over the
  conformance suite and the unit tests, per file and per function. The result is a list of large
  unexecuted regions, not a target number: 100% of an interpreter is neither reachable nor useful.
- **Rules without cases.** A pass over rewrite-context's 88 sections, listing each rule it states
  (a "must", an "is an error", a stated result) and the conformance case or unit test that
  exercises it, or "none". The list is committed as `docs/review/rule-coverage.md` and becomes
  area 3's worklist.

## 4. The eight areas

Each area is one subagent in its own worktree, branched from main, with its own method. Each
reports findings only, changes no shared code, and stops at its time box (about two hours of work,
or 30 findings, whichever comes first). Reports go to `docs/review/<area>.md` on the agent's
branch.

| # | Area | Method |
| --- | --- | --- |
| 1 | **Memory and lifetimes** | Run every conformance program, example, and benchmark under the testing allocator's leak and double-free checks, and with allocation failure injected at each point (`checkAllAllocationFailures`) for a sample; reference counts across tasks, closures, and copy-on-write |
| 2 | **Robustness on broken input** | Mutate the conformance programs (delete, duplicate, and swap tokens; truncate at every byte) and run `check`, `format`, and the language server on each; any panic, hang, or non-idempotent format is a finding. Extends the fuzz campaign to the checker and the server |
| 3 | **Rules without cases** | Work through `rule-coverage.md`'s "none" rows: write the case; a case that fails is a finding, one that passes is a test the suite gains |
| 4 | **Tasks and cancellation** | Run every task and channel program 1,000 times, with timing and scheduling perturbed; cancellation at every await point; deadlock detection; standard input under cancellation |
| 5 | **Cross-platform determinism** | Run the whole conformance suite and the benchmarks on Linux, macOS, and Windows and compare outputs byte for byte, including Unicode, time zones, file paths, line endings, and floating-point formatting |
| 6 | **Standard library against references** | Differential tests: generated inputs to `String`, `List`, `Dict`, `Math`, dates, JSON, CSV, regular expressions, Base64, and digests, compared against Python (or Go, where Python's semantics differ from Emerald's), with every disagreement either a finding or a documented difference |
| 7 | **Error messages against student mistakes** | A corpus of about 200 programs, each a mistake novices are known to make (decision 4), checked for whether the first diagnostic names the real problem, at the right place, with a help that fixes it |
| 8 | **What ties the language to the interpreter** | Read for behavior the compiler could not reproduce: evaluation order the spec does not state, behavior that depends on the interpreter's data structures (iteration order, hashing, reference counts), and runtime checks the spec assumes but does not name. Each is a finding only with a program whose result depends on it |

## 5. Triage

One owner, Claude, after every area has reported:

1. **Rerun** every reproduction on main. A finding that no longer reproduces is closed.
2. **Deduplicate** across areas: one cause found by two areas is one finding.
3. **Rank**: crashes and wrong answers first, then misleading diagnostics, then untested rules that
   pass, then platform differences already documented.
4. **Bring the list to the user**, as with the standard-library audit: each finding fixed now,
   deferred with a reason, or shown wrong.

## 6. Fix batches

As the 19-item batch was run: one commit per finding, each adding the conformance case or test that
reproduced it, in PRs of about ten, each through the full gate and `/code-review`. A finding that
needs a language decision goes to the user first, not into a batch.

## 7. Done when

- every finding is fixed, deferred by the user with a reason, or shown wrong;
- every rule in `rule-coverage.md` has a case or a recorded reason it has none;
- area 2's mutation campaign, rerun on the fixed main, finds no crash;
- the conformance suite passes on all three platforms with identical output; and
- the handoff records the coverage before and after.

## 8. Decision 4: the corpus of student mistakes

The classroom pilot was dropped, so there are no students' programs to collect. The corpus is built
instead from published studies of the errors novices make most often (in Python and Java, for
example missing or mismatched brackets, `=` for `==`, using a variable before assigning it, off-by-one
ranges, calling a method on the wrong type, forgetting to return, and mistaking a string for a
number), each written as the Emerald program a beginner would write, and from the mistakes the
guide's own pages already show. It is committed with the review, so it can grow when Emerald
does meet a class.

## Cost

Eight subagents in parallel, as slices 2 and 3 of the library additions were built, and a triage
and fix phase sized by what they find. The measurement step needs Docker for `kcov`; area 5 needs
CI's three platforms, through `workflow_dispatch`.
