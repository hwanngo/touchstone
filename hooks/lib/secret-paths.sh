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
is_secret_path() {
  local base rc had=0
  base="$(basename -- "$1" 2>/dev/null)" || return 1
  [ -z "$base" ] && return 1
  rc=1
  # Save/restore rather than unconditionally clobbering: a caller that already had nocasematch
  # set (or unset) must see it unchanged on return.
  shopt -q nocasematch && had=1
  shopt -s nocasematch
  case "$base" in
  *.example | *.example.* | *.sample | *.sample.* | *.template | *.template.*) rc=1 ;;
  .env | .env.* | .envrc | *.env) rc=0 ;;
  esac
  [ "$had" -eq 1 ] || shopt -u nocasematch
  return "$rc"
}
