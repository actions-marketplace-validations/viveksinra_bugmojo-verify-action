# BugMojo Verify — Mobile (Maestro)

Close the **verified loop** for **React Native / Expo** bugs. This is the mobile
half of [BugMojo Verify](./README.md); it runs a mobile bug's own PR'd
**Maestro flow** against a built app on an emulator/simulator and reports the
result back to BugMojo over the **exact same** CI webhook contract as web.

> **One loop, both platforms — not a fork.** Mobile results POST to the identical
> `POST /api/webhooks/ci` endpoint with the identical body
> (`{ bug_key, passed, proof_url }`). The BugMojo state machine
> (`DEV_TESTING → VERIFIED_FIXED` on pass, `→ REOPENED` on fail) is shared. The
> only thing that differs is the runner: **Maestro against a native build**
> instead of **Playwright against a deployed URL**.

---

## How the mobile loop works

```
PR with the Maestro repro merges
        │
        ▼
mobile bug -> DEV_TESTING  (fixed-pending-verification)
        │
        │  your mobile build finishes  ──►  BugMojo deploy webhook materializes a
        │                                   CI regression run (status = AWAITING_CI)
        ▼
this action runs .maestro/bugmojo/<BUG-KEY>.flow.yaml on an emulator/simulator
        │
        ├── pass ──►  POST /api/webhooks/ci { passed: true }  ──►  VERIFIED_FIXED
        └── fail ──►  POST /api/webhooks/ci { passed: false } ──►  REOPENED
```

Only the bug's **own** repro can verify it, and only while it is in
`DEV_TESTING` — identical to web. The CI webhook does not care whether the run
was Playwright or Maestro; it authenticates the secret in constant time and
transitions the bug from the reported `passed` boolean.

---

## Setup (3 steps)

### 1. Commit your Maestro flows

Export each mobile bug's repro from BugMojo (the `get_repro_pack` MCP tool
returns a `flow` for a `platform: "mobile"` bug, or use the bug's "Download
repro" button) and commit it under `.maestro/bugmojo/`. **Name the file for the
bug** so the action can map results back:

```
.maestro/bugmojo/MOB-42.flow.yaml            # verifies bug MOB-42
.maestro/bugmojo/MOB-42-checkout.flow.yaml   # also maps to MOB-42 (prefix before 2nd dash)
.maestro/bugmojo/RN-7.flow.yaml              # verifies bug RN-7
```

The flows are standard [Maestro](https://maestro.mobile.dev) YAML files. Each
BugMojo-generated flow starts with `launchApp`, replays the tester's action
timeline (`tapOn`, `inputText`, `scroll`, ...), and ends with the **fixed
post-condition assertion** (`assertVisible` / `assertNotVisible`). A green
`maestro test` run therefore means the bug is fixed on this build.

The generated flow's `appId:` header is the app under test. If you templatize it
(e.g. `appId: ${APP_ID}`), pass `maestro-env: 'APP_ID=com.acme.app'`.

### 2. Add the CI webhook secret

Same secret as the web action — you configure it once. In your GitHub repo:
**Settings → Secrets and variables → Actions → New repository secret**:

| Secret name                 | Value                                                    |
| --------------------------- | -------------------------------------------------------- |
| `BUGMOJO_CI_WEBHOOK_SECRET` | The CI webhook secret from your BugMojo project settings. |

### 3. Add the workflow

The mobile action is `viveksinra/bugmojo-verify-action/mobile@v1`. Copy [`examples/bugmojo-verify-mobile.yml`](./examples/bugmojo-verify-mobile.yml)
into your repo at `.github/workflows/bugmojo-verify-mobile.yml` and adjust:

- the trigger (fire **after** your mobile build completes),
- the **build + install** step (produce an APK / app and `adb install` it, or
  install on the iOS Simulator),
- `bugmojo-url` (your BugMojo instance),
- `maestro-env` (your app id / any deep links the flow references).

> A **real device/emulator/simulator is required**. Unlike web, there is no
> "deployed URL" — Maestro drives a native build. The example uses
> [`reactivecircus/android-emulator-runner`](https://github.com/ReactiveCircus/android-emulator-runner)
> to boot a headless Android emulator on the runner; for iOS use a `macos-latest`
> runner and `xcrun simctl`. A hosted device-farm shard (e.g. Maestro Cloud) is a
> drop-in alternative — point the `script` at `maestro cloud` instead.

---

## Inputs

| Input               | Required | Default                              | Description                                                           |
| ------------------- | -------- | ------------------------------------ | --------------------------------------------------------------------- |
| `ci-webhook-secret` | yes      | —                                    | `${{ secrets.BUGMOJO_CI_WEBHOOK_SECRET }}`. Never inline.             |
| `bugmojo-url`       | no       | `https://www.bugmojo.com`            | Your BugMojo instance base URL.                                       |
| `bug-key`           | no       | *(derived from file name)*           | Force a single bug key for all flows (e.g. `MOB-42`).                 |
| `flow-glob`         | no       | `.maestro/bugmojo/**/*.flow.yaml`    | Which Maestro flows to run.                                           |
| `maestro-env`       | no       | *(none)*                             | `key=value,key=value` forwarded to `maestro test -e`.                |
| `working-directory` | no       | `.`                                  | Where `.maestro/bugmojo` lives.                                       |

---

## What it POSTs

For each flow (or once, if you set `bug-key`) the action calls the **same
endpoint the web action does**:

```
POST {bugmojo-url}/api/webhooks/ci
Headers:  X-CI-Secret: <BUGMOJO_CI_WEBHOOK_SECRET>
          Content-Type: application/json
Body:     { "bug_key": "MOB-42", "passed": true, "proof_url": "<link to this CI run>" }
```

Because the contract is shared, **no BugMojo server changes are needed for
mobile** — the webhook route, the verified-loop state machine, and the
`RegressionRun` closeout are all reused as-is.

---

## Local dry run

```bash
BUGMOJO_URL=https://www.bugmojo.com \
CI_WEBHOOK_SECRET=*** \
MAESTRO_ENV=APP_ID=com.acme.app \
bash scripts/run-maestro-and-report.sh
```

(An emulator/simulator with your app installed must be running for `maestro test`
to succeed.)

---

## Files

| File                                    | Purpose                                                          |
| --------------------------------------- | ---------------------------------------------------------------- |
| `mobile/action.yml`                     | Composite action definition (installs Maestro, runs flows).      |
| `scripts/run-maestro-and-report.sh`     | Runs each flow and curls the result to `/api/webhooks/ci`.       |
| `examples/bugmojo-verify-mobile.yml`    | Drop-in workflow you copy into your repo.                        |
