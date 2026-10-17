import { defineConfig, devices } from '@playwright/test';

// ---------------------------------------------------------------------------
// Playwright config used by the BugMojo Verify action to run repro specs against
// a DEPLOYED build. BugMojo's compiled repros use `baseURL`-relative navigation
// (page.goto('/path')), so the deployed URL is wired in here via env. The action
// points Playwright at this config with `--config`.
//
// You normally do NOT edit this — the action ships it. If you keep your own
// playwright.config.ts, ensure its `use.baseURL` reads BUGMOJO_DEPLOYED_URL the
// same way and run your specs with your config instead.
// ---------------------------------------------------------------------------

const baseURL = process.env.BUGMOJO_DEPLOYED_URL || process.env.DEPLOYED_URL;

if (!baseURL) {
  throw new Error('BUGMOJO_DEPLOYED_URL (deployed build URL) is not set');
}

export default defineConfig({
  testDir: process.env.BUGMOJO_SPEC_DIR || 'tests/bugmojo',
  fullyParallel: true,
  forbidOnly: true,
  retries: 0,
  reporter: 'line',
  timeout: 60_000,
  use: {
    baseURL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    headless: true,
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
