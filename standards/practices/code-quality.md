# Code Quality Standards

Language-agnostic coding principles every stack assumes — naming, size, simplicity, control flow,
error handling, comments. Per-language formatting/linting lives in the language docs
([python.md](../languages/python.md), [golang.md](../languages/golang.md),
[shell.md](../languages/shell.md)); review *process* in [code-review.md](code-review.md); test
doubles in [testing-strategy.md](testing-strategy.md); doc/comment style in
[documentation.md](documentation.md); file-sprawl-vs-git policy in [collaboration.md](collaboration.md).

> **One law:** code is read far more often than it is written — optimise for the next reader.

---

## 1. Read before you write

- **Read the README and the surrounding code first.** Load the project's architecture, conventions,
  and gotchas before planning a change — a plan that contradicts established design is wasted work.
- **Match the file you're editing.** Follow the local idiom (naming, error style, layering) over your
  personal preference; a diff that fights the surrounding code is harder to review and review-trust.
- **Find the existing thing before adding a new one.** Grep for an existing helper/module/pattern
  before introducing a parallel one — most "new" code is a near-duplicate of code already here.

## 2. Naming

- **Intention-revealing names.** A name states *what it is / does*; if it needs a comment to explain
  the name, rename it. `activeUsers`, not `au`; `retryWithBackoff`, not `doIt`.
- **No abbreviations or single letters** outside tight loop indices and well-known math/domain terms.
  Spelled-out and long beats short and cryptic — the reader shouldn't decode.
- **Names carry no type/scope noise** — drop Hungarian prefixes and `Manager`/`Helper`/`Util` filler;
  let the type system and module say it. Never name a module `util`/`common`/`shared`/`misc`.
- **Descriptive, kebab-case file names.** A filename should reveal purpose to someone reading only the
  directory listing — `parse-webhook-payload.ts`, not `helper.ts`. Use **kebab-case** for new files,
  except framework-mandated names (`README.md`, `Dockerfile`, `SKILL.md`) and per-language convention
  (Go's lowercase, React components' PascalCase) — defer casing to the language doc when it disagrees.

## 3. Size & single responsibility

A unit should do one thing, at one level of abstraction, and be nameable without "and".

| Unit | Soft ceiling | When you hit it |
|---|---|---|
| Function | ~30–40 lines / one screen | Extract a well-named sub-step; don't inline a second job |
| File / module | ~200–300 lines | Split by responsibility, not by line count |
| Parameters | ~4 | Bundle into a value object / options struct |
| Nesting depth | ~3 | Flatten with guard clauses (§5) |

- **These are smells, not hard caps** — a cohesive 250-line file beats four anaemic 60-line ones.
  Some language docs pin tighter, enforceable limits: defer to them ([shell.md](../languages/shell.md)
  caps shell at ~50 lines of logic / ~100 hard; the language docs set line length via the formatter).
- **One reason to change per unit.** If a function both fetches and formats and persists, it has three;
  split until each has one. Cohesion over brevity.

## 4. Simplicity: KISS, YAGNI, DRY

- **KISS** — choose the simplest design that works; clarity beats cleverness. The reader's time is the
  scarce resource, not the author's keystrokes.
- **YAGNI** — build for the requirement in front of you, not a hypothetical future. No speculative
  config knobs, plugin layers, or generic frameworks for a single caller.
- **DRY, but earn the abstraction.** Duplication is cheaper than the *wrong* abstraction. Apply the
  **rule of three**: inline the first two copies; extract only when a third appears and the shared
  shape is real — not two things that merely look alike today.
- **Delete before you add.** The best change is often less code. Dead branches, unused params, and
  "just in case" indirection are liabilities, not assets.

## 5. Control flow: guard clauses & early returns

Keep the happy path flat and last; handle the exceptional cases first and bail early.

```text
# Prefer — guard clauses, un-indented happy path
function handle(req):
    if not req.authed:   return error(401)
    if not req.valid:    return error(422)
    return process(req)        # the real work, at depth 0

# Avoid — the success path buried inside nested conditionals
function handle(req):
    if req.authed:
        if req.valid:
            return process(req)
        else: return error(422)
    else: return error(401)
```

