import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

test('selected transcript text can be quoted in a floating reply', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  const filler = Array.from({ length: 40 }, (_, index) => `Filler paragraph ${index + 1}.`);
  app.sessionEvents = [
    {
      sequence: 1,
      item: { kind: 'user', payload: { content: 'Show the browser fixture quote reply' } },
    },
    {
      sequence: 2,
      item: {
        kind: 'assistant',
        payload: {
          content: [...filler, 'First answer paragraph.', 'Second answer paragraph.']
            .join('\n\n'),
        },
      },
    },
  ];
  await app.install();
  await app.goto();
  await app.openSession();

  const transcript = page.locator('#transcript');
  const markdown = page.locator('.transcript .msg-content.markdown');
  const first = markdown.getByText('First answer paragraph.');
  const second = markdown.getByText('Second answer paragraph.');
  const bar = page.getByRole('toolbar', { name: 'Selection actions' });
  const reply = page.getByRole('dialog', { name: 'Reply to selection' });
  const comment = reply.getByRole('textbox', { name: 'Reply' });
  const batch = reply.getByRole('checkbox', { name: 'Batch' });
  const task = page.locator('#task');
  const pinned = () => page.evaluate(() => CSS.highlights.has('quote-reply'));
  const selectWord = paragraph => paragraph.dblclick({ position: { x: 8, y: 8 } });
  const openReply = async paragraph => {
    await selectWord(paragraph);
    await bar.getByRole('button', { name: 'Reply' }).click();
    await expect(comment).toBeFocused();
  };
  const scrollTranscript = async delta => {
    const box = await transcript.boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + 40);
    await page.mouse.wheel(0, delta);
  };

  // Selecting text offers Reply just above it; Reply opens a composer that
  // keeps the quote in view and painted while the comment is typed.
  await selectWord(first);
  await expect(bar.getByRole('button')).toHaveText(['Copy', 'Reply']);
  const barBox = await bar.boundingBox();
  const firstBox = await first.boundingBox();
  expect(barBox.y + barBox.height).toBeLessThanOrEqual(firstBox.y);
  await bar.getByRole('button', { name: 'Reply' }).click();
  await expect(reply.locator('blockquote')).toHaveText('First');
  await expect(comment).toBeFocused();
  expect(await pinned()).toBe(true);
  await expect(reply.getByRole('button', { name: 'Send reply' })).toBeDisabled();

  // Batched, the reply joins the message being written, which is where the
  // reader lands; nothing is sent.
  await batch.check();
  await expect(comment).toBeFocused();
  await expect(reply.getByRole('button', { name: 'Add to message' })).toBeEnabled();
  await page.keyboard.type('Why first?');
  await page.keyboard.press('Enter');
  await expect(reply).toHaveCount(0);
  await expect(task).toHaveValue('> First\n\nWhy first?\n\n');
  await expect(task).toBeFocused();
  expect(await pinned()).toBe(false);
  expect(app.requests.some(request => request.method === 'agent.start')).toBe(false);

  // An offer follows its selection: it goes on Escape, when the selection
  // goes, and when a scroll moves the text from under it.
  await selectWord(first);
  await expect(bar).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(bar).toHaveCount(0);
  await selectWord(first);
  await expect(bar).toBeVisible();
  await page.evaluate(() => document.getSelection().removeAllRanges());
  await expect(bar).toHaveCount(0);
  await selectWord(first);
  await expect(bar).toBeVisible();
  await scrollTranscript(-60);
  await expect(bar).toHaveCount(0);
  await scrollTranscript(60);

  // A reply being typed survives a scroll, and closes on Escape or a press
  // elsewhere.
  await openReply(first);
  await page.keyboard.type('Keep me');
  await scrollTranscript(-60);
  await expect(comment).toHaveValue('Keep me');
  await scrollTranscript(60);
  await page.keyboard.press('Escape');
  await expect(reply).toHaveCount(0);
  await openReply(first);
  await page.locator('.topbar-title').click();
  await expect(reply).toHaveCount(0);
  await expect(task).toHaveValue('> First\n\nWhy first?\n\n');

  // Text selected outside the transcript gets no offer, and neither does a
  // transcript selection left from earlier when the mouse is pressed and
  // released somewhere else.
  const press = (locator, selected) => locator.evaluate((element, selected) => {
    const event = type => new MouseEvent(type, { bubbles: true, button: 0 });
    element.dispatchEvent(event('mousedown'));
    const range = document.createRange();
    range.selectNodeContents(selected ?? element);
    const selection = document.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    element.dispatchEvent(event('mouseup'));
  }, selected);
  const settled = () => page.evaluate(() => new Promise(resolve => {
    setTimeout(() => requestAnimationFrame(() => requestAnimationFrame(resolve)), 0);
  }));
  const title = page.locator('.topbar-title');
  await press(title);
  await settled();
  await expect(bar).toHaveCount(0);
  await press(title, await first.elementHandle());
  await settled();
  await expect(bar).toHaveCount(0);
  await press(first);
  await expect(bar).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(bar).toHaveCount(0);

  // Escape meant for another overlay leaves the reply and its text alone.
  await openReply(first);
  await page.keyboard.type('Still here');
  await page.keyboard.press(await page.evaluate(() =>
    navigator.platform.includes('Mac') ? 'Meta+KeyP' : 'Control+KeyP'));
  const quickOpen = page.getByRole('dialog', { name: 'Search workspace files' });
  await expect(quickOpen).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(quickOpen).toHaveCount(0);
  await expect(comment).toHaveValue('Still here');
  await comment.focus();
  await page.keyboard.press('Escape');
  await expect(reply).toHaveCount(0);

  // A composer holding a shell command is not editing a message: it declines
  // the reply, which says so and keeps what was typed until it is taken.
  const batched = '> First\n\nWhy first?\n\n';
  await task.fill('!echo hello');
  await expect(page.locator('.composer-mode-chip')).toBeVisible();
  await openReply(first);
  await page.keyboard.type('Not a command');
  await page.keyboard.press('Enter');
  await expect(reply.getByRole('status')).toHaveText(
    "The message box can't take a reply right now.");
  await expect(comment).toHaveValue('Not a command');
  await expect(task).toHaveValue('!echo hello');
  expect(app.requests.some(request => request.method === 'terminal.open')).toBe(false);
  await task.fill(batched);
  await comment.focus();
  await page.keyboard.press('Enter');
  await expect(reply).toHaveCount(0);
  await expect(task).toHaveValue(`${batched}> First\n\nNot a command\n\n`);
  await task.fill(batched);

  // A reply belongs to the conversation it quotes: leaving that conversation
  // from the keyboard takes the reply off screen instead of retargeting it.
  await openReply(second);
  await page.keyboard.type('Wrong place');
  await page.keyboard.press(await page.evaluate(() =>
    navigator.platform.includes('Mac') ? 'Meta+KeyN' : 'Control+KeyN'));
  await expect(page.locator('.empty-title')).toBeVisible();
  await expect(reply).toHaveCount(0);
  await expect(task).toHaveValue('');
  await page.getByText('Rabbita browser fixture', { exact: true }).first().click();
  await expect(second).toBeVisible();
  await expect(reply).toHaveCount(0);
  await expect(task).toHaveValue('> First\n\nWhy first?\n\n');

  // Unbatched, the reply is sent at once with what was already batched.
  await openReply(second);
  await expect(batch).toBeChecked();
  await batch.uncheck();
  await expect(comment).toBeFocused();
  await page.keyboard.type('And this?');
  await page.keyboard.press('Enter');
  await expect(reply).toHaveCount(0);
  await expect.poll(() => app.requests.find(request =>
    request.method === 'agent.start')?.params.task)
    .toBe('> First\n\nWhy first?\n\n> Second\n\nAnd this?');
  await expect(task).toHaveValue('');
  expect(app.pageErrors).toEqual([]);
});

