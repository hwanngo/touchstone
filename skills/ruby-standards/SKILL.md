---
name: ruby-standards
description: Use when writing, reviewing, testing, formatting, or configuring any Ruby code (.rb files, Gemfile, .gemspec) in a touchstone repo — version-manager + .ruby-version pin, Bundler with committed Gemfile.lock, RuboCop (+performance/+rspec), RBS/Steep or Sorbet, RSpec, YJIT. Invoke before adding gems, editing specs, touching types, or changing error handling. Rails-specific concerns (controllers, ActiveRecord, migrations) → rails-standards skill.
license: MIT
metadata:
  version: 0.2.0
  author: touchstone
---

# Ruby Standards

Full standard: **`standards/languages/ruby.md`** in the touchstone repo. This skill inlines the
load-bearing rules so it stays useful even when installed standalone in `~/.claude/skills/`:

## Always
- **Bundler only** (`bundle add`/`install`/`exec`). Commit `Gemfile.lock` (apps **and** gems); CI runs `bundle install --frozen`.
- Pin Ruby in **`.ruby-version`** (3.3 floor, target 3.4) via mise/rbenv — never the system Ruby; same string CI installs.
- Lint + format with **RuboCop** (`+rubocop-performance +rubocop-rspec`, `NewCops: enable`); CI runs `rubocop` with no autocorrect — a red cop is a red build.
- **`# frozen_string_literal: true` at the top of every `.rb` file.**
- Type-check with **RBS + Steep** (default) or **Sorbet** — one per repo, new code at the strict bar.

## Don't get burned
- **Never bare `rescue`** (or `rescue Exception`) — it swallows signals/`SystemExit`; `rescue => e` scopes to `StandardError`. No rescue-log-continue; re-raise or record. Errors under one base class.
- **`Data.define`** for immutable value objects (not mutable `Struct`); **pattern matching** (`case/in`) to parse API/JSON shapes; explicit **keyword args** (not splatted hashes).
- **Don't over-mock:** stub at the boundary (WebMock/VCR, the clock), real objects inward; `verify_partial_doubles = true`. Run specs order-randomized; `pending` is a tripwire, not a graveyard.
- **GVL:** threads/Fibers for I/O-bound, processes for CPU-bound; Ractor only _(scale-up)_ for isolated compute. Profile with stackprof before optimizing; YJIT on in prod.
- **`standard`** is the escape hatch from RuboCop config — but you lose the performance/security cops, so it's a deliberate trade.
- `bundler-audit check --update` clean; pin gems pessimistically (`~>`); publish via MFA + OIDC.

## Done
`rubocop` clean · every file frozen-string · `steep check` (or `srb tc`) clean · `rspec` green (randomized, coverage ≥ floor) · `bundle install --frozen` passes, `Gemfile.lock` committed · `bundler-audit` clean. See `standards/languages/ruby.md`.
