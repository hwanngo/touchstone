# Ruby on Rails Standards

Framework layer; language rules → [ruby.md](../languages/ruby.md).

Current Rails (target the **7.2+** floor; verify the release) — omakase, convention-over-configuration, MVC on ActiveRecord.
This doc owns only the Rails-shaped decisions. Cross-cutting concerns are **deferred, not repeated**:
API contracts → [api-design.md](../design/api-design.md), schema/migrations →
[database.md](../platform/database.md), retries/idempotency → [resilience.md](../design/resilience.md),
authN/authZ/OWASP → [app-security.md](../practices/app-security.md), test strategy →
[testing-strategy.md](../practices/testing-strategy.md), dependencies/supply-chain → [ruby.md](../languages/ruby.md) + [security.md](../practices/security.md). Sibling: [django.md](django.md).

---

## 1. Structure & "the Rails way"

Lean on convention first — directory layout, naming, and REST are load-bearing. Earn every deviation.
The real debate is **fat models vs skinny controllers**: both fail at scale. Keep controllers thin,
keep models focused on persistence + field-local invariants, and push multi-step business logic into
**service objects / POROs** under `app/services/`.

| Concern | Rule |
|---|---|
| Controllers | **Thin**: authenticate → strong-params → call one service/model method → respond. No business logic, no multi-model writes, no N+1-causing view prep. |
| Models | Own persistence, associations, validations, scopes, and field-local invariants — not cross-aggregate workflows. A 600-line `User` model is a smell, not a badge. |
| Service objects | One public `call` per use case (`Orders::Place`, `Billing::Refund`) returning a Result, not raising for control flow. This is where transactions, orchestration, and side-effects live. |
| Concerns | Extract **shared behavior** (`Trashable`, `Tokenizable`), not a junk drawer to shrink a fat model. A concern that only one class includes is just hidden code. |
| POROs | Plain Ruby for value objects, query objects, and policies — not everything must be an `ActiveRecord` subclass. |

```ruby
# app/services/orders/place.rb
module Orders
  class Place
    Result = Struct.new(:ok?, :order, :error)

    def self.call(...) = new(...).call

    def initialize(cart:, user:)
      @cart, @user = cart, user
    end

    def call
      order = nil
      ActiveRecord::Base.transaction do            # short, no network calls inside
        order = Order.create!(user: @user, total: @cart.total)
        @cart.line_items.each { order.items.create!(_1.attributes) }
      end
      Result.new(true, order, nil)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(false, nil, e.message)
    end
  end
end
```

## 2. ActiveRecord

The ORM is the default for the 80% (CRUD, lookups); drop to `find_by_sql`/Arel for hot
reporting/window queries and own the plan. Conventions (naming, PK choice, indexes, `timestamptz`/UTC)
→ [database.md](../platform/database.md).

| Concern | Rule |
|---|---|
| N+1 | **`includes`** (or `preload`/`eager_load`) on any association a view/serializer walks. Gate it: run **`bullet`** in dev/test to fail on undetected N+1, and assert on hot paths. |
| Scopes | Name canonical filters as `scope :active, -> { where(archived_at: nil) }` — never copy-paste `.where(...)` across controllers. Compose scopes; keep them chainable. |
| Validations | Enforce **in the model** (`validates :email, presence: true, uniqueness: true`) **and** back uniqueness with a DB unique index — model validation alone races. |
| Callbacks | **Avoid callbacks for business logic** (`after_save` that charges a card, sends mail, mutates other aggregates). They fire on every path, defy testing, and hide side-effects. Keep callbacks for field-local normalization only; orchestration belongs in a service. |
| Querying | `.exists?` not `.present?` on a relation; `.pluck`/`.select` to trim columns; `.find_each`/`.in_batches` for large scans; `insert_all`/`upsert_all` for bulk. Push filtering into SQL, not Ruby. |

### Migrations

Every schema change is a **reviewed, committed migration**; `bin/rails db:migrate` runs as a
**deploy step**. CI gates `db:migrate` + `db:rollback` against a throwaway DB, and a clean
`db/schema.rb` (no drift). Use **`strong_migrations`** to block unsafe ops (adding a `NOT NULL`
column, backfilling in a DDL migration, index-without-`algorithm: :concurrently`).

- **Zero-downtime = expand → contract** ([database.md](../platform/database.md)): additive migration
  first, backfill in a **separate idempotent task/job** (never a heavy inline `update_all` holding
  locks during deploy), drop the old column in a *later* release. Renames and `NOT NULL`-on-existing
  are expand/contract in disguise.
- Add indexes with `disable_ddl_transaction!` + `algorithm: :concurrently` so you don't lock writes.

