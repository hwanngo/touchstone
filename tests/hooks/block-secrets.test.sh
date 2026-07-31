#!/usr/bin/env bash
# Write-guard cases: secret paths and secret content.
# PEM headers are assembled from fragments so this file does not contain a literal
# key header — the live guard denies writes containing one, including this test.
set -uo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/../lib/assert.sh"
# shellcheck disable=SC1091
. "$DIR/../lib/hookcase.sh"
HOOK="$DIR/../../hooks/block-secrets.sh"

DASH5="-----"
BEG="${DASH5}BEGIN"
END="${DASH5}END"
PK="PRIVATE KEY"

path_case() { # <expected> <path>
  assert_eq "path $2" "$1" "$(write_decision "$HOOK" "$2")"
}

body_case() { # <expected> <label> <content>
  assert_eq "content $2" "$1" "$(write_decision "$HOOK" "notes.txt" "$3")"
}

notebook_case() { # <expected> <label> <notebook-path> <new-source>
  assert_eq "notebook $2" "$1" "$(notebook_decision "$HOOK" "$3" "${4-}")"
}

# --- paths that must be denied ---
path_case deny "/r/.env"
path_case deny "/r/.env.local"
path_case deny "/r/.env.production"
path_case deny "/r/.ENV"
path_case deny "/r/.Env"
path_case deny "/r/.envrc"
path_case deny "/r/prod.env"

# --- paths that must be allowed ---
path_case allow "/r/.env.example"
path_case allow "/r/.env.sample"
path_case allow "/r/.env.template"
path_case allow "/r/README.md"
path_case allow "/r/environment.ts"

# --- content that must be denied ---
body_case deny "rsa" "$BEG RSA $PK$DASH5
AAAA
$END RSA $PK$DASH5"
body_case deny "openssh" "$BEG OPENSSH $PK$DASH5
AAAA
$END OPENSSH $PK$DASH5"
body_case deny "pgp" "$BEG PGP $PK BLOCK$DASH5
AAAA
$END PGP $PK BLOCK$DASH5"

# --- content that must be allowed ---
body_case allow "public key" "${BEG} PUBLIC KEY${DASH5}
AAAA
${END} PUBLIC KEY${DASH5}"
body_case allow "prose" "We never commit private keys to the repo."

# --- NotebookEdit: notebook_path and new_source coverage ---
notebook_case deny "secret path" "/r/.env" ""
notebook_case deny "key in new_source" "analysis.ipynb" "$BEG RSA $PK$DASH5
AAAA
$END RSA $PK$DASH5"
notebook_case allow "benign" "analysis.ipynb" "import pandas as pd"

ts_report
