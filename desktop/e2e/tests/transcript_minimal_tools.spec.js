import { test, expect } from '@playwright/test';
import { MinimalTranscriptHarness } from './support/minimal_transcript_harness.js';

test('single minimal calls have no duplicate disclosure and preserve status and edits', async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture single call' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: 'Checking the project.', tool_calls: [
      { id: 'single', name: 'mbtx', arguments: '{}' },
    ] } } },
  ];
  await app.install();
  await app.goto();
  await app.openSession();
  const stream = page.locator('#stream');
  await expect(stream.locator('.minimal-tools')).toHaveCount(0);
  await expect(stream.locator('.minimal-call .tool-status')).toHaveAttribute('aria-label', 'Tool in progress');
  app.append('tool_result', { tool_call_id: 'single', tool_name: 'mbtx', content: '', brief: 'mbtx (exit=0)', is_error: false });
  await expect(stream.locator('.minimal-call-caption')).toHaveText('mbtx (exit=0)');
  await expect(stream.locator('.minimal-call .tool-status')).toHaveCount(0);
  app.append('terminal', { kind: 'finished', message: 'Checked.' });
  const process = stream.locator('.minimal-process');
  await process.locator(':scope > summary').click();
  await expect(process.locator('.minimal-tools, .minimal-process-body summary')).toHaveCount(0);
  await expect(process.locator('.minimal-call-caption')).toBeVisible();

  app.append('user', { content: 'Edit the file next.' });
  app.append('assistant', { content: '', tool_calls: [
    { id: 'edit', name: 'edit', arguments: JSON.stringify({ path: 'main.mbt', old_string: 'old', new_string: 'new' }) },
  ] });
  const single = stream.locator(':scope > .minimal-messages > .minimal-single-call');
  await expect(single.locator('.tool-status')).toHaveAttribute('aria-label', 'Tool in progress');
  await expect(single.locator('.editor-diff-preview')).toBeVisible();
  app.append('tool_result', { tool_call_id: 'edit', tool_name: 'edit', content: '', brief: 'Edit failed', is_error: true });
  await expect(single.locator('.minimal-call-caption')).toHaveText('Edit failed');
  await expect(single.locator('.tool-status.failed')).toHaveAttribute('aria-label', 'Tool failed');
  await expect(single.locator('.minimal-failure-count')).toHaveCount(0);
  await expect(single).not.toContainText(/tool calls? failed/);
  app.append('terminal', { kind: 'finished', message: 'Could not edit.' });
  await expect(stream.getByText('Could not edit.', { exact: true })).toBeVisible();
  await expect(single.locator('.tool-status')).toBeVisible();
  await expect(single.locator('.editor-diff-preview')).toBeVisible();
  await expect(stream.locator('.minimal-tools')).toHaveCount(0);
  await expect(stream.locator('.minimal-process')).toHaveCount(1);
  expect(app.pageErrors).toEqual([]);
});

