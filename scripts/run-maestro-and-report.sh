#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# BugMojo Verify (MOBILE) — run Maestro repro FLOWS against a built RN/Expo app
# and report each result to POST /api/webhooks/ci. The mobile analogue of
# run-and-report.sh; it reuses the EXACT SAME CI webhook contract (bug_key +
# passed + proof_url) so mobile bugs flow through the identical verified-loop
# state machine as web — no fork.
#
# Env (set by action-mobile.yml, or exported for a local dry run):
#   BUGMOJO_URL        base URL of the BugMojo instance
#   CI_WEBHOOK_SECRET  shared secret for the CI webhook (X-CI-Secret header)
#   BUG_KEY            optional single bug key; else derived per flow filename
#   FLOW_GLOB          glob of Maestro flows (default .maestro/bugmojo/**/*.flow.yaml)
#   MAESTRO_ENV        optional `key=value,key=value` passed to `maestro test -e`
#                      (e.g. APP_ID / DEEPLINK the flow references)
#
# There is NO deployed-URL for a native app — Maestro drives a build on an
# attached device / emulator / simulator (or a device-farm shard). The workflow
# is responsible for booting that device and installing the build BEFORE this
# script runs; here we only run the flows and report.
#
# Bug-key convention (identical to the web runner): each flow is named for the
# bug it verifies, e.g.
#   .maestro/bugmojo/MOB-42.flow.yaml         -> bug_key "MOB-42"
#   .maestro/bugmojo/MOB-42-checkout.flow.yaml -> bug_key "MOB-42"
# Override with the `bug-key` input to force a single key for all flows.
# ---------------------------------------------------------------------------
set -uo pipefail

: "${BUGMOJO_URL:?BUGMOJO_URL is required}"
: "${CI_WEBHOOK_SECRET:?CI_WEBHOOK_SECRET is required}"
FLOW_GLOB="${FLOW_GLOB:-.maestro/bugmojo/**/*.flow.yaml}"
BUG_KEY="${BUG_KEY:-}"
MAESTRO_ENV="${MAESTRO_ENV:-}"

CI_ENDPOINT="${BUGMOJO_URL%/}/api/webhooks/ci"

# Derive a bug key ("MOB-42") from a flow path like .maestro/bugmojo/MOB-42-foo.flow.yaml
derive_bug_key() {
  local path="$1"
  local base
  base="$(basename "$path")"
  base="${base%.flow.yaml}"
  base="${base%.yaml}"
  # Keep everything up to and including the LAST "-<number>" group (the issue
  # number), dropping any trailing "-description". Preserves composite project
  # keys, e.g.  MY-APP-13-checkout  ->  MY-APP-13.
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
FLOWS=( $FLOW_GLOB )

if [ "${#FLOWS[@]}" -eq 0 ]; then
  echo "No Maestro flows matched '${FLOW_GLOB}'. Nothing to verify."
  exit 0
fi

# Build the optional `-e key=value` args from MAESTRO_ENV (comma-separated).
ENV_ARGS=()
if [ -n "$MAESTRO_ENV" ]; then
  IFS=',' read -ra PAIRS <<< "$MAESTRO_ENV"
  for pair in "${PAIRS[@]}"; do
    ENV_ARGS+=( "-e" "$pair" )
  done
fi

OVERALL_RC=0
for flow in "${FLOWS[@]}"; do
  key="$BUG_KEY"
  if [ -z "$key" ]; then
    key="$(derive_bug_key "$flow")"
  fi

  echo "=== Running Maestro repro: ${flow} (bug ${key}) ==="
  # `maestro test` exits non-zero if any assertion in the flow fails, which is
  # exactly the pass/fail signal the CI webhook wants. The BugMojo-generated flow
  # ends with the fixed post-condition assertion (assertVisible / assertNotVisible),
  # so a green run means the bug is fixed on this build.
  if maestro test "${ENV_ARGS[@]}" "$flow"; then
    report_result "$key" "true" "$PROOF_URL"
  else
    OVERALL_RC=1
    report_result "$key" "false" "$PROOF_URL"
  fi
done

# Exit non-zero if any repro failed, so the CI job status also reflects reality.
exit "$OVERALL_RC"
