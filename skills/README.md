# Skills

Claude Code **skill wrappers** — thin pointers that surface the right [`standards/`](../standards/README.md)
doc at the right moment (on a matching file edit, dependency, or task). Each `SKILL.md` inlines the
load-bearing rules so it stays useful even when copied standalone into `~/.claude/skills/`; the
canonical depth always lives in `standards/`.

## Install

```bash
cp -r skills/* ~/.claude/skills/          # global, all repos
# or, per-repo:
cp -r skills/* /path/to/repo/.claude/skills/
```

## What's here

`touchstone` is the **meta/router** skill — load it first; it routes to the rest. A generated,
per-skill index with full descriptions lives in [`CATALOG.md`](CATALOG.md).

| Skill | Standard |
|---|---|
| `touchstone` | router → all of `standards/` |
| `python-` · `typescript-` · `go-` · `rust-` · `java-kotlin-` · `csharp-` · `swift-` · `php-` · `ruby-` · `elixir-` · `zig-` · `solidity-` · `shell-standards` | `standards/languages/*.md` |
| `react-` · `next-` · `nuxt-` · `svelte-` · `vue-` · `angular-` · `solid-` · `astro-standards` (frontend) | `standards/frameworks/*.md` |
| `fastapi-` · `litestar-` · `django-` · `gin-` · `node-backend-` · `spring-boot-` · `aspnet-core-` · `rails-` · `laravel-` · `phoenix-` · `axum-standards` (backend) | `standards/frameworks/*.md` |
| `react-native-` · `flutter-` · `swiftui-` · `jetpack-compose-standards` (mobile) | `standards/frameworks/*.md` |
| `docker-` · `devops-` · `ci-cd-` · `database-` · `observability-` · `terraform-` · `kubernetes-` · `monorepo-` · `caching-` · `data-engineering-` · `search-standards` | `standards/platform/*.md` |
| `security-` · `app-security-` · `testing-strategy-` · `code-quality-` · `performance-` · `accessibility-` · `documentation-` · `git-workflow-` · `ai-engineering-standards` | `standards/practices/*.md` |
| `api-design-` · `event-driven-` · `graphql-` · `grpc-standards` | `standards/design/*.md` |

## Format

Every `SKILL.md` follows one template (`templates/SKILL.md`): frontmatter (`name` == dir,
`description` with a "Use when…" trigger) → `Full standard:` pointer → `## Always` (required, first)
→ one or more domain-specific sections → `## Done`. CI validates this via [`scripts/check-skills.sh`](../scripts/).
When you change a standard, update its skill in the same PR so they don't drift.
