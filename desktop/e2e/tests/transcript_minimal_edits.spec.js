import { test, expect } from '@playwright/test';
import { MinimalTranscriptHarness } from './support/minimal_transcript_harness.js';

test('minimal edit previews share detailed-mode unified lines and preserve call state', async ({ page }, testInfo) => {
  const app = new MinimalTranscriptHarness(page);
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture requested edits' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: '', tool_calls: [
      { id: 'edit-one', name: 'edit', arguments: JSON.stringify({
        path: 'src/main.mbt', start_line: 12, old_string: 'first\nold\nlast', new_string: 'first\nnew\nlast',
        description: 'Update the entry point', internal: 'PARAMETER_SENTINEL',
      }) },
      { id: 'edit-many', name: 'multi_edit', arguments: JSON.stringify({
        description: 'Update supporting files', edits_file: 'PARAMETER_SENTINEL',
        edits: [
          { file: 'src/add.mbt', old_string: '', new_string: 'added <script>', internal: 'PARAMETER_SENTINEL' },
          { file: 'src/remove.mbt', old_string: 'deleted', new_string: '' },
        ],
      }) },
    ] } } },
  ];
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const stream = page.locator('#stream');
  const tools = stream.locator('.minimal-tools-live');
  await expect(tools.locator('.editor-diff-preview').first()).toBeVisible();
  const calls = tools.locator('.minimal-call');
  await expect(calls.locator('.tool-status.pending')).toHaveCount(2);
  await expect(calls.nth(0).locator('.editor-diff-source')).toHaveText(['first', 'old', 'new', 'last']);
  await expect(calls.nth(0).locator('.editor-diff-sign')).toHaveText(['', '−', '+', '']);
  await expect(calls.nth(0).locator('.edit-path')).toHaveText('src/main.mbt');
  await expect(calls.nth(0).locator('.editor-diff-number')).toHaveText(['12', '13', '13', '14']);
  await expect(calls.locator('.tool-card-chip')).toHaveCount(0);
  await expect(calls.nth(1).locator('.edit-path')).toHaveText(['src/add.mbt', 'src/remove.mbt']);
  await expect(calls.nth(1).locator('.added .editor-diff-source')).toHaveText('added <script>');
  await expect(calls.nth(1).locator('.removed .editor-diff-source')).toHaveText('deleted');
  await expect(calls.locator('.editor-diff-preview script')).toHaveCount(0);
  await expect(tools.locator('summary')).toHaveCount(0);
  for (const [id, name, failed] of [['edit-one', 'edit', false], ['edit-many', 'multi_edit', true]]) {
    app.append('tool_result', { tool_call_id: id, tool_name: name, content: 'OUTPUT_SENTINEL',
      is_error: failed, brief: failed ? 'Batch rejected' : 'Updated entry point' });
  }
  await expect(calls.last().locator('.minimal-call-caption')).toHaveText('Batch rejected');
  await expect(calls.locator('.editor-diff-preview').first()).toBeVisible();
  await expect(calls.nth(1).locator('.tool-status.failed')).toHaveAttribute('aria-label', 'Tool failed');
  await expect(calls.locator('.editor-diff-preview')).toHaveCount(3);
  await expect(stream).not.toContainText('PARAMETER_SENTINEL');
  await expect(stream).not.toContainText('OUTPUT_SENTINEL');
  await expect(stream.locator('.tool-call-tabs')).toHaveCount(0);
  await page.screenshot({ animations: 'disabled', path: testInfo.outputPath('minimal-edit-diffs.png') });
  await page.setViewportSize({ width: 640, height: 900 });
  await page.emulateMedia({ colorScheme: 'dark' });
  for (const block of await calls.locator('.minimal-edit-block').all()) {
    await expect(block.getByRole('button', { name: 'Copy diff', exact: true })).toBeVisible();
    const box = await block.boundingBox();
    expect(box.x + box.width).toBeLessThanOrEqual(640);
  }
  await page.screenshot({ animations: 'disabled', path: testInfo.outputPath('minimal-edit-diffs-dark-narrow.png') });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.emulateMedia({ colorScheme: 'light' });
  const minimalDiffs = await calls.locator('.editor-diff-source').allTextContents();
  app.append('assistant', { content: 'Finished reviewing the edits.' });
  app.append('terminal', { kind: 'finished', message: 'Finished reviewing the edits.' });
  await expect(stream.locator('.editor-diff-preview').first()).toBeHidden();
  await expect(stream.getByText('Finished reviewing the edits.', { exact: true })).toBeVisible();
  const completed = stream.locator('.minimal-process');
  await expect(completed.locator('.minimal-tools')).toHaveCount(0);
  await completed.locator(':scope > summary').click();
  await expect(completed.locator('.editor-diff-preview').first()).toBeVisible();
  await expect(completed.locator('.editor-diff-preview')).toHaveCount(3);
  await expect(completed.locator('.minimal-call .tool-status.failed')).toHaveAttribute('aria-label', 'Tool failed');

  // Detailed mode keeps the original diff prefixes, while minimal mode uses backgrounds; its
  // Original JSON tabs remain available. Expand parents before tool rows.
  await app.detailedMode().click();
  await app.openSession();
  await expect(stream.locator('details.tool-call')).toHaveCount(2);
  for (const disclosure of await stream.locator('details.activity, details.activity-step-group').all()) {
    if (await disclosure.getAttribute('open') === null) await disclosure.locator(':scope > summary').click();
  }
  for (const disclosure of await stream.locator('details.tool-call').all()) {
    if (await disclosure.getAttribute('open') === null) await disclosure.locator(':scope > summary').click();
  }
  await expect(stream.locator('.tool-diff').first()).toBeVisible();
  expect((await stream.locator('.tool-diff > div').allTextContents()).map(line => line.slice(2))).toEqual(minimalDiffs);
  await expect(stream.getByText('Original JSON', { exact: true }).first()).toBeVisible();
});

