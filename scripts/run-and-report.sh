#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# BugMojo Verify — run repro specs against the deployed build and report each
# result to POST /api/webhooks/ci. Part of the verified loop (Wave 3b).
#
# Env (set by action.yml):
#   DEPLOYED_URL       base URL of the deployed build under test
#   BUGMOJO_URL        base URL of the BugMojo instance
#   CI_WEBHOOK_SECRET  shared secret for the CI webhook (X-CI-Secret header)
#   BUG_KEY            optional single bug key; else derived per spec filename
#   SPEC_GLOB          glob of repro specs (default tests/bugmojo/**/*.spec.ts)
#
# Bug-key convention: each repro spec is named for the bug it verifies, e.g.
#   tests/bugmojo/WEB-42.spec.ts        -> bug_key "WEB-42"
#   tests/bugmojo/WEB-42-checkout.spec.ts -> bug_key "WEB-42" (prefix before 2nd dash)
# Override with the `bug-key` input to force a single key for all specs.
# ---------------------------------------------------------------------------
set -uo pipefail

: "${DEPLOYED_URL:?DEPLOYED_URL is required}"
: "${BUGMOJO_URL:?BUGMOJO_URL is required}"
: "${CI_WEBHOOK_SECRET:?CI_WEBHOOK_SECRET is required}"
SPEC_GLOB="${SPEC_GLOB:-tests/bugmojo/**/*.spec.ts}"
BUG_KEY="${BUG_KEY:-}"

CI_ENDPOINT="${BUGMOJO_URL%/}/api/webhooks/ci"

# Derive a bug key ("WEB-42") from a spec path like tests/bugmojo/WEB-42-foo.spec.ts
derive_bug_key() {
  local path="$1"
  local base
  base="$(basename "$path")"
  base="${base%.spec.ts}"
  # Keep everything up to and including the LAST "-<number>" group (the issue
  # number), dropping any trailing "-description". This preserves composite
  # project keys, e.g.  MY-APP-13-checkout  ->  MY-APP-13.
  echo "$base" | sed -E 's/^(.*-[0-9]+)(-[^0-9].*)?$/\1/'
}

# POST a single result to the CI webhook. Args: bug_key passed proof_url
report_result() {
  local bug_key="$1" passed="$2" proof_url="$3"
  echo "-> reporting ${bug_key}: passed=${passed}"
  curl --fail-with-body --silent --show-error \
    -X POST "$CI_ENDPOINT" \
    -H 'Content-Type: application/json' \
    -H "X-CI-Secret: ${CI_WEBHOOK_SECRET}" \
    -d "{\"bug_key\":\"${bug_key}\",\"passed\":${passed},\"proof_url\":\"${proof_url}\"}" \
    || echo "!! failed to report result for ${bug_key} (continuing)"
  echo
}

PROOF_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-local}"

# Expand the glob (bash globstar for **).
shopt -s globstar nullglob
SPECS=( $SPEC_GLOB )

if [ "${#SPECS[@]}" -eq 0 ]; then
  echo "No repro specs matched '${SPEC_GLOB}'. Nothing to verify."
  exit 0
fi

OVERALL_RC=0
for spec in "${SPECS[@]}"; do
  key="$BUG_KEY"
  if [ -z "$key" ]; then
    key="$(derive_bug_key "$spec")"
  fi

  echo "=== Running repro: ${spec} (bug ${key}) against ${DEPLOYED_URL} ==="
  # Point Playwright's baseURL at the deployed build via our shipped config
  # (playwright.bugmojo.config.ts reads BUGMOJO_DEPLOYED_URL). The emitted BugMojo
  # repros navigate with baseURL-relative page.goto('/path'), so this is what
  # makes them hit the patched build.
  if BUGMOJO_DEPLOYED_URL="$DEPLOYED_URL" \
       npx playwright test "$spec" \
         --config "${BUGMOJO_ACTION_PATH:-.}/playwright.bugmojo.config.ts" \
         --reporter=line; then
    report_result "$key" "true" "$PROOF_URL"
  else
    OVERALL_RC=1
    report_result "$key" "false" "$PROOF_URL"
  fi
done

# Exit non-zero if any repro failed, so the CI job status also reflects reality.
exit "$OVERALL_RC"
