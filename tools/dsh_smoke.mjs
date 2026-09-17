/**
 * Drive the shipped DeepSeek Harness page in a headless browser and prove a
 * prompt reaches the model and comes back.
 *
 * This is the check that closes the gap between "the route is configured" and
 * "a person can type and get an answer". Curling the API cannot see the page
 * fail to boot, a modal block the composer, or the route arrive with the wrong
 * reasoning level; only driving the real page can.
 *
 * It is deliberately not part of `swift test`: it needs a running model, which
 * the unit tests must never require. `tools/dsh_local.sh smoke` is the entry
 * point -- it starts the harness, runs this, and stops it.
 *
 * Usage (usually via dsh_local.sh):
 *   node tools/dsh_smoke.mjs --url <tokenised-url> [--expect 42] [--timeout 300]
 *
 * Exit status is 0 only when the expected text appears in the page *after* the
 * prompt was sent. The prompt itself is on the page, so a naive text match finds
 * the echo; the expected string is therefore chosen so it cannot appear in the
 * prompt, and the baseline is compared against.
 */
import { chromium } from 'playwright';

function arg(name, fallback = null) {
  const index = process.argv.indexOf(`--${name}`);
  return index !== -1 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const url = arg('url');
const prompt = arg('prompt', 'What is 6 times 7? Reply with only the number.');
const expect = new RegExp(arg('expect', '\\b42\\b'));
const timeoutSeconds = Number(arg('timeout', '300'));
const shot = arg('shot', '');

if (!url) {
  console.error('dsh_smoke: --url is required (the tokenised URL `dsh web` prints)');
  process.exit(2);
}

const log = (message) => console.log(`dsh_smoke: ${message}`);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const browser = await chromium.launch();
const page = await browser.newPage();
let failure = null;

try {
  log(`loading ${url.split('?')[0]}`);
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  await sleep(5000);

  // The harness shows a one-time "Internal Testing Notice" modal that covers the
  // page and makes every click land on its mask. Dismiss it if it is there.
  const cont = page.getByRole('button', { name: /^continue$/i }).first();
  if (await cont.count()) {
    try {
      await cont.click({ timeout: 5000 });
      log('dismissed the onboarding notice');
      await sleep(1500);
    } catch {
      // Not blocking this run; the composer wait below reports it if it is.
    }
  }

  const composer = page.locator('div[contenteditable="true"]').first();
  try {
    await composer.waitFor({ state: 'visible', timeout: 20000 });
  } catch {
    throw new Error(
      'no composer appeared. The harness needs a workspace selected before it '
      + 'will accept a prompt; `tools/dsh_local.sh ensure` seeds one.');
  }

  const baseline = await page.evaluate(() => document.body.innerText);
  await composer.click();
  await composer.type(prompt, { delay: 8 });
  await sleep(400);

  const send = page.getByRole('button', { name: /^send message$/i }).first();
  if (!(await send.count()) || !(await send.isEnabled())) {
    throw new Error('the send button never became enabled — the composer has no workspace or model');
  }
  await send.click();
  log(`sent "${prompt}" at ${new Date().toISOString()}`);

  // Wait for the answer. The first token of an agentic turn can take a long
  // time: the harness sends a large system prompt with tools, and prefill on a
  // small model runs at tens of tokens a second, so minutes is normal and the
  // page shows "Deep diving..." while it works.
  const deadline = Date.now() + timeoutSeconds * 1000;
  let found = false;
  let sawRetry = false;
  while (Date.now() < deadline) {
    await sleep(3000);
    const text = await page.evaluate(() => document.body.innerText);
    if (expect.test(text) && !expect.test(baseline)) { found = true; break; }
    if (/Retrying model request/.test(text)) {
      if (!sawRetry) { sawRetry = true; log('the page reports retrying the model request'); }
    } else if (sawRetry) {
      sawRetry = false;
      log('the retry stopped');
    }
  }

  if (!found) {
    const text = await page.evaluate(() => document.body.innerText);
    throw new Error(
      `no answer matching ${expect} within ${timeoutSeconds}s. Page tail:\n`
      + text.replace(/\n{2,}/g, '\n').slice(-600));
  }
  log(`answer matching ${expect} appeared`);
} catch (error) {
  failure = error;
} finally {
  if (shot) {
    try { await page.screenshot({ path: shot }); log(`screenshot: ${shot}`); } catch { /* best effort */ }
  }
  await browser.close();
}

if (failure) {
  console.error(`dsh_smoke: FAILED: ${failure.message}`);
  process.exit(1);
}
console.log('dsh_smoke: PASSED');
