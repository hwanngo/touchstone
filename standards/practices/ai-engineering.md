# AI / LLM Engineering Standards

How we build production features on top of large language models: when an LLM is the right tool,
how prompts/outputs/RAG/agents are engineered, and — above all — how the system is **evaluated**.
This doc owns the AI-specific discipline; it defers the cross-cutting machinery to siblings rather
than restating it: output validation to [../design/api-design.md](../design/api-design.md),
timeouts/retries/fallbacks to [../design/resilience.md](../design/resilience.md), tracing/cost
telemetry to [../platform/observability.md](../platform/observability.md), eval-as-tests to
[../practices/testing-strategy.md](../practices/testing-strategy.md), PII/retention to
[../practices/data-privacy.md](../practices/data-privacy.md), and prompt-injection/filtering to
[../practices/security.md](../practices/security.md). For **Anthropic/Claude API specifics** (model
IDs, pricing, prompt caching, tool-use shapes) defer to the user's `claude-api` skill if present —
don't hard-code them here.

> **One law:** you cannot ship what you cannot evaluate — an LLM feature without an eval set is a
> demo, not a product, and every change to it is a guess.

---

## 1. When to reach for an LLM (and when not to)

An LLM is a fuzzy, expensive, non-deterministic function. Use it only where that trade buys you
something cheaper code can't. **Pick the lowest-power tool that solves the problem.**