test('minimal diff uses syntax colors and change backgrounds', async ({ page }, testInfo) => {
  const app = new MinimalTranscriptHarness(page);
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture highlighted edits' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: '', tool_calls: [
      { id: 'highlight', name: 'multi_edit', arguments: JSON.stringify({ edits: [
        { file: 'scripts/write-refusals.mbtx', start_line: 297,
          old_string: 'fn main {\n  let message = "before"\n  println(message)\n}',
          new_string: 'fn main {\n  let message = "<script>after</script>"\n  println(message)\n}' },
        { file: 'src/index.js', start_line: 1, old_string: 'const count = 1;', new_string: 'const count = 2;' },
        { file: 'notes.txt', old_string: 'before\n\nend', new_string: 'after\n\nend' },
      ] }) },
    ] } } },
  ];
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const blocks = page.locator('.minimal-edit-block');
  await expect(blocks.first().locator('.added .mtk3')).toHaveText('let');
  await expect(blocks.first().locator('.added .mtk5')).toHaveText('"<script>after</script>"');
  await expect(blocks.first().locator('script')).toHaveCount(0);
  await expect(blocks.nth(1).locator('.added .mtk3')).toHaveText('const');
  await expect(blocks.nth(2).locator('.added .editor-diff-source')).toHaveText('after');
  const blank = blocks.nth(2).locator('.context').first();
  await expect(blank.locator('.editor-diff-source')).toHaveText('');
  expect((await blank.boundingBox()).height).toBeGreaterThan(0);
  for (const colorScheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme });
    const colors = await blocks.first().evaluate(block => {
      const add = block.querySelector('.added');
      const del = block.querySelector('.removed');
      return {
        add: getComputedStyle(add).backgroundImage,
        del: getComputedStyle(del).backgroundImage,
        keyword: getComputedStyle(add.querySelector('.mtk3')).color,
        string: getComputedStyle(add.querySelector('.mtk5')).color,
        title: getComputedStyle(block.querySelector('.edit-titlebar')).fontSize,
        code: getComputedStyle(block.querySelector('.editor-diff-preview')).fontSize,
      };
    });
    expect(colors.add).not.toBe(colors.del);
    expect(colors.add).not.toBe('none');
    expect(colors.keyword).not.toBe(colors.string);
    expect(parseFloat(colors.title)).toBeGreaterThan(parseFloat(colors.code));
    await blocks.first().screenshot({ animations: 'disabled', path: testInfo.outputPath(`highlighted-diff-${colorScheme}.png`) });
  }
  expect(app.pageErrors).toEqual([]);
});

