import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { MinimalTranscriptHarness } from './support/minimal_transcript_harness.js';

test('minimal images open by default and preserve manual collapse across updates', async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  const png = readFileSync(new URL('../../../deepseek/client/testdata/two-colors.png', import.meta.url)).toString('base64');
  const image = { type: 'image', media_type: 'image/png', data: png };
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture image previews' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: '', tool_calls: [
      { id: 'picture', name: 'read_image', arguments: '{"path":"PARAMETER_SENTINEL.png"}' },
      { id: 'missing', name: 'read_image', arguments: '{}' },
      { id: 'ptc', name: 'mbtx', arguments: '{"description":"Inspect generated images"}' },
    ] } } },
  ];
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const stream = page.locator('#stream');
  const rows = stream.locator('.minimal-call');
  await expect(rows).toHaveCount(3);
  await expect(rows.first().locator('.minimal-tool-icon > svg > path')).toHaveAttribute('d', /^M6 1C4\.89543/);
  await expect(stream.locator('.minimal-image-call')).toHaveCount(0);
  app.append('tool_result', {
    tool_call_id: 'picture', tool_name: 'read_image', brief: 'read_image preview.png', is_error: false,
    content: [{ type: 'text', text: 'OUTPUT_SENTINEL' }, image, image],
  });
  const preview = rows.first().locator('.minimal-image-call');
  await expect(preview).toHaveAttribute('open', '');
  await expect(preview.locator('img')).toHaveCount(2);
  await expect(preview.locator('img').first()).toBeVisible();
  await expect.poll(() => preview.locator('img').first().evaluate(img => img.naturalWidth)).toBeGreaterThan(0);
  // Native summary supports keyboard activation as well as clicking.
  await preview.locator('summary').focus();
  await page.keyboard.press('Enter');
  await expect(preview.locator('img').first()).toBeHidden();
  app.append('tool_result', {
    tool_call_id: 'missing', tool_name: 'read_image', brief: 'Cannot read missing.png', is_error: true,
    content: 'OUTPUT_SENTINEL',
  });
  await expect(rows.nth(1).locator('.tool-status.failed')).toBeVisible();
  await expect(rows.nth(1).locator('details')).toHaveCount(0);
  await expect(preview).not.toHaveAttribute('open', '');
  app.append('tool_result', {
    tool_call_id: 'ptc', tool_name: 'mbtx', brief: 'mbtx (exit=0)', is_error: false,
    content: [image],
    data: { ptc_calls: [{
      name: 'read_image', arguments: { path: 'preview.png' }, status: 'done',
      result: { version: 1, content: 'OUTPUT_SENTINEL', is_error: false },
    }] },
  });
  await expect(rows).toHaveCount(4);
  const ptc = rows.nth(2).locator('.minimal-image-call');
  await expect(ptc).toHaveAttribute('open', '');
  await expect(ptc.locator('img')).toBeVisible();
  await expect(preview).not.toHaveAttribute('open', '');
  await preview.locator('summary').click();
  await expect(preview.locator('img').first()).toBeVisible();
  await expect(stream).not.toContainText('OUTPUT_SENTINEL');
  await expect(stream).not.toContainText('PARAMETER_SENTINEL');

  app.append('terminal', { kind: 'finished', message: 'Images inspected.' });
  await page.reload();
  await app.openSession();
  await expect(preview).toHaveAttribute('open', '');
  const process = stream.locator('.minimal-process');
  await process.locator(':scope > summary').click();
  for (const img of await preview.locator('img').all()) {
    await expect(img).toBeVisible();
    await expect(img).toHaveAttribute('src', `data:image/png;base64,${png}`);
  }
  // Narrow layouts keep both the disclosure and the images inside the row.
  await page.setViewportSize({ width: 640, height: 900 });
  await expect(preview.locator('img').first()).toBeVisible();
  expect(await preview.evaluate(node => node.scrollWidth <= node.clientWidth)).toBe(true);
  expect(app.pageErrors).toEqual([]);
});

for (const retired of [false, true]) test(`minimal image collapse survives preceding PTC insertion (retired=${retired})`, async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  const png = readFileSync(new URL('../../../deepseek/client/testdata/two-colors.png', import.meta.url)).toString('base64');
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture stable image rows' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: '', tool_calls: [
      { id: 'earlier', name: 'mbtx', arguments: '{"description":"Earlier script"}' },
      { id: 'picture', name: 'read_image', arguments: '{}' },
    ] } } },
    { sequence: 3, item: { kind: 'tool_result', payload: {
      tool_call_id: 'picture', tool_name: 'read_image', brief: 'read_image later.png', is_error: false,
      content: [{ type: 'image', media_type: 'image/png', data: png }],
    } } },
  ];
  await app.install();
  await app.goto();
  await app.enableMinimal();
  if (retired) {
    app.append('assistant', { content: 'Continuing while the script runs.' });
    await page.locator('.minimal-tools > summary').click();
  }
  const preview = page.locator('.minimal-image-call');
  await expect(preview.locator('img')).toBeVisible();
  await preview.locator('summary').click();
  await expect(preview).not.toHaveAttribute('open', '');
  const original = await preview.elementHandle();
  app.append('tool_result', {
    tool_call_id: 'earlier', tool_name: 'mbtx', content: '', is_error: false,
    data: { ptc_calls: [{
      name: 'read_image', arguments: { path: 'earlier.png' }, status: 'done',
      result: { version: 1, content: 'Earlier image metadata', is_error: false },
    }] },
  });
  await expect(page.locator('.minimal-call-caption')).toHaveText(['Earlier script', 'read_image', 'read_image later.png']);
  await expect(preview).not.toHaveAttribute('open', '');
  expect(await original.evaluate(node => node.isConnected)).toBe(true);
  await expect(preview.locator('img')).toBeHidden();
  await preview.locator('summary').click();
  await expect(preview.locator('img')).toBeVisible();
  expect(app.pageErrors).toEqual([]);
});

test('a single completed minimal image call keeps its own disclosure', async ({ page }, testInfo) => {
  const app = new MinimalTranscriptHarness(page);
  const png = readFileSync(new URL('../../../deepseek/client/testdata/two-colors.png', import.meta.url)).toString('base64');
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture single image' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: '', tool_calls: [
      { id: 'image', name: 'read_image', arguments: '{}' },
    ] } } },
    { sequence: 3, item: { kind: 'tool_result', payload: {
      tool_call_id: 'image', tool_name: 'read_image', brief: 'read_image preview.png', is_error: false,
      content: [{ type: 'image', media_type: 'image/png', data: png }],
    } } },
    { sequence: 4, item: { kind: 'terminal', payload: { kind: 'finished', message: 'Image inspected.' } } },
  ];
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const row = page.locator('#stream .minimal-single-call');
  await expect(page.locator('#stream .minimal-process, #stream .minimal-tools')).toHaveCount(0);
  await expect(row.locator('details')).toHaveAttribute('open', '');
  await expect(row.locator('img')).toBeVisible();
  await expect(row.locator('.tool-status')).toHaveCount(0);
  await expect.poll(() => row.locator('img').evaluate(img => img.naturalWidth)).toBeGreaterThan(0);
  await row.screenshot({ animations: 'disabled', path: testInfo.outputPath('minimal-image-expanded.png') });
  expect(app.pageErrors).toEqual([]);
});
