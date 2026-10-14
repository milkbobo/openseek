import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

test('runtime notices keep the compact result-row presentation', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openseek.minimal_transcript', 'false'));
  const app = new DesktopBrowserHarness(page);
  app.sessionEvents = [
    {
      sequence: 1,
      item: {
        kind: 'user',
        payload: { content: 'Show the browser fixture runtime notice' },
      },
    },
    {
      sequence: 2,
      item: {
        kind: 'runtime_notice',
        payload: {
          content: 'background job bg-1 finished (exit=0): `moon test`',
        },
      },
    },
  ];
  await app.install();
  await app.goto();
  await app.openSession();

  // The caption is the engine-notice glyph; the notice's own text stays in
  // the row's body.
  const notice = page.locator('.activity-row', { hasText: '🔔' });
  const result = notice.locator('details.tool-result');
  await expect(notice.locator('.summary-card')).toHaveCount(0);
  await expect(result.locator('.tool-result-text')).toHaveText('🔔');
  await expect(result).not.toHaveAttribute('open', '');
  await result.locator('.tool-result-summary').click();
  await expect(result).toContainText('background job bg-1 finished (exit=0)');
  expect(app.pageErrors).toEqual([]);
});

test('a model step shows its thought, then its prose, then its tool rows', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openseek.minimal_transcript', 'false'));
  const app = new DesktopBrowserHarness(page);
  app.sessionEvents = [
    {
      sequence: 1,
      item: {
        kind: 'user',
        payload: { content: 'Show the browser fixture model step' },
      },
    },
    {
      sequence: 2,
      item: {
        kind: 'assistant',
        payload: {
          content: 'I will inspect the project.',
          reasoning_content: 'first thought',
          tool_calls: [{ id: 'c1', name: 'read', arguments: '{"path":"moon.mod"}' }],
        },
      },
    },
    {
      sequence: 3,
      item: {
        kind: 'tool_result',
        payload: {
          tool_call_id: 'c1',
          tool_name: 'read',
          content: 'module contents',
          is_error: false,
          brief: 'read moon.mod',
        },
      },
    },
  ];
  await app.install();
  await app.goto();
  await app.openSession();

  // One durable response is one step, whose parts keep the model's order:
  // the thought it had, the prose it said, then the calls that prose announced.
  const step = page.locator('.step');
  await expect(step).toHaveCount(1);
  await expect(step.locator(':scope > *')).toHaveClass(['activity-row', 'msg', 'activity-row']);
  await expect(step.locator('.activity-row').first().locator('.activity-text')).toHaveText('#1 · Thought');
  await expect(step.locator('.msg .msg-content.markdown')).toContainText('I will inspect the project.');
  await expect(step.locator('.activity-row').last().locator('.tool-call-text')).toHaveText('read moon.mod');
  expect(app.pageErrors).toEqual([]);
});