## 3. Strong parameters & form/request objects

Mass assignment is the classic Rails CVE — **strong parameters are mandatory** at the controller
boundary. Never `Model.new(params)` raw.

```ruby
def order_params
  params.require(:order).permit(:total, items_attributes: %i[sku qty])
end
```

- For anything past a single model — multi-step forms, search filters, API payloads — introduce a
  **form object / request object** (an `ActiveModel::Model` PORO) that validates the *shape* of input
  before it reaches a service. Keeps controllers thin and validation testable in isolation.
- `permit!` (allow-all) is banned in app code. Nested params are explicitly permitted, never wildcarded.

## 4. Routing

RESTful **`resources`** is the default — map use cases onto the seven standard actions before
inventing custom routes.

- `resources :orders` (nest **one level** deep, max); reach for member/collection routes only for a
  genuinely non-CRUD verb, and prefer a **nested resource** (`resources :orders do; resource :refund; end`)
  over an ad-hoc `post :refund`.
- Name every route; use path helpers (`order_path(order)`) — never hand-build URL strings.
- Constrain formats and params (`constraints`, `defaults: { format: :json }`); version APIs via a
  namespace (`namespace :api do; namespace :v1`). Contract/versioning → [api-design.md](../design/api-design.md).

## 5. Hotwire (Turbo + Stimulus)

**Hotwire is the default frontend** — server-rendered HTML over the wire, sprinkled with JS. Reach
for a SPA only when a genuinely app-like surface demands it, and justify the cost.

| Piece | Use |
|---|---|
| Turbo Drive | Free SPA-feel navigation — already on; don't fight it with full-page reloads. |
| Turbo Frames | Scope a page region for independent navigation/lazy-load (`turbo_frame_tag`). |
| Turbo Streams | Surgical DOM updates over WebSocket/response (`turbo_stream.replace`) — pair with `broadcasts_to` for live updates. |
| Stimulus | Modest, sprinkled behavior bound to HTML (`data-controller`) — not an app framework. Keep controllers small and stateless. |

- Render Turbo Stream responses from the same controller action (`respond_to`), not a parallel JS API.
- Heavy/interactive islands can drop to a JS framework via `importmap` or a bundler — but the **page
  shell stays server-rendered**. Accessibility still applies — see the frontend standards.

## 6. APIs & serialization

For JSON APIs, the **serializer is the boundary** — never render an AR model field-for-field
(`render json: @order` leaks columns you add later).

- HTML-shaped JSON / view-driven payloads: **`jbuilder`** templates. Resource APIs: a serializer
  layer (**`alba`** for speed, or `jsonapi-serializer`) with explicit attribute allowlists and
  read/write separation.
- Use `ActionController::API` for API-only controllers; map domain errors → status centrally with
  `rescue_from`, emitting a consistent error body (RFC 9457 `application/problem+json` preferred).
- Pagination, versioning, idempotency keys, envelope shape → [api-design.md](../design/api-design.md).

## 7. Background jobs

Out-of-request work (mail, webhooks, exports, third-party calls) goes through **Active Job**. The
default backend on Rails 8 is **Solid Queue** (DB-backed, no Redis); **Sidekiq** _(scale-up)_ when you
need its throughput/observability. Never fire-and-forget threads in the request path.

- **Jobs must be idempotent and retry-safe** — they will run more than once. Key on an idempotency
  token, make the effect a no-op on replay, bound retries with backoff. Patterns →
  [resilience.md](../design/resilience.md).