- **Return/continue/throw early** to drop an `else`; deeply nested conditionals hide the main logic.
- **Don't `else` after a `return`** — the branch already exited; the `else` is noise.

## 6. Error handling philosophy

Mechanics (exception types, `%w` wrapping, `Result`) belong to the language docs — this is the
*philosophy*; see [golang.md](../languages/golang.md) §6 and [python.md](../languages/python.md) §6.

- **Validate at the boundary, fail fast.** Parse and reject untrusted input *once*, at the edge, with
  the correct status — before starting expensive work. Trust the typed values inward.
- **No catch-log-continue.** A handler that logs and falls through hides the failure and corrupts
  downstream state. Either re-raise (wrapped, with context), return the failure as a value the caller
  must check, or don't catch it.
- **Never swallow errors.** No empty catch blocks, no discarding the error value, no bare catch-all
  that hides a typo. Catch the **narrowest** thing you can actually handle.
- **An error is a value, not a side effect.** Surface it where a caller can act; don't bury a real
  failure in a log line and return a plausible-looking zero.

## 7. Comments & dead code

- **Comment the *why*, never the *what*.** Explain the constraint, trade-off, or non-obvious reason;
  if a comment restates the next line, delete one of them — usually the comment. (Docstring style and
  public-API doc rules: [documentation.md](documentation.md) §5.)
- **No commented-out code.** Git is the history — delete it. A block "kept just in case" is dead weight
  the next reader has to mentally execute.
- **No bare `TODO`/`FIXME`.** A marker without a tracked issue link is a wish, not a plan — file the
  issue and reference it, or do the work now.

## 8. No fake data, no mock-the-world

- **Never fake-pass a check.** Stubs, hard-coded "expected" values, or disabled assertions that turn CI
  green while hiding a real failure are worse than a red build — they ship the regression. Implement
  the real path.
- **No placeholder data in production code paths.** Seed/sample data lives behind tests or an explicit
  flag, never inlined into the running code. Test doubles are a *testing* concern — what to mock and
  where (fakes over mocks, mock only at the boundary) is owned by [testing-strategy.md](testing-strategy.md).

## 9. Edit existing over creating new

- **Modify the file in place.** Don't ship `thing-v2`, `thing-enhanced`, or `thing-new` beside the
  original — parallel copies diverge, confuse imports, and leave dead code. One source of truth.
- **Consolidate duplicates instead of letting them drift.** If two modules already do the same job,
  merge them; don't add a third.
- **Right-size the change.** A bug fix shouldn't drag in a rename-the-world refactor — keep the diff
  scoped to its one concern (PR-splitting rules: [code-review.md](code-review.md) §2.1).

## 10. Immutability & consistency

- **Prefer immutable, prefer pure.** Default to values that don't change after construction and
  functions that don't reach outside themselves — they're easier to test, reason about, and run
  concurrently. Confine mutation to the smallest scope that needs it.
- **No surprising side effects.** A function named for a query shouldn't write; one named for a
  computation shouldn't perform I/O. Make effects visible in the name and signature.
- **Be consistent with the codebase over your own taste.** One coherent style the whole repo follows
  beats a locally "better" style only one file uses.

## Definition of done

- [ ] Names reveal intent; files are descriptive + kebab-case (or per-language convention)
- [ ] Functions do one thing; no unit blew the size/nesting/param smells without a reason
- [ ] Simplest design that works — no speculative generality; abstraction earned by the rule of three
- [ ] Happy path is flat (guard clauses / early returns); no `else`-after-`return`
- [ ] Input validated and rejected at the boundary; no catch-log-continue; no swallowed errors
- [ ] Comments explain *why*; no commented-out code; no `TODO`/`FIXME` without an issue link
- [ ] No fake data or check-bypassing stubs in production paths
- [ ] Changes edit existing files; no `-v2`/`-enhanced` duplicates; duplicates consolidated
- [ ] New state is immutable where practical; style matches the surrounding code
