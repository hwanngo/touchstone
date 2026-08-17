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

# Rows promoted from the guardrail-redteam campaign carry the attempt id that produced them
# (see the task-5b campaign record), so a reader can trace a row back to its attempt.
path_case_id() { # <attempt-id> <expected> <path>
  assert_eq "$1 path $3" "$2" "$(write_decision "$HOOK" "$3")"
}

body_case_id() { # <attempt-id> <expected> <path> <content>
  assert_eq "$1 content $3" "$2" "$(write_decision "$HOOK" "$3" "$4")"
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

# =====================================================================================
# Rows promoted from the guardrail-redteam campaign (task 5b). Every row below is named
# for the attempt it came from.
# =====================================================================================

DASH4="----"
BEG4="${DASH4} BEGIN"
END4="${DASH4} END"
PPK="PuTTY-User-Key""-File-3:"

# --- FALSE POSITIVE BS-040: security DOCUMENTATION that quotes a PEM header inline in prose was
#     denied — writing docs/security.md explaining what a private key looks like is exactly the
#     work this kit exists to do. A real key's header BEGINS a line (optionally indented, as in
#     an embedded YAML/JSON secret); a header quoted mid-sentence does not. ---
body_case_id BS-040 allow "docs/security.md" "## Never commit keys

If a file begins with \`$BEG RSA $PK$DASH5\`, it is a private key. Delete it and rotate.
"
body_case_id BS-040b allow "docs/security.md" "A footer line reading \`$END RSA $PK$DASH5\` is the other half."
# indentation is not prose: an embedded key in YAML must still deny
body_case_id BS-040c deny "k8s/secret.yaml" "data:
  tls.key: |
    $BEG RSA $PK$DASH5
    AAAA
    $END RSA $PK$DASH5"

# --- FALSE POSITIVE BS-041: a throwaway TEST FIXTURE key. Crypto/TLS/SSH suites legitimately
#     commit test keys; there was no path allowlist the way there is a `*.example.*` name
#     allowlist. Narrow on purpose — a `fixtures`/`testdata` PATH COMPONENT, nothing broader. ---
body_case_id BS-041 allow "tests/fixtures/throwaway_rsa_test_key.pem" "$BEG RSA $PK$DASH5
MIIEowIBAAKCAQEAtestkeyonlyfortests==
$END RSA $PK$DASH5
"
body_case_id BS-041b allow "internal/testdata/key.pem" "$BEG RSA $PK$DASH5
AAAA
$END RSA $PK$DASH5"
# the allowlist is a path COMPONENT, not a substring, and it does not cover ordinary source
body_case_id BS-041c deny "src/fixtures_helper.go" "$BEG RSA $PK$DASH5
AAAA
$END RSA $PK$DASH5"
body_case_id BS-041d deny "deploy/key.pem" "$BEG RSA $PK$DASH5
AAAA
$END RSA $PK$DASH5"

# --- BYPASS BS-021/022/024: the PEM label class excluded digits and the header had to have
#     exactly five dashes and no space, so the standard RFC 4716 / ssh.com private key escaped in
#     both its spellings. BS-024 (four-dash RSA) was UNCERTAIN and resolves here: the rule targets
#     key-shaped material, not only what openssl will parse. ---
body_case_id BS-021 deny "deploy/key.ssh2" "$BEG SSH2 ENCRYPTED $PK$DASH5
P2/56wAAAgIAAAAmZGwtbW9kcAAAA
$END SSH2 ENCRYPTED $PK$DASH5"
body_case_id BS-022 deny "deploy/key.ssh2" "$BEG4 SSH2 ENCRYPTED $PK $DASH4
Comment: \"rsa-key-20240101\"
P2/56wAAAgIAAAAmZGwtbW9kcAAAA
$END4 SSH2 ENCRYPTED $PK $DASH4"
body_case_id BS-024 deny "deploy/key.pem" "${DASH4}BEGIN RSA $PK$DASH4
MIIEowIBAAKCAQEAx7Vq9k2mQ==
${DASH4}END RSA $PK$DASH4"

# --- BYPASS BS-023: a PuTTY `.ppk` private key has no PEM header at all. ---
body_case_id BS-023 deny "deploy/key.ppk" "$PPK ssh-rsa
Encryption: none
Comment: rsa-key-20240101
Public-Lines: 6
AAAAB3NzaC1yc2EAAAADAQABAAABAQC
Private-Lines: 14
AAABAQCx7Vq9k2mQ8ZlKQnJ3vXbYd
Private-MAC: 5f3a"
body_case_id BS-023b allow "docs/keys.md" "A putty key file starts with \`$PPK ssh-rsa\`."

# --- BYPASS BS-033: only the BEGIN header was ever examined, so a complete key with a mangled
#     BEGIN and an intact END footer passed. ---
body_case_id BS-033 deny "deploy/key.pem" "${DASH5}BEGIN RSAXX
MIIEowIBAAKCAQEAx7Vq9k2mQ==
$END RSA $PK$DASH5"

# --- BYPASS BS-030: ONE MultiEdit call reconstructs a header on disk while no single field
#     contains it — the fields were joined with a newline, so the two halves never shared a line
#     for grep, yet land adjacent in the file. The fields are now ALSO joined with nothing. ---
assert_eq "BS-030 multiedit reassembles a key header" "deny" \
  "$(multiedit_decision "$HOOK" "deploy/key.pem" "${DASH5}BEGIN RSA" " $PK$DASH5
MIIEowIBAAKCAQEAx7Vq9k2mQ==
$END RSA $PK$DASH5")"
assert_eq "multiedit of unrelated fragments still allows" "allow" \
  "$(multiedit_decision "$HOOK" "src/app.ts" "const a = 1;" "const b = 2;")"
# The row above also carries an intact END footer, so the footer widening alone would deny it.
# This one has NO footer and no complete header in either field, so it can only be caught by the
# no-separator join — which is the defect BS-030 actually reported.
assert_eq "BS-030b multiedit header split with no footer to fall back on" "deny" \
  "$(multiedit_decision "$HOOK" "deploy/key.pem" "${DASH5}BEGIN RSA" " $PK$DASH5
MIIEowIBAAKCAQEAx7Vq9k2mQ==")"

# --- BYPASS BS-010..013, BS-051: `.env`-family name gaps, reached through the Write tool. ---
path_case_id BS-010 deny ".envrc.local"
path_case_id BS-011 deny ".env~"
path_case_id BS-012 deny ".flaskenv"
path_case_id BS-013 deny ".env-production"
path_case_id BS-051 deny "config/env.production"
path_case deny "/r/.env_production"
path_case deny "/r/env.staging"
path_case deny "/r/.envrc.private"
# ...and the names that must stay allowed. `env.<ext>` is ordinary application source in the
# TypeScript ecosystem (`src/env.ts` from @t3-oss/env is everywhere), which is why the dotless
# form is matched against deployment-stage names only, never against any extension.
path_case allow "/r/src/env.ts"
path_case allow "/r/src/env.d.ts"
path_case allow "/r/src/env.mjs"
path_case allow "/r/env.example"
path_case allow "/r/.env.example~"
path_case allow "/r/README.md~"
path_case allow "/r/.zshenv"

# --- FALSE POSITIVE BS-192: `.env-*`/`.env_*` joined the deny patterns without the matching
#     template forms on the allowlist, so `.env.example` allowed while `.env-example` — the same
#     file, written by someone who separates with a hyphen — denied. A separator the deny side
#     treats as equivalent to `.` has to be equivalent on the allow side too. ---
path_case_id BS-192 allow "/r/.env-example"
path_case allow "/r/.env_example"
path_case allow "/r/.env-sample"
path_case allow "/r/.env_template"
path_case allow "/r/.env-example.bak"
path_case allow "/r/.ENV-EXAMPLE"
# The widening is anchored to the `.env` prefix, so the component-anchored rule it sits beside is
# untouched: "example" as a mere substring of a longer word is still not a template marker.
path_case deny "/r/prod-example.env"
path_case deny "/r/my-example.env"
path_case deny "/r/examples.env"
path_case deny "/r/.env-templates"
path_case deny "/r/.env-production"

# --- FALSE NEGATIVE BS-193: the `glued` view (the same edits joined with NOTHING, which exists so
#     a header reassembled across two MultiEdit edits is still seen) was matched against the PEM
#     pattern only, never the PuTTY one. So the .ppk magic line split across two edits reconstructed
#     a real key header on disk and was not caught — in the one place the second view was added to
#     cover exactly that. Both views are now matched against both patterns. ---
assert_eq "BS-193 multiedit reassembles a PuTTY .ppk magic line" "deny" \
  "$(multiedit_decision "$HOOK" "deploy/key.ppk" "PuTTY-User-Key-File-" "2: ssh-rsa
Encryption: none
Private-MAC: 5f3a")"
# The paired control: the single-edit form was always denied, so the row above must not be passing
# because of the path or some unrelated arm.
body_case_id BS-193b deny "deploy/key.ppk" "$PPK ssh-rsa
Encryption: none"
assert_eq "multiedit of unrelated fragments in a .ppk-named file still allows" "allow" \
  "$(multiedit_decision "$HOOK" "deploy/notes.txt" "PuTTY is a terminal" " emulator for Windows.")"

# --- The fixtures/testdata CONTENT exemption does NOT relax the PATH check. hooks/README.md claims
#     this in words; nothing asserted it, and it is the newest and broadest widening in this hook. ---
path_case deny "tests/fixtures/.env"
path_case deny "internal/testdata/.env.production"
path_case deny "src/__fixtures__/.envrc"
# ...while the content exemption those paths sit under still works for a throwaway key file.
body_case_id BS-041e allow "tests/fixtures/key.ppk" "$PPK ssh-rsa
Encryption: none"

ts_report