- **Don't pass AR objects** to jobs — pass the **id** and re-fetch (GlobalID does this; the row may
  have changed or vanished). Enqueue **after commit** (`after_commit` / Active Job's default) so a
  rolled-back write can't dispatch a job for a row that never persisted.
- Jobs are thin wrappers over the same **service layer** (§1) — no business logic in the job body.

## 8. Security

Rails ships strong defaults — the job is to **not undo them**. Run **`brakeman`** as a CI gate and
`bundle audit` for vulnerable gems.

| Built-in | Rule |
|---|---|
| CSRF | `protect_from_forgery` is on by default for cookie/session forms — keep it. Token/JWT APIs are CSRF-exempt by design (no cookie auth); don't blanket-disable. |
| Strong params | Mandatory (§3); `permit!` banned — mass-assignment is the canonical breach. |
| SQL injection | AR parameterizes by default; interpolate **only** via placeholders (`where("name = ?", n)` / `where(name: n)`), **never** string-build. `find_by_sql`/Arel use bind params. |
| XSS | ERB auto-escapes — don't `raw`/`html_safe` untrusted data; sanitize rich text via Action Text. |
| Secrets | **Encrypted credentials** (`config/credentials.yml.enc` + `RAILS_MASTER_KEY`) or a secret manager — never secrets in source or plaintext ENV files. Encrypt PII columns with Active Record Encryption. |

- AuthN/authZ policy, password/session model, OWASP coverage → [app-security.md](../practices/app-security.md).
  Use a vetted auth library (`devise`, or Rails 8's built-in `authenticate` generator) — don't hand-roll.

## 9. Caching

Rails 8's default cache store is **Solid Cache** (DB-backed, disk-fast, no separate Redis to run).

- **Fragment + Russian-doll caching** for view-heavy pages: nest `cache` blocks keyed on the record
  (`cache [order, order.items]`) so an inner change busts only its fragment. `touch: true` on
  associations propagates the bust upward.
- Cache keys derive from `updated_at` + version — never hand-roll keys you must manually expire.
- Cache at the **right layer**: HTTP caching (`fresh_when`/`stale?` + ETags) for whole responses,
  fragments for view chunks, memoization for per-request reuse. Don't cache un-authorized data
  per-user without scoping the key.

## 10. Testing

**RSpec** (`rspec-rails`) or **Minitest** (the omakase default) — pick one per repo and commit.
Strategy/coverage → [testing-strategy.md](../practices/testing-strategy.md).

- **`factory_bot`** for test data — never committed fixtures-as-truth or hand-built hashes; factories
  stay resilient to added non-null columns.
- **System tests** (Capybara + a real headless browser) for the Hotwire happy paths — Turbo Streams
  only prove out end-to-end. Request specs for API contracts (assert **status + serialized shape**).
- Run against **real Postgres**, not SQLite — SQLite hides constraint/transaction/JSON differences
  that bite in prod. Lock N+1 with `bullet` raising in test (§2).
- Cover the **authorization-denied and error paths**, not just the happy path.

## 11. The Solid Trifecta & deploy

Rails 8's headline: the **Solid Trifecta** — **Solid Queue** (jobs), **Solid Cache** (caching), and
**Solid Cable** (Action Cable) — all DB-backed, so a new app ships with **no Redis** to operate.
Adopt them as the default; add Redis/Sidekiq only when load justifies the extra moving part _(scale-up)_.

- **Kamal** is the omakase deploy — container-based, zero-downtime, no PaaS lock-in. `bin/kamal deploy`
  runs migrations as a release step; keep them expand/contract (§2) so old and new app versions
  coexist during the rollout. CI/CD wiring → [database.md](../platform/database.md).

## Definition of done

- [ ] Controllers thin (authenticate → strong-params → service/model → respond); business logic in `app/services` POROs, not callbacks or fat models.
- [ ] Strong parameters at every controller boundary; `permit!` absent; multi-model input goes through a form/request object.
- [ ] N+1 guarded with `includes` + `bullet` raising in test; canonical filters as scopes; uniqueness backed by a DB index.
- [ ] Callbacks limited to field-local normalization; no `after_*` side-effects (mail/charges/cross-aggregate writes).
- [ ] Schema changes are reviewed migrations; `strong_migrations` gates unsafe ops; backfills run as separate jobs (expand/contract); indexes added concurrently.
- [ ] RESTful `resources` (≤1 level nesting); named path helpers; APIs serialized through an allowlist boundary, never `render json: model`.
- [ ] Hotwire is the frontend default; Turbo Stream responses from the owning action; Stimulus controllers small and stateless.
- [ ] Background work on Active Job (Solid Queue / Sidekiq); jobs idempotent, pass ids, enqueue after commit.
- [ ] `brakeman` + `bundle audit` clean; CSRF intact; no string-interpolated SQL; secrets in encrypted credentials/secret manager; PII encrypted.
- [ ] Caching via Solid Cache with fragment/Russian-doll keys derived from `updated_at`; HTTP caching with ETags where whole responses are cacheable.
- [ ] Tests on RSpec/Minitest + `factory_bot` against real Postgres; system tests cover Hotwire flows; auth-denied/error paths covered.
- [ ] Deploy via Kamal with migrations as an expand/contract release step.

**Sources:** [Rails Guides](https://guides.rubyonrails.org/) · [Rails 8.0 release notes](https://guides.rubyonrails.org/8_0_release_notes.html) · [Hotwire](https://hotwired.dev/) · [Solid Queue](https://github.com/rails/solid_queue) · [Solid Cache](https://github.com/rails/solid_cache) · [strong_migrations](https://github.com/ankane/strong_migrations) · [Kamal](https://kamal-deploy.org/)