test('minimal current tools expand with icons and retire when new prose arrives', async ({ page }, testInfo) => {
  const app = new MinimalTranscriptHarness(page);
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const older = page.locator('.minimal-tools').first();
  await expect(older).not.toHaveAttribute('open', '');
  app.append('assistant', { content: 'Now inspect and edit the implementation.', tool_calls: [
    { id: 'live-read', name: 'read', arguments: JSON.stringify({ description: 'Read the implementation' }) },
    { id: 'live-edit', name: 'edit', arguments: JSON.stringify({ description: 'Edit the implementation' }) },
    { id: 'live-script', name: 'mbtx', arguments: JSON.stringify({ description: 'Verify the implementation' }) },
  ] });
  const live = page.locator('.minimal-tools-live');
  await expect(live.locator('.minimal-call-caption')).toHaveText([
    'Read the implementation', 'Edit the implementation', 'Verify the implementation',
  ]);
  await expect(live.locator('summary')).toHaveCount(0);
  await expect(live.locator('.minimal-tool-icon > svg')).toHaveCount(3);
  await expect(live.locator('.minimal-tool-icon')).toHaveText(['', '', '']);
  for (const name of ['read', 'edit', 'mbtx']) {
    await expect(live.locator(`.minimal-tool-icon[title="${name}"] > svg`)).toBeVisible();
  }
  for (const row of await live.locator('.minimal-call').all()) await expect(row).toBeVisible();
  app.append('tool_result', { tool_call_id: 'live-read', tool_name: 'read', content: '', brief: 'Read implementation.mbt', is_error: false });
  await expect(live.locator('.minimal-call-caption').first()).toHaveText('Read implementation.mbt');
  await expect(live.locator('.tool-status.pending')).toHaveCount(2);
  await expect(older).not.toHaveAttribute('open', '');
  await page.screenshot({ animations: 'disabled', path: testInfo.outputPath('minimal-live-icons.png') });
  await page.locator('.minimal-messages').screenshot({ animations: 'disabled', path: testInfo.outputPath('minimal-icons-alignment.png') });

  app.append('assistant', { content: 'The implementation is ready; check the results.', tool_calls: [
    { id: 'next-read', name: 'read', arguments: JSON.stringify({ description: 'Read the results' }) },
    { id: 'next-image', name: 'imageView', arguments: JSON.stringify({ description: 'Inspect the screenshot' }) },
  ] });
  await expect(page.locator('.minimal-tools')).toHaveCount(2);
  const retired = page.locator('.minimal-tools').last();
  await expect(retired).not.toHaveAttribute('open', '');
  await expect(retired.locator('.minimal-call').first()).toBeHidden();
  await expect(live.locator('.minimal-call-caption')).toHaveText(['Read the results', 'Inspect the screenshot']);
  await expect(live.locator('.minimal-tool-icon > svg')).toHaveCount(2);
  await expect(live.locator('.minimal-tool-icon[title="imageView"] > svg')).toBeVisible();
  await retired.locator(':scope > summary').click();
  app.append('tool_result', { tool_call_id: 'next-read', tool_name: 'read', content: '', brief: 'Read results.json', is_error: false });
  await expect(live.locator('.minimal-call-caption').first()).toHaveText('Read results.json');
  await expect(retired).toHaveAttribute('open', '');
  for (const width of [1440, 640]) {
    await page.setViewportSize({ width, height: 900 });
    const layout = await retired.evaluate(node => {
      const summary = node.querySelector(':scope > summary');
      const label = summary.querySelector('.minimal-summary-text').getBoundingClientRect();
      const arrow = summary.querySelector('.minimal-chevron').getBoundingClientRect();
      const body = node.querySelector('.minimal-call-list');
      return { labelRight: label.right, arrowLeft: arrow.left,
        border: getComputedStyle(body).borderLeftWidth,
        indent: getComputedStyle(body).marginLeft,
        padding: getComputedStyle(body).paddingLeft };
    });
    expect(layout.arrowLeft).toBeGreaterThanOrEqual(layout.labelRight);
    expect(layout.border).toBe('0px');
    expect(layout.indent).toBe('0px');
    expect(layout.padding).toBe('0px');
    // SVG baselines differ from text baselines. Compare visible row centers
    // so folded summaries, expanded calls and their status icons stay aligned.
    const rows = await page.locator('.minimal-activity-summary:visible, .minimal-call:visible').evaluateAll(nodes => nodes.map(node => {
      const caption = node.querySelector('.minimal-summary-text, .minimal-call-caption').getBoundingClientRect();
      const icons = [...node.querySelectorAll(':scope > .minimal-tool-icon > svg, :scope > .minimal-chevron, :scope > .tool-status, :scope > .minimal-tool-status')];
      const tool = node.querySelector(':scope > .minimal-tool-icon > svg').getBoundingClientRect();
      return { width: tool.width, height: tool.height,
        offsets: icons.map(icon => { const box = icon.getBoundingClientRect(); return box.y + box.height / 2 - caption.y - caption.height / 2; }) };
    }));
    for (const row of rows) {
      for (const offset of row.offsets) expect(Math.abs(offset)).toBeLessThanOrEqual(0.5);
      expect(row.width).toBe(14);
      expect(row.height).toBe(14);
    }
  }
  await page.screenshot({ animations: 'disabled', path: testInfo.outputPath('minimal-retired-icons.png') });
  expect(app.pageErrors).toEqual([]);
});