| Problem shape | Reach for | Not |
|---|---|---|
| Deterministic rules, exact math, lookups | **plain code** | an LLM (it'll hallucinate the obvious) |
| Structured classification with labeled data + volume | **a small fine-tuned/classical ML model** | a frontier LLM per call (10–100× the cost) |
| Open-ended language: summarize, extract, rewrite, converse, reason over messy NL | **an LLM** | a brittle regex pipeline |
| Semantic search / "find similar" | **embeddings + vector search** (§4) | an LLM ranking everything |

- **Default to no LLM.** If a `switch` statement or a SQL query is correct 100% of the time, that
  beats a model that's correct 95% of the time and costs money per call.
- **Smallest model that passes eval.** Don't reach for the biggest model reflexively; tier it (§8).
- **Escape hatch:** prototype with a frontier model to learn the task, then distill down to a
  cheaper model or classical approach once the eval set tells you what "good" requires.

## 2. Prompts are code, not strings

A prompt is program logic. Treat it like source: versioned, reviewed, templated, and tested (§6).

- **Never hard-code prompts inline.** Store them as versioned templates in the repo
  (`prompts/<name>.vN.jinja` / a registry), referenced by ID + version — so a prompt change is a
  reviewable diff with an eval run attached, not a silent string edit buried in a function.
- **Use the role hierarchy deliberately.** `system`/`developer` = durable instructions, persona,
  guardrails, output contract; `user` = the request; `assistant` = few-shot exemplars. Don't stuff
  user-controlled text into the system role (that's an injection vector — §7).
- **Few-shot beats prose.** 2–5 high-quality, diverse examples in the prompt outperform a paragraph
  describing the behaviour. Curate them; they're part of the contract.
- **Templated, not concatenated.** Render variables through a real template engine with escaping;
  never f-string user input straight into a prompt.
- **Optimize prompts as code _(scale-up)_:** for high-value prompts, **DSPy** compiles/optimizes
  prompts against a metric instead of hand-tuning — but only once you have the eval set (§6) it
  optimizes toward.

## 3. Structured outputs — validate at the boundary

Free-text parsed with regex is a production incident waiting to happen. Make the model emit
**structured, schema-constrained** output and validate it before it touches your system.

- **Prefer tool/function calling or native structured-output mode** with a **JSON Schema** the
  provider enforces during decoding — not "respond in JSON" in the prompt and hope.
- **Validate every output against the schema at the boundary**, exactly like an untrusted API
  request — a model is an untrusted client. Use **Instructor** / **Pydantic** (Python) or **Zod**
  (TS) to parse-or-fail. Reject-and-repair on validation failure (one bounded retry feeding the
  error back), then fall through to an error. The validation discipline and error envelope are
  owned by [../design/api-design.md](../design/api-design.md).
- **Constrain the surface.** Enums over free strings; bounded lists; required fields explicit. A
  narrow schema is fewer ways for the model to surprise you.

```python
from pydantic import BaseModel, Field
import instructor

class Triage(BaseModel):
    category: Literal["bug", "billing", "other"]   # enum, not free text
    urgency: int = Field(ge=1, le=5)
    summary: str = Field(max_length=280)

client = instructor.from_provider("...")
result = client.create(response_model=Triage, max_retries=1, messages=[...])  # parsed or raises
```

## 4. RAG — ground answers, don't stuff context

Retrieval-augmented generation grounds the model in your data. The failure mode is **garbage
retrieval**, not generation — so eval the retriever separately (§6).

| Stage | Default | Notes |
|---|---|---|
| Chunking | **semantic / structure-aware**, ~200–500 tokens, small overlap | naive fixed-size splits break mid-thought; chunk on headings/sentences |
| Embeddings | a current top-MTEB model; **pin the version** | re-embedding the corpus on a model change is a migration, not a config flip |
| Store | **pgvector** if you already run Postgres; **Qdrant/Weaviate** at scale | one vector store; don't run three |
| Retrieval | **hybrid** (BM25 + dense) → **rerank** top-k | pure-vector misses exact terms; a reranker fixes precision |
| Grounding | pass retrieved chunks + **require citations** | answer must cite chunk IDs; "I don't know" when retrieval is empty |

- **More context is not better.** Stuffing the whole corpus into the window raises cost, latency,
  and "lost in the middle" errors. Retrieve *few, relevant* chunks; rerank; cap k.
- **Cite or abstain.** The model answers **only** from retrieved context and emits citations;
  unsupported claims are a bug you can detect (faithfulness eval, §6). No grounding → "I don't
  know", never a confident guess.
- **Frameworks:** **LlamaIndex** for retrieval-heavy pipelines, **LangChain** for broader
  orchestration — pick one. Escape hatch: a thin hand-rolled retriever is fine and often clearer
  for a single corpus.

## 5. Agents & tool use — bound the loop

An agent is an LLM in a loop calling tools. Power and risk both come from the loop, so **bound it
and keep a human on the dangerous edges.**

- **Design tools like an API** ([../design/api-design.md](../design/api-design.md)): few, narrow,
  well-described, with validated typed arguments. A vague `run_query(sql)` tool is an injection and
  blast-radius hole; prefer specific, least-privilege tools.
- **Terminate deliberately.** Hard cap on iterations/wall-clock/token budget; an explicit "done"
  signal; detect and break no-progress loops. An unbounded agent loop is a runaway cost incident.
- **Guardrail every tool call.** Authz per tool (the agent acts as the user, not as root),
  allowlists, and **idempotency** for anything mutating (defer to
  [../design/resilience.md](../design/resilience.md)). Validate tool *outputs* too — they re-enter
  the prompt and carry injection (§7).
- **Human-in-the-loop on irreversible actions.** Spending money, sending external messages,
  deleting data, modifying prod → require explicit confirmation. Reversibility decides autonomy.
- **Start the simplest thing that works.** A single prompt + tools beats a multi-agent swarm for
  most tasks; reach for orchestration frameworks (LangGraph) only when the control flow demands it.

## 6. Evaluation — the heart of it

This is where AI engineering is won or lost. Treat evals like tests
([../practices/testing-strategy.md](../practices/testing-strategy.md)): versioned, in CI, gating
merges. **No eval, no merge.**

- **Build a golden dataset first.** Curated input→expected pairs covering happy paths, edge cases,
  and known failure modes. Start with 20–50 hand-written cases; grow it from production failures.
  It's a versioned asset in the repo, owned like code.
- **Score with the right grader per task:**

  | Output type | Grader |
  |---|---|
  | Extraction / classification / structured | **exact / schema / assertion** — deterministic, cheap, trustworthy |
  | RAG retrieval | **recall@k, MRR, faithfulness, answer-relevance** (e.g. **Ragas**) |
  | Open-ended generation | **LLM-as-judge** with a rubric — *with caveats below* |

- **LLM-as-judge, used honestly.** A model grading model output is useful but biased (verbosity,
  position, self-preference). Mitigate: a written rubric, pairwise comparison over absolute scores,
  randomized order, a **stronger** judge than the generator, and **calibrate the judge against human
  labels** before trusting it. Never let a model be the sole gate on a safety-critical path.
- **Regression evals in CI.** Run the eval suite on every prompt/model/RAG change; **fail the build
  on regression** against the baseline (ratcheted, like coverage). Tools: **promptfoo** (CI-native,
  config-as-code), **Braintrust** / **Langfuse** (datasets, scoring, tracking over time). Pick one.
- **Online eval _(scale-up)_:** sample production traffic, score it continuously, and watch for
  drift — offline sets go stale as inputs shift.

## 7. Safety & guardrails — prompt injection is the #1 risk

Any text the model reads can carry instructions. Treat **all** model input as untrusted and all
model output as unverified. This section defers filtering/PII mechanics to
[../practices/security.md](../practices/security.md) and
[../practices/data-privacy.md](../practices/data-privacy.md).

- **Prompt injection is the top LLM risk (OWASP LLM01).** Untrusted content — user input, retrieved
  docs, tool outputs, web pages — can hijack the model. There is **no complete fix**; defend in
  depth: keep untrusted text out of the system role; clearly delimit/quote it; least-privilege tools
  so a hijack can't do much; and **never trust the model to police itself** as the only control.
- **Filter both edges.** Validate/classify input (jailbreak and injection detection) and **moderate
  output** before it reaches a user or a tool. Output validation (§3) is also a safety control.
- **PII never leaves the boundary unredacted.** Don't send PII to third-party providers without a
  DPA and a lawful basis; scrub before the call; honor zero-retention (§9 / §11). Rules live in
  [../practices/data-privacy.md](../practices/data-privacy.md).
- **Assume jailbreaks succeed sometimes.** The real control is **blast radius**: what can the model
  actually *do*? Authz and reversibility (§5), not prompt cleverness, are the backstop.

## 8. Cost & latency — budget the tokens

Tokens are money and milliseconds. Make both first-class, measured (§10), and bounded.

- **Tier the model.** Route by difficulty: a cheap/fast model for the bulk, escalate to a frontier
  model only for hard cases. Set a **per-request and per-user token budget** and enforce it.
- **Cache aggressively.** **Prompt caching** for stable prefixes (system prompt, few-shot, RAG
  context) cuts cost and latency hugely; an exact-match/semantic **response cache** for repeated
  queries. (Provider-specific caching mechanics → `claude-api` skill / [../design/resilience.md](../design/resilience.md) §7.)
- **Stream user-facing responses.** Stream tokens so time-to-first-token, not total latency, is what
  the user feels.
- **Batch the offline work _(scale-up)_.** Non-interactive jobs (evals, bulk enrichment,
  embeddings) go through batch APIs at a steep discount — never the real-time endpoint.
- **Keep context lean.** Long prompts cost on every call; trim history, retrieve few chunks (§4),
  summarize rolling context.

## 9. Reliability — providers fail; plan for it

A model API is a slow, flaky third party. Everything in
[../design/resilience.md](../design/resilience.md) applies; the LLM-specific bits:

- **Timeouts + bounded retries with jitter** on every call; **never retry a content refusal or a
  4xx** (defer to resilience §1–2). LLM calls are slow — set generous-but-finite deadlines.
- **Fallback model.** On provider outage/rate-limit, fail over to a second provider or a smaller
  model behind the same validated schema (§3) — a degraded answer beats a 500
  ([../design/resilience.md](../design/resilience.md) §6).
- **Handle truncation and refusals as first-class outcomes**, not exceptions: check the stop reason;
  `max_tokens` hit mid-JSON is a parse failure you must catch.
- **Rate-limit and shed** at your edge before the provider does it for you (resilience §4).

## 10. Observability — trace every call

You can't debug or cost-control what you can't see. Use the OTel **GenAI semantic conventions** and
defer the pipeline to [../platform/observability.md](../platform/observability.md).

- **Trace each LLM/agent step as a span:** model + version, prompt ID/version, token counts
  (in/out), **cost**, latency, stop reason, tool calls, and a sampled trace through retrieval. An
  agent run is a trace; each tool call a child span.
- **Log responsibly.** Prompts/completions are gold for debugging *and* a PII/secret leak risk —
  redact before storage, gate raw payloads behind access control and short retention
  ([../practices/data-privacy.md](../practices/data-privacy.md)).
- **Dashboard the AI golden signals:** cost/req, p99 latency, token usage, error/refusal rate, eval
  score over time, cache hit-rate. Alert on cost and quality regressions, not just 5xx.

## 11. Reproducibility & data governance

- **Pin everything that moves the output.** Exact model **version/snapshot** (never a floating
  `latest` alias), `temperature`, `top_p`, `seed` where supported, prompt version, and embedding
  model version — recorded with each result so a run is reproducible and a regression is bisectable.
- **A model upgrade is a migration, not a config bump.** Re-run the full eval suite (§6) before
  switching; provider model updates silently change behaviour.
- **Don't train on customer data without consent.** Default to providers/endpoints with **zero data
  retention** and **no-train** terms for customer content; a **DPA** is required for any provider
  that processes user PII ([../practices/data-privacy.md](../practices/data-privacy.md) §7). Make
  the no-train/ZDR posture explicit and verifiable, not assumed.

## Definition of done

- [ ] LLM is the **justified** choice — not reachable by plain code or a cheaper classical model
- [ ] Prompts are **versioned templates** in the repo (not inline strings), reviewed with an eval run
- [ ] Outputs are **schema-constrained** (tool/JSON-schema) and **validated at the boundary** (Instructor/Pydantic/Zod), reject-and-repair bounded
- [ ] _(RAG)_ retriever evaluated separately; **hybrid + rerank**; answers **cite or abstain**; embedding model pinned
- [ ] _(agents)_ tools are narrow/least-privilege; loop is **bounded** (iterations/budget); **human-in-the-loop** on irreversible actions
- [ ] **Golden eval set** committed; **regression evals gate CI** (promptfoo/Braintrust/Langfuse); LLM-judge calibrated against humans
- [ ] **Prompt-injection** defenses in depth: untrusted text isolated, input/output filtered, blast radius bounded by authz; no PII to providers without DPA
- [ ] **Token budgets** set; model **tiered**; prompt caching + response cache on; user-facing responses **streamed**; offline work batched _(scale-up)_
- [ ] Timeouts + bounded retries (no retry on refusal/4xx); **fallback model**; truncation/stop-reason handled (defer to resilience)
- [ ] Every call **traced** (model/prompt version, tokens, cost, latency) via OTel GenAI conventions; prompts/completions redacted before storage
- [ ] Model snapshot, temperature, seed, prompt + embedding versions **pinned and recorded**; upgrades re-run the eval suite
- [ ] Provider on **zero-retention / no-train** terms for customer data; DPA on file

**Sources:** [OWASP Top 10 for LLM Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/) · [OpenTelemetry GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) · [Ragas](https://docs.ragas.io/) · [promptfoo](https://www.promptfoo.dev/) · [DSPy](https://dspy.ai/)