test('transcript Markdown keeps links safe and loads local raster bytes through the host', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await page.context().route('https://example.test/docs', route => route.fulfill({
    contentType: 'text/html', body: '<title>External docs</title>',
  }));
  app.binaryFiles['diagram.png'] = {
    data_base64: 'iVBORw0KGgo=',
    media_type: 'image/png',
  };
  app.sessionEvents = [
    {
      sequence: 1,
      item: {
        kind: 'user',
        payload: { content: 'Show the browser fixture Markdown policy' },
      },
    },
    {
      sequence: 2,
      item: {
        kind: 'assistant',
        payload: {
          content: [
            '[External docs](https://example.test/docs)',
            '[Source](src/main.mbt:12)',
            '[Local URI](file:///Users/me/My%20Project/main.mbt#L7)',
            '[Bundled guide](/Users/me/Library/Application%20Support/SeekMoon/gmachine-3.md)',
            '[Unsafe](javascript:alert(1))',
            '![Fixture image](diagram.png)',
            '![Repeated image](diagram.png)',
            '![Unavailable image](missing-image.png)',
          ].join('\n\n'),
        },
      },
    },
  ];
  await app.install();
  await app.goto();
  await app.openSession();

  const markdown = page.locator('.transcript .msg-content.markdown');
  await expect(markdown.locator('a[href^="javascript:"]')).toHaveCount(0);
  await expect(markdown.getByText('Unsafe', { exact: true })).toBeVisible();

  const image = markdown.locator('img[alt="Fixture image"]');
  await expect.poll(() => app.requests.find(request =>
    request.method === 'fs.read_file' && request.params?.path === 'diagram.png'))
    .toMatchObject({ params: { root: '/workspace' } });
  await expect(image).toHaveAttribute('src', 'data:image/png;base64,iVBORw0KGgo=');
  await expect(markdown.locator('img[alt="Repeated image"]'))
    .toHaveAttribute('src', 'data:image/png;base64,iVBORw0KGgo=');
  await expect(markdown.locator('img[alt="Unavailable image"]')).toHaveClass(/unavailable/);
  await expect(markdown.locator('img[data-transcript-image]')).toHaveCount(0);
  expect(app.requests.filter(request => request.method === 'fs.read_file' &&
    request.params?.path === 'diagram.png')).toHaveLength(1);


  const external = markdown.getByRole('link', { name: 'External docs' });
  await expect(external).toHaveAttribute('target', '_blank');
  await expect(external).toHaveAttribute('rel', 'noopener noreferrer');
  await external.focus();
  await external.evaluate(element => {
    element.dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: 0,
      clientY: 0,
    }));
  });
  let contextMenu = page.getByRole('menu', { name: 'Context menu' });
  await expect(contextMenu).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(external).toBeFocused();

  await external.click({ button: 'right' });
  contextMenu = page.getByRole('menu', { name: 'Context menu' });
  await expect(contextMenu.getByRole('menuitem')).toHaveText([
    'Open in New Tab',
    'Copy Link',
  ]);
  const popupPromise = page.waitForEvent('popup');
  const navigationPromise = page.context().waitForEvent('request', {
    predicate: request => request.url() === 'https://example.test/docs',
  });
  await contextMenu.getByRole('menuitem', { name: 'Open in New Tab' }).click();
  const popup = await popupPromise;
  await navigationPromise;
  await popup.close();

  const source = markdown.getByTitle('Open src/main.mbt:12');
  await source.click({ button: 'right' });
  contextMenu = page.getByRole('menu', { name: 'Context menu' });
  await expect(contextMenu.getByRole('menuitem')).toHaveText([
    'Open',
    'Copy Path',
  ]);
  await page.keyboard.press('Escape');

  const unsafe = markdown.getByText('Unsafe', { exact: true });
  await unsafe.evaluate(element => {
    const range = document.createRange();
    range.selectNodeContents(element);
    const selection = document.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    const rect = range.getBoundingClientRect();
    element.dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: rect.left + Math.max(1, rect.width / 2),
      clientY: rect.top + Math.max(1, rect.height / 2),
    }));
  });
  contextMenu = page.getByRole('menu', { name: 'Context menu' });
  await expect(contextMenu.getByRole('menuitem')).toHaveText(['Copy']);
  await page.keyboard.press('Escape');

  const ordinaryEventAllowed = await page.getByRole('main').evaluate(element => {
    document.getSelection()?.removeAllRanges();
    return element.dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true,
      cancelable: true,
      clientX: 4,
      clientY: 4,
    }));
  });
  expect(ordinaryEventAllowed).toBe(false);
  await expect(page.getByRole('menu', { name: 'Context menu' })).toHaveCount(0);

  await source.click();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'host.open_path' && request.params?.path === 'src/main.mbt:12'))
    .toBeTruthy();
  const localUri = markdown.getByTitle('Open /Users/me/My Project/main.mbt#L7');
  await expect(localUri).toBeVisible();
  await localUri.click();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'host.open_path' &&
    request.params?.path === '/Users/me/My Project/main.mbt#L7'))
    .toBeTruthy();
  const guidePath = '/Users/me/Library/Application Support/SeekMoon/gmachine-3.md';
  const guide = markdown.getByRole('button', { name: 'Bundled guide', exact: true });
  await expect(guide).toHaveAttribute('data-context-file', guidePath);
  await guide.click();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'host.open_path' && request.params?.path === guidePath))
    .toBeTruthy();
  expect(app.pageErrors).toEqual([]);
});

test('pending job waits show descriptions from earlier tool rows', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openseek.minimal_transcript', 'false'));
  const app = new DesktopBrowserHarness(page);
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture waiting for CI' } } },
    { sequence: 2, item: { kind: 'assistant', payload: {
      content: '', tool_calls: [{ id: 'start', name: 'mbtx',
        arguments: JSON.stringify({ description: 'Watch CI on rebased PR 27' }) }],
    } } },
    { sequence: 3, item: { kind: 'tool_result', payload: {
      tool_call_id: 'start', tool_name: 'mbtx', content: '',
      is_error: false, brief: 'mbtx → bg bg-10',
    } } },
    { sequence: 4, item: { kind: 'assistant', payload: {
      content: '', tool_calls: [{ id: 'wait', name: 'job_wait',
        arguments: JSON.stringify({ job_ids: ['bg-10', 'bg-11'] }) },
        { id: 'wait', name: 'job_wait', arguments: JSON.stringify({ job_ids: ['bg-11'] }) }],
    } } },
  ];
  await app.install();
  await app.goto();
  await app.openSession();
  const wait = page.locator('details.tool-call').filter({ hasText: 'Wait for' });
  await expect(wait.locator('.tool-call-text')).toHaveText([
    'Wait for any of these jobs to complete: "Watch CI on rebased PR 27", bg-11',
    'Wait for job bg-11 to complete',
  ]);
  await expect(wait.first()).not.toHaveAttribute('open', '');
  await wait.first().locator('summary').click();
  await expect(wait.first()).toContainText('"job_ids"');
  expect(app.pageErrors).toEqual([]);
});