test('minimal diff pins line numbers and markers while source scrolls', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 640, height: 900 });
  const app = new MinimalTranscriptHarness(page);
  const source = '  let message = "' + 'long source '.repeat(24) + '"';
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture long diff lines' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: '', tool_calls: [
      { id: 'long-edit', name: 'edit', arguments: JSON.stringify({
        path: 'desktop/frontend/component_transcript.mbt', start_line: 1529,
        old_string: 'fn main {\n  let message = "before"\n}',
        new_string: `fn main {\n${source}\n}`,
      }) },
    ] } } },
  ];
  await app.install();
  await app.goto();
  await page.getByRole('button', { name: 'Show sidebar', exact: true }).click();
  await app.openSession();
  await expect(page.locator('.app')).toHaveClass(/sidebar-collapsed/);
  const block = page.locator('.minimal-edit-block');
  const diff = block.locator('.editor-diff-preview');
  await expect(block.locator('.added .editor-diff-source')).toHaveText(source);
  for (const colorScheme of ['light', 'dark']) {
    await page.emulateMedia({ colorScheme });
    const title = await block.locator('.edit-titlebar').boundingBox();
    const geometry = await diff.evaluate(el => ({
      width: el.clientWidth, contentWidth: el.scrollWidth,
      heights: [...el.querySelectorAll('.editor-diff-row')].map(row => row.getBoundingClientRect().height),
      widths: [...el.querySelectorAll('.editor-diff-row')].map(row => row.getBoundingClientRect().width),
      lineHeight: parseFloat(getComputedStyle(el).lineHeight),
      pageWidth: document.documentElement.scrollWidth,
    }));
    expect(geometry.contentWidth).toBeGreaterThan(geometry.width);
    expect(geometry.pageWidth).toBeLessThanOrEqual(640);
    for (const height of geometry.heights) expect(height).toBeCloseTo(geometry.lineHeight, 0);
    for (const width of geometry.widths) expect(width).toBeCloseTo(geometry.widths[0], 0);
    const gutters = block.locator('.editor-diff-number, .editor-diff-sign');
    const before = await gutters.evaluateAll(els => els.map(el => el.getBoundingClientRect().x));
    for (const row of await block.locator('.editor-diff-row').all()) {
      const spacing = await row.evaluate(el => {
        const number = el.querySelector('.editor-diff-number');
        const range = document.createRange();
        range.selectNodeContents(number);
        return { number: range.getBoundingClientRect().right,
          marker: el.querySelector('.editor-diff-sign').getBoundingClientRect().x };
      });
      if (spacing.number > 0) expect(spacing.marker - spacing.number).toBeGreaterThanOrEqual(6);
    }
    await diff.evaluate(el => { el.scrollLeft = 160; });
    await expect.poll(() => diff.evaluate(el => el.scrollLeft)).toBe(160);
    expect(await gutters.evaluateAll(els => els.map(el => el.getBoundingClientRect().x))).toEqual(before);
    expect(await block.locator('.edit-titlebar').boundingBox()).toEqual(title);
    await block.hover();
    await expect(block.getByRole('button', { name: 'Copy diff', exact: true })).toBeVisible();
    await block.screenshot({ animations: 'disabled', path: testInfo.outputPath(`scrolling-diff-${colorScheme}.png`) });
    await diff.evaluate(el => { el.scrollLeft = 0; });
  }
  expect(app.pageErrors).toEqual([]);
});