test('minimal captions persist through completion and yield to newer descriptions and briefs', async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture latest operation' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: '', tool_calls: [
      { id: 'script', name: 'mbtx', arguments: JSON.stringify({ description: 'Run project tests' }) },
    ] } } },
  ];
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const summary = page.locator('#stream > .minimal-messages .minimal-call-caption').last();
  const calls = page.locator('#stream > .minimal-messages > .minimal-tools-live .minimal-call, #stream > .minimal-messages > .minimal-single-call');
  await expect(summary).toHaveText('Run project tests');
  app.append('tool_result', {
    tool_call_id: 'script', tool_name: 'mbtx', brief: 'mbtx → bg bg-1', content: '', is_error: false,
  });
  await expect(calls.locator('.tool-status')).toHaveCount(0);
  await expect(summary).toHaveText('Run project tests');
  app.append('runtime_notice', { content: 'background job bg-1 finished (exit=0): Run project tests' });
  app.append('assistant', { content: '', tool_calls: [{ id: 'edit', name: 'edit', arguments: '{}' }] });
  await expect(calls).toHaveCount(2);
  await expect(summary).toHaveText('edit');
  app.append('tool_result', {
    tool_call_id: 'edit', tool_name: 'edit', brief: 'Edited main.mbt', content: '', is_error: false,
  });
  await expect(calls.last().locator('.minimal-call-caption')).toHaveText('Edited main.mbt');
  await expect(summary).toHaveText('Edited main.mbt');
  app.append('assistant', { content: '', tool_calls: [
    { id: 'next', name: 'read', arguments: JSON.stringify({ description: 'Check test results' }) },
  ] });
  await expect(summary).toHaveText('Check test results');
  app.append('tool_result', {
    tool_call_id: 'next', tool_name: 'read', brief: 'Read results.json', content: '', is_error: false,
  });
  await expect(calls.last().locator('.minimal-call-caption')).toHaveText('Read results.json');
  await expect(summary).toHaveText('Read results.json');
  app.append('assistant', { content: '', tool_calls: [
    { id: 'plan', name: 'plan', arguments: '{}' },
  ] });
  app.append('tool_result', {
    tool_call_id: 'plan', tool_name: 'plan', brief: 'Updated plan', content: '', is_error: false,
  });
  await expect(summary).toHaveText('Updated plan');
  app.append('terminal', { kind: 'finished', message: 'Tests passed.' });
  const completed = page.locator('#stream > .minimal-messages > .minimal-process');
  await expect(completed.locator(':scope > summary > .minimal-summary-text')).toHaveText('Run project tests · Edited main.mbt · Read results.json · …');
  // One tool group needs only the completed-turn disclosure, regardless of
  // how many calls it contains. Opening it once exposes every operation.
  await expect(completed.locator('.minimal-tools')).toHaveCount(0);
  await expect(completed.locator('.minimal-call').first()).toBeHidden();
  await completed.locator(':scope > summary').click();
  await expect(completed.locator('.minimal-call-caption')).toHaveText([
    'Run project tests', 'Edited main.mbt', 'Read results.json', 'Updated plan',
  ]);
  for (const call of await completed.locator('.minimal-call').all()) {
    await expect(call).toBeVisible();
  }
  await expect(completed.locator('.minimal-note')).toBeVisible();
  expect(app.pageErrors).toEqual([]);
});