test('a floating reply takes a comment of several lines', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  const filler = Array.from({ length: 40 }, (_, index) => `Filler paragraph ${index + 1}.`);
  app.sessionEvents = [
    {
      sequence: 1,
      item: { kind: 'user', payload: { content: 'Show the browser fixture quote reply' } },
    },
    {
      sequence: 2,
      item: {
        kind: 'assistant',
        payload: { content: [...filler, 'First answer paragraph.'].join('\n\n') },
      },
    },
  ];
  await app.install();
  await app.goto();
  await app.openSession();

  const markdown = page.locator('.transcript .msg-content.markdown');
  const reply = page.getByRole('dialog', { name: 'Reply to selection' });
  const comment = reply.getByRole('textbox', { name: 'Reply' });
  const task = page.locator('#task');
  const height = async locator => (await locator.boundingBox()).height;
  const openReply = async paragraph => {
    await paragraph.dblclick({ position: { x: 8, y: 8 } });
    await page.getByRole('toolbar', { name: 'Selection actions' })
      .getByRole('button', { name: 'Reply' }).click();
    await expect(comment).toBeFocused();
  };
  const scrolls = () => comment.evaluate(input => input.scrollHeight > input.clientHeight);
  const bottom = async () => {
    const box = await reply.boundingBox();
    return box.y + box.height;
  };
  const lines = 'Line one\nLine two\nLine three\nLine four';
  const long = Array.from({ length: 40 }, (_, index) => `Row ${index + 1}`).join('\n');

  await openReply(markdown.getByText('First answer paragraph.'));
  await reply.getByRole('checkbox', { name: 'Batch' }).check();
  await expect(comment).toBeFocused();

  // Shift+Enter starts a new line and the input grows to show it, upwards:
  // the row being typed in stays where it is.
  await page.keyboard.type('Line one');
  const oneLine = await height(comment);
  const anchored = await bottom();
  await page.keyboard.press('Shift+Enter');
  await page.keyboard.type('Line two');
  await expect(comment).toHaveValue('Line one\nLine two');
  await expect.poll(() => height(comment)).toBeGreaterThan(oneLine * 1.5);
  expect(await bottom()).toBeCloseTo(anchored, 0);

  // Text put in whole, as a paste is, keeps its line breaks.
  await page.keyboard.insertText('\nLine three\nLine four');
  await expect(comment).toHaveValue(lines);

  // The input stops growing at a few lines and scrolls from there.
  await comment.fill(long);
  await expect.poll(scrolls).toBe(true);
  expect(await bottom()).toBeCloseTo(anchored, 0);
  await comment.fill(lines);
  await expect.poll(scrolls).toBe(false);

  // Enter still delivers, with the lines intact.
  await page.keyboard.press('Enter');
  await expect(reply).toHaveCount(0);
  await expect(task).toHaveValue(`> First\n\n${lines}\n\n`);

  // Near the top of the viewport there is less room to grow into: the input
  // gives way sooner rather than push the reply off screen.
  const near = markdown.getByText('Filler paragraph 20.', { exact: true });
  await near.evaluate(element => {
    document.querySelector('#transcript').scrollTop +=
      element.getBoundingClientRect().top - 170;
  });
  await page.evaluate(() => new Promise(resolve => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  }));
  await openReply(near);
  const anchoredNear = await bottom();
  await comment.fill(long);
  await expect.poll(scrolls).toBe(true);
  expect((await reply.boundingBox()).y).toBeGreaterThanOrEqual(0);
  expect(await bottom()).toBeCloseTo(anchoredNear, 0);
  expect(app.pageErrors).toEqual([]);
});