test('minimal edits handle unreadable payloads and bound multi-edit previews', async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  const batch = Array.from({ length: 51 }, (_, i) => ({ file: `src/${i}.mbt`, old_string: 'old', new_string: 'new' }));
  batch.splice(1, 0, { file: 'invalid.mbt', old_string: 'missing replacement' });
  const argumentsList = [
    ['edit', '{'],
    ['edit', JSON.stringify({ old_string: 'same', new_string: 'same' })],
    ['multi_edit', JSON.stringify({ edits_file: 'unavailable.json' })],
    ['edit', JSON.stringify({ old_string: 'old', new_string: 'x'.repeat(128001) })],
  ];
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture partial edits' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: '', tool_calls:
      argumentsList.map(([name, args], i) => ({ id: `edit-${i}`, name, arguments: args })),
    } } },
  ];
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const tools = page.locator('.minimal-tools-live');
  await expect(tools.locator('summary')).toHaveCount(0);
  app.append('assistant', { content: '', tool_calls: [
    { id: 'batch', name: 'multi_edit', arguments: JSON.stringify({ edits: batch }) },
  ] });
  const calls = tools.locator('.minimal-call');
  await expect(calls).toHaveCount(5);
  await expect(calls.last().locator('.editor-diff-preview').first()).toBeVisible();
  for (let i = 0; i < 4; i++) {
    await expect(calls.nth(i).locator('.minimal-call-caption')).toBeVisible();
    await expect(calls.nth(i).locator('.editor-diff-preview')).toHaveCount(0);
  }
  await expect(calls.last().locator('.editor-diff-preview')).toHaveCount(50);
  await expect(calls.last().locator('.edit-omitted')).toContainText('2 more edits not shown');
});

// Keep both tool payload shapes. Git inventory variants cannot affect this
// path-only action; each case asserts that no Git original is requested.
// Append/copy payload variants are covered by edit_diff_wbtest.mbt.
for (const scenario of ['partial', 'search-bound']) test(`minimal diff title opens the file without a position check: ${scenario}`, async ({ page, context }) => {
  const app = new MinimalTranscriptHarness(page);
  const source = Array.from({ length: 180 }, (_, i) => `fn line_${i + 1}() -> Int { ${i + 1} }`).join('\n');
  app.gitFilesByRevision[app.gitBaseline]['src/main.mbt'] = source;
  // Later edits do not block opening the file. The requested fragment no
  // longer matches, and the first current hunk is far from the old request.
  app.workingFiles['src/main.mbt'] = source.replace('Int { 2 }', 'Int { 998 }').replace('Int { 140 }', 'Int { 1000 }');
  const old = '140';
  const modified = '999';
  const start = scenario === 'search-bound' ? 1 : 140;
  app.rpcDelays.set('git.original_file', 150);
  app.rpcDelays.set('fs.read_file', 75);
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture recorded edit' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: '', tool_calls: [
      { id: 'recorded', name: scenario === 'search-bound' ? 'multi_edit' : 'edit', arguments: JSON.stringify(scenario === 'search-bound' ? {
        edits: [{ file: 'src/main.mbt', start_line: start, old_string: old, new_string: modified }],
      } : { path: 'src/main.mbt', start_line: start, old_string: old, new_string: modified }) },
    ] } } },
  ];
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const block = page.locator('.minimal-edit-block');
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await block.hover();
  await block.getByRole('button', { name: 'Copy diff', exact: true }).click();
  await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toBe(`- ${old}\n+ ${modified}`);
  const title = block.getByRole('button', { name: 'src/main.mbt', exact: true });
  await title.click();
  await expect(page.locator('#viewer-host')).toBeVisible();
  await expect(page.locator('#viewer-host')).toContainText('line_1()');
  await expect(page.locator('#viewer-host')).toContainText('Int { 998 }');
  await expect(page.locator('#diff-editor-host')).toBeHidden();
  await expect(page.locator('.semantic-review')).toBeHidden();
  await title.click();
  await expect(page.locator('#viewer-host')).toBeVisible();
  await expect(page.locator('.editor-tab')).toHaveCount(1);
  await expect.poll(() => app.requests.filter(r => r.method === 'fs.read_file' && r.params.path === '/workspace/src/main.mbt').length).toBeGreaterThan(0);
  expect(app.requests.filter(r => r.method === 'host.open_path').map(r => r.params.path)).toEqual(['src/main.mbt', 'src/main.mbt']);
  expect(app.requests.filter(r => r.method === 'git.original_file')).toHaveLength(0);
  await expect(page.locator('.notification')).toHaveCount(0);
  expect(app.pageErrors).toEqual([]);
});