test('minimal job waits name their targets while pending and disappear after success', async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture job waits' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: '', tool_calls: [
      { id: 'start', name: 'mbtx', arguments: JSON.stringify({ description: 'Run the pr tests', script: 'SCRIPT_SENTINEL' }) },
    ] } } },
    { sequence: 3, item: { kind: 'tool_result', payload: {
      tool_call_id: 'start', tool_name: 'mbtx', brief: 'mbtx → bg bg-2', content: 'OUTPUT_SENTINEL', is_error: false,
    } } },
    { sequence: 4, item: { kind: 'assistant', payload: { content: '', tool_calls: [
      { id: 'wait', name: 'job_wait', arguments: JSON.stringify({ job_ids: ['bg-2', 'bg-2'] }) },
    ] } } },
  ];
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const stream = page.locator('#stream');
  const tools = stream.locator('.minimal-tools-live');
  const caption = 'Wait for job "Run the pr tests" to complete';
  await expect(tools.locator('.minimal-call-caption').last()).toHaveText(caption);

  await expect(tools.locator('.minimal-call-caption')).toHaveText(['Run the pr tests', caption]);
  await expect(tools.locator('.minimal-call .tool-status.pending')).toHaveAttribute('aria-label', 'Tool in progress');
  const notice = 'background job bg-2 finished (exit=0): Run the pr tests';
  app.append('runtime_notice', { content: notice });
  app.append('tool_result', { tool_call_id: 'wait', tool_name: 'job_wait', content: 'WAIT_RESULT_SENTINEL', is_error: false });
  await expect(tools.locator('.minimal-call-caption')).toHaveText(['Run the pr tests']);
  await expect(tools.locator('.minimal-call-caption').last()).toHaveText('Run the pr tests');
  await expect(tools.getByText(notice, { exact: true })).toBeVisible();
  await expect(stream).not.toContainText('WAIT_RESULT_SENTINEL');

  app.append('assistant', { content: '', tool_calls: [
    { id: 'wait-many', name: 'job_wait', arguments: JSON.stringify({ job_ids: ['bg-2', 'bg-unknown'] }) },
  ] });
  await expect(tools.locator('.minimal-call-caption').last()).toHaveText('Wait for any of these jobs to complete: "Run the pr tests", bg-unknown');
  app.append('tool_result', { tool_call_id: 'wait-many', tool_name: 'job_wait', content: 'unknown job', brief: 'Unknown job bg-unknown', is_error: true });
  await expect(tools.locator('.minimal-call-caption')).toHaveText(['Run the pr tests', 'Unknown job bg-unknown']);
  await expect(tools.locator('.minimal-call .tool-status.failed')).toHaveAttribute('aria-label', 'Tool failed');
  await expect(tools.locator('.minimal-call-caption').last()).toHaveText('Unknown job bg-unknown');

  // A wait-only group disappears without leaving an empty activity disclosure.
  app.append('assistant', { content: 'Waiting for another job.', tool_calls: [
    { id: 'wait-only', name: 'job_wait', arguments: JSON.stringify({ job_ids: ['bg-3'] }) },
  ] });
  await expect(stream.locator('.minimal-tools')).toHaveCount(1);
  const singleWait = stream.locator(':scope > .minimal-messages > .minimal-single-call');
  await expect(singleWait.locator('.minimal-call-caption')).toHaveText('Wait for job bg-3 to complete');
  app.append('tool_result', { tool_call_id: 'wait-only', tool_name: 'job_wait', content: 'Woken by user input', is_error: false });
  await expect(stream.locator('.minimal-tools')).toHaveCount(1);
  await expect(stream).not.toContainText('Wait for job bg-3 to complete');
  await expect(singleWait).toHaveCount(0);

  // Full transcript still exposes all three wait calls for inspection.
  await app.detailedMode().click();
  await app.openSession();
  await expect(stream.locator('details.tool-call')).toHaveCount(4);
  expect(app.pageErrors).toEqual([]);
});

