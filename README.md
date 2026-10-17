# BugMojo Verify — GitHub Action

Close the **verified loop**: run a bug's own PR'd repro test against your
deployed build and report the result back to BugMojo. A passing repro promotes
the bug from **DEV_TESTING** (fixed-pending-verification) to **VERIFIED_FIXED**;
a failing repro **REOPENS** it.

> There is **no BugMojo-hosted browser runner** in v1 — by design. *Your* CI runs
> the repro on *your* infrastructure against *your* deployed build, and POSTs the
> outcome to BugMojo. This action is that reporter.

---

## How the loop works

```
PR with the repro merges
        │
        ▼
bug -> DEV_TESTING  (fixed-pending-verification)
        │
        │  your deploy finishes  ──►  BugMojo deploy webhook materializes a
        │                             CI regression run (status = AWAITING_CI)
        ▼
this action runs tests/bugmojo/<BUG-KEY>.spec.ts against the deployed URL
        │
        ├── pass ──►  POST /api/webhooks/ci { passed: true }  ──►  VERIFIED_FIXED
        └── fail ──►  POST /api/webhooks/ci { passed: false } ──►  REOPENED
```

Only the bug's **own** repro can verify it, and only while it is in
`DEV_TESTING`. A stray or duplicate CI callback never yanks a bug out of an
unrelated state.

---

## Setup (3 steps)

### 1. Commit your repro specs

Export each bug's repro from BugMojo (the `get_repro_pack` MCP tool / the bug's
"Download repro" button) and commit it under `tests/bugmojo/`. **Name the file
for the bug** so the action can map results back:

```
tests/bugmojo/WEB-42.spec.ts            # verifies bug WEB-42
tests/bugmojo/WEB-42-checkout.spec.ts   # also maps to WEB-42 (prefix before 2nd dash)
tests/bugmojo/API-7.spec.ts             # verifies bug API-7
```

The specs are standard `@playwright/test` files that navigate with
`baseURL`-relative `page.goto('/path')`, so they run against whatever build you
point them at.

### 2. Add the CI webhook secret

In your GitHub repo: **Settings → Secrets and variables → Actions → New
repository secret**:

| Secret name                 | Value                                                        |
| --------------------------- | ------------------------------------------------------------ |
| `BUGMOJO_CI_WEBHOOK_SECRET` | The CI webhook secret from your BugMojo project settings.     |

In BugMojo, this is the `ci_webhook_secret` on your project's **WEBHOOK**
integration. If you already configured a **deploy hook secret**, you can reuse
it — the CI webhook accepts either.

> **Placeholder** — you must supply real values for `CI_WEBHOOK_SECRET` and your
> BugMojo app URL. Never inline the secret in YAML; always reference
> `${{ secrets.BUGMOJO_CI_WEBHOOK_SECRET }}`.

### 3. Add the workflow

```yaml
- uses: actions/checkout@v4
- uses: viveksinra/bugmojo-verify-action@v1
  with:
    deployed-url: https://staging.example.com
    ci-webhook-secret: ${{ secrets.BUGMOJO_CI_WEBHOOK_SECRET }}
```

Or copy [`examples/bugmojo-verify.yml`](./examples/bugmojo-verify.yml) into your
repo at `.github/workflows/bugmojo-verify.yml` and adjust:

- the trigger (fire **after** your deploy completes),
- `deployed-url` (the build to test),
- `bugmojo-url` (your BugMojo instance).

---

## Inputs

| Input               | Required | Default                          | Description                                                              |
| ------------------- | -------- | -------------------------------- | ------------------------------------------------------------------------ |
| `deployed-url`      | yes      | —                                | Base URL of the deployed build to test.                                  |
| `ci-webhook-secret` | yes      | —                                | `${{ secrets.BUGMOJO_CI_WEBHOOK_SECRET }}`. Never inline.                 |
| `bugmojo-url`       | no       | `https://www.bugmojo.com`        | Your BugMojo instance base URL.                                          |
| `bug-key`           | no       | *(derived from file name)*       | Force a single bug key for all specs (e.g. `WEB-42`).                     |
| `spec-glob`         | no       | `tests/bugmojo/**/*.spec.ts`     | Which repro specs to run.                                                 |
| `working-directory` | no       | `.`                              | Where `package.json` / `tests/bugmojo` live.                             |

---

## What it POSTs

For each spec (or once, if you set `bug-key`) the action calls:

```
POST {bugmojo-url}/api/webhooks/ci
Headers:  X-CI-Secret: <BUGMOJO_CI_WEBHOOK_SECRET>
          Content-Type: application/json
Body:     { "bug_key": "WEB-42", "passed": true, "proof_url": "<link to this CI run>" }
```

BugMojo authenticates the secret in **constant time** and, only when the bug is
still `DEV_TESTING` and it is the bug's own repro, transitions it. The action's
job exit code also reflects reality (non-zero if any repro failed).

---

## Local dry run

```bash
DEPLOYED_URL=https://staging.example.com \
BUGMOJO_URL=https://www.bugmojo.com \
CI_WEBHOOK_SECRET=*** \
BUGMOJO_ACTION_PATH="$(pwd)" \
bash scripts/run-and-report.sh
```

---

## Files

| File                             | Purpose                                                      |
| -------------------------------- | ----------------------------------------------------------- |
| `action.yml`                     | Composite action definition (inputs + steps).               |
| `scripts/run-and-report.sh`      | Runs each repro and curls the result to `/api/webhooks/ci`.  |
| `playwright.bugmojo.config.ts`   | Playwright config wiring `baseURL` to the deployed URL.      |
| `examples/bugmojo-verify.yml`    | Drop-in workflow you copy into your repo.                    |
