#!/usr/bin/env bash
# Shared secret-path predicate, sourced by block-secrets.sh (Write/Edit/MultiEdit/NotebookEdit)
# and guard-bash.sh (Bash redirects). Keeping one copy is the point: a file blocked through one
# tool must not be writable through the other.
#
# Case-insensitive on purpose — macOS filesystems are case-insensitive by default, so a write
# to `.ENV` lands in `.env`.

# is_secret_path <path> -> 0 when the basename looks like a real secret file
#
# The allowlist is component-anchored: *.example.* (not the looser *.example*) so a template
# marker must appear as a full dot-delimited component. That allows a template-to-backup copy
# (.env.example.bak, .env.example.real, .example.env) — false denials are the greater harm in
# an advisory guard — without allowlisting a name like examples.env, which is genuinely
# secret-shaped with "example" as a mere substring. Backup suffixes are deliberately NOT on the
# allowlist: copying a real secret to a .bak (.env.bak) must keep denying.
#
# The DOTLESS `env.<stage>` family is matched against a fixed list of deployment-stage words, not
# against `env.*`. That looks timid until you notice `src/env.ts` and `src/env.mjs` — the
# @t3-oss/env convention — are everywhere in the TypeScript ecosystem, and `env.d.ts` in every
# Vite project. A blanket `env.*` would deny writing ordinary application source, which is a far
# worse defect than missing an `env.<something-unusual>`.
is_secret_path() {
  local base rc had=0
  base="$(basename -- "$1" 2>/dev/null)" || return 1
  [ -z "$base" ] && return 1
  # An editor/patch backup is the same file with a suffix stapled on, so strip a trailing `~`
  # before the name test: `.env~` denies, and `README.md~` still allows because what is left is
  # still not a secret name. Done before the allowlist too, so `.env.example~` stays allowed.
  base="${base%\~}"
  [ -z "$base" ] && return 1
  rc=1
  # Save/restore rather than unconditionally clobbering: a caller that already had nocasematch
  # set (or unset) must see it unchanged on return.
  shopt -q nocasematch && had=1
  shopt -s nocasematch
  case "$base" in
  *.example | *.example.* | *.sample | *.sample.* | *.template | *.template.*) rc=1 ;;
  # `.env-*` and `.env_*` were added to the deny list below without the matching template forms
  # here, so `.env.example` allowed while `.env-example` and `.env_sample` — the same file, written
  # by someone who separates with a hyphen — denied. A separator the deny side treats as equivalent
  # to `.` must be equivalent on the allow side too, or the allowlist is a spelling test rather than
  # a meaning test.
  #
  # Anchored to the `.env` prefix rather than written as a general `*-example`, deliberately: a
  # general form would also allowlist `prod-example.env` and `my-example.env`, which the
  # component-anchored rule above denies on purpose (see the paragraph at the top of this file —
  # "example" as a mere substring of a longer word is not a template marker). This arm widens
  # exactly the family the `.env-*`/`.env_*` patterns widened, and nothing else.
  .env-example | .env-example.* | .env-sample | .env-sample.* | .env-template | .env-template.* | \
    .env_example | .env_example.* | .env_sample | .env_sample.* | .env_template | .env_template.*) rc=1 ;;
  .env | .env.* | .env-* | .env_* | .envrc | .envrc.* | .flaskenv | *.env) rc=0 ;;
  env.prod | env.production | env.stage | env.staging | env.dev | env.development | \
    env.local | env.test | env.ci | env.qa | env.preview) rc=0 ;;
  esac
  [ "$had" -eq 1 ] || shopt -u nocasematch
  return "$rc"
}
