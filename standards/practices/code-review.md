# Code Review

Human review behaviour standards. Mechanics of commits, branches, PRs, and CODEOWNERS live in [collaboration.md](collaboration.md) and [ci-cd.md](../platform/ci-cd.md).

---

## 1. Why this doc exists

Automated tools catch syntax and style. This doc governs the human decisions: what to look for, how to say it, and when to escalate.

---

## 2. Author duties

### 2.1 Keep PRs small

| Target | Hard limit |
|---|---|
| < 400 lines changed | 800 lines — split before requesting review |
| Single logical change | One PR per concern; refactor + feature = two PRs |

Rationale: reviewers hold less context, find more bugs, and merge faster on small diffs. Large PRs mask intent and slip through.

### 2.2 Self-review first

Before marking Ready for Review:

- [ ] Read your own diff in the PR UI, not the editor
- [ ] Delete dead code, debug prints, and accidental whitespace
- [ ] Confirm tests exist and actually assert meaningful behaviour (see [testing-strategy.md](testing-strategy.md))

### 2.3 Write a useful description

Every PR must include:

```text
## What
One sentence. What changed?

## Why
Link the issue/ticket. Why does this matter?

## How to test
Step-by-step. What should the reviewer try?
```

Omitting "How to test" blocks approval — reviewers should not have to guess.

### 2.4 CI must be green

No review requests on red CI. Fix the build first. Flaky tests: annotate with the known-flake ticket; don't leave reviewers chasing noise.

### 2.5 Draft = WIP

Mark as draft until it is ready for human review. Do not ping reviewers on a draft.

### 2.6 Respond, don't argue

Address every comment — with a code change, a clarifying question, or an explicit decision. Silence is not resolution. If you disagree, say so once, briefly, then defer or escalate (see §7).

---

## 3. Reviewer duties

### 3.1 SLA

| PR size | Review SLA |
|---|---|
| < 200 lines | Same business day |
| 200–400 lines | Next business day |
| > 400 lines | Ask the author to split; review the first half same day |

Missing SLA? The author may re-assign or escalate to the team lead.

### 3.2 Review priority order

Review top-to-bottom; stop if a higher tier blocks:

1. **Correctness** — does it do what the description claims?
2. **Security** — injection, auth, secrets, deps (see [app-security.md](app-security.md))
3. **Tests** — do tests exist? do they cover the failure path?
4. **Readability** — would a peer six months from now understand this?
5. **Style** — the linter's job, not yours; leave at most one nit

Rationale: spending reviewer cycles on whitespace and naming while missing a SQL injection is a values failure.

### 3.3 Check intent, not implementation

Read the description first. Ask: "Does this diff achieve what it says?" Implementation bikeshedding is optional; intent mismatch is a blocker.

### 3.4 Approve small and obvious changes

Don't gatekeep. If a PR is correct, safe, tested, and readable, approve it. Holding approval to bikeshed implementation style erodes trust and velocity.

---

## 4. Comment conventions

Every review comment must carry a prefix:

| Prefix | Meaning | Expected response |
|---|---|---|
| `blocking:` | Must fix before merge | Code change required |
| `nit:` | Minor, take it or leave it | Author decides; no reply needed |
| `question:` | Clarification needed | Answer in thread or code comment |
| `suggestion:` | Optional improvement | Author decides |

**Rules:**
- Be specific about the code, not the author: "This loop is O(n²) because…" not "You wrote a slow loop."
- Offer the fix: include a snippet or a concrete alternative.
- One comment per concern; don't chain unrelated feedback in a thread.
- Emoji reactions (👍, ✅) are sufficient for approval of small nits already addressed.

---

## 5. Approval rules

| Rule | Detail |
|---|---|
| Minimum approvals | ≥ 1 from a code owner (see CODEOWNERS in [ci-cd.md](../platform/ci-cd.md)) |
| Require last-push approval | Any push after approval resets approval; re-approval required |
| Self-merge | Permitted only for owners on trivially obvious fixes (typo, lock file bump); must still be green CI |
| Cross-team PRs | ≥ 1 approval from each affected team's code owner |

_(scale-up)_ At > 50 engineers: enforce 2 approvals on paths under `src/core/` and `infra/`.

---

## 6. Reviewing AI-generated code

AI agents are first-class authors in this kit. The human author owns AI output as if hand-written — no reduced accountability.

**Heightened bar:**

| Check | Why |
|---|---|
| Does it actually run? | LLMs hallucinate plausible-looking code that does not compile or silently no-ops |
| Are the APIs real? | Verify library calls against the actual version in `package.json` / `go.mod` / etc. |
| Are tests meaningful? | AI tests often assert trivial state (`expect(x).toBe(x)`) or mock everything, covering nothing |
| License and provenance | AI may reproduce GPL code in an MIT codebase; flag for legal if uncertain |
| Security | AI frequently omits input validation, uses deprecated crypto, or inlines credentials |
| Does the PR description explain the intent? | If the author pasted a prompt instead of writing a description, request a rewrite |

If the AI-generated section is > 200 lines and the author cannot explain a given block on request, treat that as a blocker.

---

## 7. When to escalate

### 7.1 Pair instead of a long thread

If a review thread exceeds 6 back-and-forth comments on a single concern, schedule a 15-minute sync. Resolve in the call; document the decision in the thread.

### 7.2 Spike instead of blocking review

If the correct solution is genuinely unknown, open a spike ticket, merge what works behind a flag, and revisit. Don't block shipping on open-ended research.

### 7.3 Deadlock resolution

If author and reviewer cannot agree after one escalation:

1. Bring in a third reviewer; their call is final for that PR
2. If architectural impact: 30-minute sync, then record the outcome as an ADR

No PR should block more than 48 hours on a disagreement. Decide and document.

---

## Definition of done

- [ ] PR description includes What / Why / How to test with issue link
- [ ] PR is < 400 lines, or has been split with rationale
- [ ] Author completed self-review before requesting
- [ ] CI is green at time of review request
- [ ] All `blocking:` comments resolved with code changes
- [ ] All `question:` and `suggestion:` comments acknowledged (code change or explicit decision)
- [ ] ≥ 1 code-owner approval obtained
- [ ] No approval was invalidated by a post-approval push without re-review
- [ ] AI-generated sections verified runnable and API-accurate by the author
- [ ] Any deadlock resolved with a third reviewer or ADR
