---
name: ai-engineering-standards
description: Use when building production LLM/AI features in a touchstone repo — prompts, structured outputs/tool-calling, RAG, agents, evals, safety/guardrails, cost/latency, or LLM observability. Invoke before adding any model call, writing a prompt, or designing an eval. NOT Anthropic/Claude API specifics (model IDs, pricing, prompt caching, tool-use shapes) — defer to the `claude-api` skill; per-language mechanics live in the language skills.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# AI / LLM Engineering

Full standard: **`standards/practices/ai-engineering.md`** in the touchstone repo. It defers the
cross-cutting machinery to siblings (api-design, resilience, observability, testing-strategy,
data-privacy, security) and defers Claude API specifics to the `claude-api` skill. This skill
inlines the load-bearing rules so it stays useful standalone in `~/.claude/skills/`:

## Always
- **You cannot ship what you cannot evaluate.** Build a **golden eval set** first; run **regression
  evals in CI** (promptfoo/Braintrust/Langfuse) and gate merges on it. No eval, no merge.
- **Default to no LLM.** If plain code or a cheaper classical model is correct, use it. Pick the
  smallest model that passes eval; tier the rest.
- **Prompts are code** — versioned templates in the repo (not inline strings), reviewed with an eval
  run. Use roles deliberately; few-shot beats prose; never f-string user input into a prompt.
- **Structured outputs, validated at the boundary.** Tool/function-calling or JSON-schema mode +
  parse-or-fail (Instructor/Pydantic/Zod). A model is an untrusted client.
- **Pin everything that moves the output:** model snapshot (never `latest`), temperature, seed,
  prompt + embedding versions — recorded per result. A model upgrade re-runs the full eval suite.

## Don't get burned
- **Prompt injection is the #1 risk (OWASP LLM01) and has no complete fix.** All model input
  (user text, retrieved docs, tool outputs) is untrusted; all output is unverified. Defend in depth:
  isolate untrusted text from the system role, filter both edges, and bound **blast radius** with
  least-privilege authz — never trust the model to police itself.
- **RAG fails at retrieval, not generation.** Eval the retriever separately (recall@k, faithfulness);
  **hybrid + rerank**; **cite or abstain** — no grounding means "I don't know", not a confident
  guess. More context is not better.
- **Bound the agent loop.** Hard caps on iterations/token budget, narrow least-privilege tools, and
  **human-in-the-loop on irreversible actions** (spend, send, delete, prod). An unbounded loop is a
  runaway-cost incident.
- **LLM-as-judge is biased** (verbosity, position, self-preference). Use a rubric, pairwise > absolute,
  a stronger judge, and **calibrate against human labels** before trusting it — never the sole gate.
- **Providers fail.** Timeouts + bounded retries (never retry a refusal/4xx), a **fallback model**,
  and handle truncation/stop-reason as first-class. Budget tokens; cache prefixes; stream to users.
- **Trace every call** (model/prompt version, tokens, cost, latency) via OTel GenAI conventions;
  **redact prompts/completions** before storage. Don't send PII to providers without a DPA; default
  to zero-retention / no-train terms for customer data.

## Done
LLM justified over plain code/ML · prompts versioned + reviewed · outputs schema-validated at the
boundary · golden eval set gates CI, judge calibrated · RAG retriever evaluated, cite-or-abstain ·
agent loop bounded + HITL on irreversible · injection defended in depth, blast radius bounded ·
token budgets + tiering + caching + streaming · timeouts/retries + fallback model · every call traced
(redacted) · model/temp/seed/versions pinned · provider zero-retention + DPA. See
`standards/practices/ai-engineering.md`.
