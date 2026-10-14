import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

test('transcript overview previews failed turns and jumps among mounted messages', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  const events = [
    {
      sequence: 1,
      ts: 1_781_144_351_123,
      item: {
        kind: 'user',
        payload: { content: 'Show the browser fixture: first question' },
      },
    },
    {
      sequence: 2,
      ts: 1_781_144_352_123,
      item: {
        kind: 'assistant',
        payload: {
          content: 'First answer recovered after the tool failed.',
          tool_calls: [{ id: 'failed-after-answer', name: 'shell', arguments: '{}' }],
        },
      },
    },
    {
      sequence: 3,
      ts: 1_781_144_353_123,
      item: {
        kind: 'tool_result',
        payload: {
          tool_call_id: 'failed-after-answer',
          tool_name: 'shell',
          content: 'fixture failure',
          is_error: true,
          brief: 'failed after answer',
        },
      },
    },
  ];
  let sequence = 4;
  for (let turn = 2; turn <= 100; turn += 1) {
    events.push({
      sequence,
      ts: 1_781_144_350_123 + sequence * 1_000,
      item: {
        kind: 'user',
        payload: { content: `Question ${turn} keeps the overview rail scrollable` },
      },
    });
    sequence += 1;
    events.push({
      sequence,
      ts: 1_781_144_350_123 + sequence * 1_000,
      item: {
        kind: 'assistant',
        payload: { content: `Answer ${turn}` },
      },
    });
    sequence += 1;
  }
  app.sessionEvents = events;
  await app.install();
  await app.goto();
  await app.openSession();

  const overview = page.getByRole('navigation', { name: 'Conversation overview' });
  const ticks = overview.locator('.overview-tick-button');
  const failed = ticks.first();
  await expect(failed).toBeVisible();
  await expect(failed).toHaveAccessibleName(
    'Show the browser fixture: first question (had errors)',
  );
  await failed.hover();
  const preview = overview.getByRole('tooltip');
  await expect(preview.locator('.overview-preview-prompt')).toContainText('first question');
  await expect(preview.locator('.overview-preview-reply')).toContainText('First answer');
  await expect(preview.locator('.overview-preview-failed')).toHaveText('had errors');
  const transcript = page.locator('#transcript');
  const scrollTopBeforeJump = await transcript.evaluate(node => node.scrollTop);
  await failed.click();
  await expect.poll(() => transcript.evaluate(node => node.scrollTop))
    .toBeLessThan(scrollTopBeforeJump);

  await overview.dispatchEvent('mouseleave');
  await expect(overview.getByRole('tooltip')).toHaveCount(0);
  expect(app.pageErrors).toEqual([]);
});

test('tool-call tabs keep focus-driven scrolling inside the transcript', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openseek.minimal_transcript', 'false'));
  const app = new DesktopBrowserHarness(page);
  const events = [
    {
      sequence: 1,
      item: {
        kind: 'user',
        payload: { content: 'Show the browser fixture with a long transcript' },
      },
    },
  ];
  let sequence = 2;
  for (let row = 1; row <= 100; row += 1) {
    events.push({
      sequence,
      item: {
        kind: 'assistant',
        payload: { content: `Transcript filler row ${row}` },
      },
    });
    sequence += 1;
  }
  events.push({
    sequence,
    item: {
      kind: 'assistant',
      payload: {
        content: '',
        tool_calls: [
          {
            id: 'deep-tabbed-call',
            name: 'mbtx',
            arguments: JSON.stringify({
              source: 'fn main { println("browser fixture") }',
              description: 'Print <browser> fixture',
            }),
          },
        ],
      },
    },
  });
  app.sessionEvents = events;
  await app.install();
  await app.goto();
  // Proton's current CEF does not use the size container as the absolute
  // positioning root. Neutralize Chromium's newer behavior so this browser
  // test exercises the same geometry as the shipping desktop host.
  await page.addStyleTag({ content: '#transcript { container-type: normal; }' });
  await app.openSession();

  const transcript = page.locator('#transcript');
  await expect(transcript.locator('.tool-call-summary')).toContainText('Print <browser> fixture');
  const tabs = transcript.locator('.tool-call-tabs');
  const originalJson = tabs.getByText('Original JSON', { exact: true });
  await transcript.locator('.tool-call-summary').click();
  // Revealing a contained row must not scroll the fixed shell either; the
  // document can remain at zero while #app shifts its entire grid by 1–2px.
  expect(await page.locator('#app').evaluate(node =>
    ({ top: node.scrollTop, left: node.scrollLeft }))).toEqual({ top: 0, left: 0 });
  await transcript.evaluate(node => {
    node.scrollTop = node.scrollHeight;
  });
  await expect(originalJson).toBeVisible();
  expect(await transcript.evaluate(node => node.scrollTop)).toBeGreaterThan(0);
  expect(await page.evaluate(() => document.scrollingElement.scrollTop)).toBe(0);

  await originalJson.click();

  const originalJsonInput = tabs.locator('.tool-call-tab-input').nth(1);
  await expect(originalJsonInput).toBeChecked();
  await originalJsonInput.focus();
  await expect(originalJsonInput).toBeFocused();
  expect(await transcript.evaluate(node => getComputedStyle(node).position))
    .toBe('relative');
  expect(await originalJsonInput.evaluate(node =>
    Boolean(node.offsetParent?.closest('#transcript')))).toBe(true);
  expect(await page.evaluate(() => document.scrollingElement.scrollTop)).toBe(0);
  expect(await page.locator('.app').evaluate(node =>
    node.getBoundingClientRect().top)).toBe(0);
  expect(await page.locator('#app').evaluate(node =>
    ({ top: node.scrollTop, left: node.scrollLeft }))).toEqual({ top: 0, left: 0 });
  expect(app.pageErrors).toEqual([]);
});
