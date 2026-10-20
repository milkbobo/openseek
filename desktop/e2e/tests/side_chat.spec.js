import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

// A side chat is the record `<conversation>-sc-N`: shown in its
// conversation's dock with its own transcript and composer, never as a
// sidebar row, and never reaching into the column beside it.

const event = (sequence, kind, payload) => ({ sequence, item: { kind, payload } });
const mainHistory = [
  event(1, 'user', { content: 'Explain the parser.' }),
  event(2, 'terminal', { kind: 'finished', message: 'The parser reads tokens.' }),
];
const sideHistory = [
  ...mainHistory,
  event(3, 'user', { content: 'An aside about tokens.' }),
  event(4, 'terminal', { kind: 'finished', message: 'Tokens are lexemes.' }),
];

async function setup(page) {
  const app = new DesktopBrowserHarness(page);
  app.liveSessions.push({ id: 'session-1-sc-0a1b2c3d', title: 'Rabbita browser fixture', updated_at_ms: 2 });
  app.sessionEvents = mainHistory;
  const original = app.replyFor.bind(app);
  app.replyFor = request => {
    if (request.method === 'session.load' && request.params.session === 'session-1-sc-0a1b2c3d') {
      return {
        session: { version: 1, id: 'session-1-sc-0a1b2c3d', events: sideHistory },
        watermark: sideHistory.at(-1).sequence,
        prediction: null,
      };
    }
    return original(request);
  };
  await app.install();
  await app.goto();
  await page.getByText('Rabbita browser fixture', { exact: true }).first().click();
  await expect(page.locator('#transcript')).toContainText('The parser reads tokens.');
  return app;
}

test('a listed side chat is a dock tab beside its conversation, not a sidebar row', async ({ page }) => {
  const app = await setup(page);
  await expect(page.locator('.conversation-row')).toHaveCount(1);
  await page.getByRole('button', { name: 'Show panel', exact: true }).click();
  const tab = page.locator('.editor-tab', { hasText: 'Side chat 1' });
  await expect(tab).toBeVisible();
  await tab.click();
  const side = page.locator('#side-chat-transcript');
  await expect(side).toContainText('Tokens are lexemes.');
  // The column keeps its own conversation and its own scroller.
  await expect(page.locator('#transcript')).not.toContainText('Tokens are lexemes.');
  await expect(page.locator('#transcript')).toHaveCount(1);
  await expect(page.locator('#task')).toHaveCount(1);
  await expect(page.locator('.conversation-row')).toHaveCount(1);
  expect(app.pageErrors).toEqual([]);
});

test('the side chat composer sends to the side chat', async ({ page }) => {
  const app = await setup(page);
  await page.getByRole('button', { name: 'Show panel', exact: true }).click();
  await page.locator('.editor-tab', { hasText: 'Side chat 1' }).click();
  await expect(page.locator('#side-chat-transcript')).toContainText('Tokens are lexemes.');
  const input = page.locator('#side-chat-task');
  await input.fill('One more aside');
  await input.press('Enter');
  await expect.poll(() => app.requests.find(r => r.method === 'agent.start')?.params.session)
    .toBe('session-1-sc-0a1b2c3d');
  // The column's draft and conversation are untouched.
  await expect(page.locator('#task')).toHaveValue('');
  expect(app.pageErrors).toEqual([]);
});

test('a draft typed in the side chat survives hiding the dock', async ({ page }) => {
  const app = await setup(page);
  await page.getByRole('button', { name: 'Show panel', exact: true }).click();
  const tab = page.locator('.editor-tab', { hasText: 'Side chat 1' });
  await tab.click();
  const input = page.locator('#side-chat-task');
  await input.fill('A draft in progress');
  await page.getByRole('button', { name: 'Hide panel', exact: true }).click();
  await expect(input).toHaveCount(0);
  await page.getByRole('button', { name: 'Show panel', exact: true }).click();
  await expect(input).toHaveValue('A draft in progress');
  expect(app.pageErrors).toEqual([]);
});

// Opening one from a selection: the host forks the conversation as a side
// chat, and the page opens it in the dock with the selection quoted.
async function setupFork(page) {
  const app = new DesktopBrowserHarness(page);
  app.sessionEvents = mainHistory;
  const original = app.replyFor.bind(app);
  app.replyFor = request => {
    if (request.method === 'session.fork' && request.params.side_chat === true) {
      app.liveSessions.push({ id: 'session-1-sc-0a1b2c3d', title: request.params.source_title, updated_at_ms: 3 });
      return { session: 'session-1-sc-0a1b2c3d', title: request.params.source_title };
    }
    if (request.method === 'session.load' && request.params.session === 'session-1-sc-0a1b2c3d') {
      const events = mainHistory.filter(e => e.sequence <= 2);
      return { session: { version: 1, id: 'session-1-sc-0a1b2c3d', events }, watermark: 2, prediction: null };
    }
    return original(request);
  };
  await app.install();
  await app.goto();
  await page.getByText('Rabbita browser fixture', { exact: true }).first().click();
  await expect(page.locator('#transcript')).toContainText('The parser reads tokens.');
  return app;
}

async function selectIn(page, container, text) {
  const paragraph = page.locator(`${container} .msg-content`).getByText(text, { exact: true }).first();
  await paragraph.dblclick({ position: { x: 8, y: 8 } });
}

test('a selection opens a side chat beside the conversation with the selection quoted', async ({ page }) => {
  const app = await setupFork(page);
  await selectIn(page, '#transcript', 'The parser reads tokens.');
  const toolbar = page.getByRole('toolbar', { name: 'Selection actions' });
  await expect(toolbar.getByRole('button')).toHaveText(['Copy', 'Reply', 'Side chat']);
  await toolbar.getByRole('button', { name: 'Side chat', exact: true }).click();
  await expect.poll(() => app.requests.find(r => r.method === 'session.fork')?.params)
    .toMatchObject({ session: 'session-1', through: 2, side_chat: true });
  const tab = page.locator('.editor-tab', { hasText: 'Side chat 1' });
  await expect(tab).toBeVisible();
  await expect(page.locator('#side-chat-transcript')).toContainText('The parser reads tokens.');
  const input = page.locator('#side-chat-task');
  await expect(input).toHaveValue(/^> The\n\n$/);
  await expect(input).toBeFocused();
  // The column did not move, and the side chat has no sidebar row.
  await expect(page.locator('#transcript')).toContainText('The parser reads tokens.');
  await expect(page.locator('.conversation-row')).toHaveCount(1);
  // A selection inside the side chat replies there, and opens no other.
  await selectIn(page, '#side-chat-transcript', 'The parser reads tokens.');
  await expect(toolbar.getByRole('button')).toHaveText(['Copy', 'Reply']);
  await page.keyboard.press('Escape');
  // Closing the tab deletes the side chat.
  await tab.locator('.tab-close').click();
  await expect.poll(() => app.requests.find(r => r.method === 'session.delete')?.params.session)
    .toBe('session-1-sc-0a1b2c3d');
  await expect(tab).toHaveCount(0);
  await expect(page.locator('#side-chat-transcript')).toHaveCount(0);
  expect(app.pageErrors).toEqual([]);
});