test('minimal OpenSeek searches and submit tools use registered activity names', async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  const names = ['web_search', 'submit_result', 'submit_answer', 'submit_pattern_repair', 'submit_review', 'finish'];
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture built-in activities' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: '', tool_calls: names.map(name => ({ id: name, name, arguments: '{}' })) } } },
    ...names.map((name, index) => ({ sequence: index + 3, item: { kind: 'tool_result', payload: {
      tool_call_id: name, tool_name: name, brief: name, content: 'OUTPUT_SENTINEL', is_error: false,
    } } })),
  ];
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const group = page.locator('.minimal-tools-live');
  await expect(group.locator('summary')).toHaveCount(0);
  await expect(group.locator('.minimal-call-caption')).toHaveText(names);
  await expect(group).not.toContainText('OUTPUT_SENTINEL');
});

test('minimal job output and runtime notices preserve recorded text', async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  app.sessionEvents = [{ sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture job text' } } }];
  await app.install(); await app.goto(); await app.openSession();
  const stream = page.locator('#stream');
  const briefs = [
    'job bg-1 (running): Build · run tests',
    'job bg-1 (output capture failed: read ): broken): Build · run tests',
    'Could not read job output',
  ];
  for (const [index, brief] of briefs.entries()) {
    const id = `read-${index}`;
    app.append('assistant', { content: '', tool_calls: [{ id, name: 'job_output', arguments: '{"job_id":"bg-1"}' }] });
    app.append('tool_result', { tool_call_id: id, tool_name: 'job_output', content: 'OUTPUT_SENTINEL', brief, is_error: index > 0 });
    await expect(stream.locator('.minimal-call-caption').last()).toHaveText(`Read output of ${brief}`);
    await expect(stream.locator('.minimal-call').last().locator('.tool-status.failed')).toHaveCount(index > 0 ? 1 : 0);
  }
  const original = await stream.locator('.minimal-call').evaluateAll(rows => rows.map(row => row.outerHTML));
  const notices = [
    'background job bg-1 finished (exit=0): `Build · run tests · mbtx run` — read its output with job_output (job_id="bg-1").',
    'background job bg-1 finished (cleanup failed: read ): broken): `Build · run tests` — read its output with job_output (job_id="other").',
    'background job bg-1 finished (exit=0): `Truncated notice',
    'An unrelated runtime notice',
  ];
  for (const notice of notices) {
    app.append('runtime_notice', { content: notice });
    await expect(stream.locator('.minimal-note').last()).toHaveText(notice);
    await expect(stream.locator('.minimal-note').last().locator('.minimal-tool-icon > svg')).toBeVisible();
  }
  // The notice icon belongs to the notice's first text line. A wrapped notice
  // must not drag it to the block's midline, and top alignment must not leave
  // it on the block's edge: its cell is one line tall, so compare the icon's
  // center with the first line box the row's own line-height describes.
  for (const width of [1440, 640]) {
    await page.setViewportSize({ width, height: 900 });
    const offsets = await stream.locator('.minimal-runtime-note:visible').evaluateAll(nodes => nodes.map(node => {
      const text = node.querySelector('.minimal-note-text').getBoundingClientRect();
      const icon = node.querySelector(':scope > .minimal-tool-icon > svg').getBoundingClientRect();
      return icon.y + icon.height / 2 - text.y - parseFloat(getComputedStyle(node).lineHeight) / 2;
    }));
    expect(offsets.length).toBe(notices.length);
    for (const offset of offsets) expect(Math.abs(offset)).toBeLessThanOrEqual(0.5);
  }
  await page.setViewportSize({ width: 1440, height: 900 });
  expect(await stream.locator('.minimal-call').evaluateAll(rows => rows.map(row => row.outerHTML))).toEqual(original);
  await expect(stream).not.toContainText('OUTPUT_SENTINEL');
  await page.reload(); await app.openSession();
  await expect(stream.locator('.minimal-call-caption')).toHaveText(briefs.map(brief => `Read output of ${brief}`));
  await expect(stream.locator('.minimal-note')).toHaveText(notices);
  await app.detailedMode().click();
  for (const notice of notices) await expect(stream).toContainText(notice);
  expect(app.pageErrors).toEqual([]);
});
