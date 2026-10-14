import { test, expect } from '@playwright/test';
import { MinimalTranscriptHarness } from './support/minimal_transcript_harness.js';

test('minimal message groups separate outer turns from internal tool and prose spacing', async ({ page }, testInfo) => {
  const app = new MinimalTranscriptHarness(page);
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture spacing' } } },
  ];
  const events = [];
  for (const [index, calls] of [['single', ['one']], ['group', ['two', 'three']]]) {
    events.push({ kind: 'assistant', payload: { content: `Before ${index}`, tool_calls: calls.map(id => ({
      id, name: 'mbtx', arguments: JSON.stringify({ description: `Inspect ${id}` }),
    })) } });
    for (const id of calls) events.push({ kind: 'tool_result', payload: {
      tool_call_id: id, tool_name: 'mbtx', content: '', is_error: false,
    } });
    events.push({ kind: 'assistant', payload: { content: `After ${index}` } });
  }
  for (const item of events) app.sessionEvents.push({ sequence: app.sessionEvents.length + 1, item });
  await app.install();
  await app.goto();
  // Compare settled layout, without the prose entry animation's translation.
  await page.addStyleTag({ content: '#stream .msg { animation: none; }' });
  await app.enableMinimal();
  for (const completed of [false, true]) {
    if (completed) {
      app.append('assistant', { content: 'Finished inspection.' });
      app.append('terminal', { kind: 'finished', message: 'Finished inspection.' });
      await page.locator('.minimal-process > summary').click();
    }
    await expect(page.locator('#stream')).toHaveCSS('row-gap', '20px');
    await expect(page.locator('#stream > .minimal-messages')).toHaveCount(1);
    const body = completed ? page.locator('.minimal-process-body') : page.locator('#stream > .minimal-messages');
    await expect(body.locator(':scope > .minimal-single-call')).toHaveCount(1);
    await expect(body.locator(':scope > .minimal-tools')).toHaveCount(1);
    await expect(body.locator(':scope > .minimal-tools')).not.toHaveAttribute('open', '');
    for (const width of [1440, 640]) {
      await page.setViewportSize({ width, height: 900 });
      // Both live messages and expanded completed content use the internal
      // gap. Measure the actual tool-to-prose distances, without padding.
      const gaps = await body.evaluate(node => [...node.children]
        .filter(row => row.matches('.minimal-single-call, .minimal-tools'))
        .map(row => {
          const label = row.querySelector('.minimal-call-caption, .minimal-summary-text').getBoundingClientRect();
          return {
            before: label.top - row.previousElementSibling.getBoundingClientRect().bottom,
            after: row.nextElementSibling.getBoundingClientRect().top - label.bottom,
          };
        }));
      expect(Math.abs(gaps[0].before - gaps[1].before)).toBeLessThanOrEqual(1);
      expect(Math.abs(gaps[0].after - gaps[1].after)).toBeLessThanOrEqual(1);
      const expectedGap = 12;
      for (const gap of gaps) {
        expect(Math.abs(gap.before - expectedGap)).toBeLessThanOrEqual(1);
        expect(Math.abs(gap.after - expectedGap)).toBeLessThanOrEqual(1);
      }
      await page.screenshot({ animations: 'disabled', path: testInfo.outputPath(`minimal-spacing-${completed ? 'completed' : 'live'}-${width}.png`) });
    }
    // Successful summaries, singletons, and groups have no status badge.
    await expect(body.locator('.tool-status, .minimal-tool-status')).toHaveCount(0);
  }
  const completedBody = page.locator('.minimal-process-body');
  await completedBody.locator('.minimal-tools > summary').click();
  await expect(completedBody.locator('.minimal-call')).toHaveCount(3);
  await expect(completedBody.locator('.tool-status, .minimal-tool-status')).toHaveCount(0);
  app.append('user', { content: 'Inspect another file.' });
  app.append('assistant', { content: 'I will inspect the next file.', tool_calls: [
    { id: 'second-turn', name: 'read', arguments: JSON.stringify({ description: 'Read the next file' }) },
  ] });
  await expect(page.locator('#stream > .minimal-messages')).toHaveCount(2);
  // Only user rows and their message groups occupy the outer grid. Measure
  // the outer boundary too, so a global gap change cannot satisfy this test.
  const outer = await page.locator('#stream').evaluate(node => ({
    kinds: [...node.children].map(row => row.matches('.msg.user') ? 'user' : row.classList.contains('minimal-messages') ? 'messages' : row.className),
    gaps: [...node.children].slice(1).map(row => row.getBoundingClientRect().top - row.previousElementSibling.getBoundingClientRect().bottom),
  }));
  expect(outer.kinds).toEqual(['user', 'messages', 'user', 'messages']);
  for (const gap of outer.gaps) expect(Math.abs(gap - 20)).toBeLessThanOrEqual(1);
  expect(app.pageErrors).toEqual([]);
});

for (const count of [1, 2]) test(`minimal first tool row has balanced spacing with ${count} calls`, async ({ page }, testInfo) => {
  const app = new MinimalTranscriptHarness(page);
  const calls = Array.from({ length: count }, (_, i) => ({
    id: `first-${i}`, name: 'mbtx', arguments: JSON.stringify({ description: `Inspect stats ${i + 1}` }),
  }));
  const items = [
    { kind: 'user', payload: { content: 'Show the browser fixture first tool row' } },
    { kind: 'assistant', payload: { content: '', tool_calls: calls } },
    ...calls.map(call => ({ kind: 'tool_result', payload: {
      tool_call_id: call.id, tool_name: call.name, content: '', is_error: false,
    } })),
    { kind: 'assistant', payload: { content: 'These stats describe the completed runs. I will compare the results.' } },
    { kind: 'assistant', payload: { content: 'Comparison complete.' } },
    { kind: 'terminal', payload: { kind: 'finished', message: 'Comparison complete.' } },
  ];
  app.sessionEvents = items.map((item, i) => ({ sequence: i + 1, item }));
  await app.install();
  await app.goto();
  await page.addStyleTag({ content: '#stream .msg { animation: none; }' });
  await app.enableMinimal();
  const process = page.locator('.minimal-process');
  await process.locator(':scope > summary').click();
  const first = process.locator('.minimal-process-body > :first-child');
  await expect(first).toHaveClass(count === 1 ? /minimal-single-call/ : /minimal-tools/);
  for (const width of [1440, 640]) {
    await page.setViewportSize({ width, height: 900 });
    const gaps = await process.evaluate(node => {
      const summary = node.querySelector(':scope > summary .minimal-summary-text').getBoundingClientRect();
      const first = node.querySelector('.minimal-process-body > :first-child');
      const label = first.querySelector('.minimal-call-caption, .minimal-summary-text').getBoundingClientRect();
      return {
        before: label.top - summary.bottom,
        after: first.nextElementSibling.getBoundingClientRect().top - label.bottom,
      };
    });
    expect(Math.abs(gaps.before - gaps.after)).toBeLessThanOrEqual(1);
    expect(Math.abs(gaps.before - 12)).toBeLessThanOrEqual(1);
    expect(Math.abs(gaps.after - 12)).toBeLessThanOrEqual(1);
    await page.screenshot({ animations: 'disabled', path: testInfo.outputPath(`first-tool-${width}.png`) });
  }
  expect(app.pageErrors).toEqual([]);
});

test('minimal summaries truncate to one line at wide and narrow widths', async ({ page }, testInfo) => {
  const app = new MinimalTranscriptHarness(page);
  const description = 'Find Url/UrlSearchParams struct definitions and visibility attributes. '.repeat(8);
  app.sessionEvents = [
    { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture long summary' } } },
    { sequence: 2, item: { kind: 'assistant', payload: { content: 'Inspecting the API.', tool_calls: [
      { id: 'long', name: 'mbtx', arguments: JSON.stringify({ description }) },
    ] } } },
  ];
  await app.install();
  await app.goto();
  await app.enableMinimal();
  for (const completed of [false, true]) {
    if (completed) {
      app.append('assistant', { content: '', tool_calls: [
        { id: 'failed', name: 'read', arguments: JSON.stringify({ description }) },
      ] });
      app.append('tool_result', { tool_call_id: 'failed', tool_name: 'read', content: '', is_error: true });
      app.append('tool_result', { tool_call_id: 'long', tool_name: 'mbtx', content: '', is_error: true });
      app.append('terminal', { kind: 'finished', message: 'Inspection complete.' });
      await page.locator('.minimal-process > summary').click();
    }
    for (const width of [1440, 640]) {
      await page.setViewportSize({ width, height: 900 });
      for (const summary of await page.locator('.minimal-activity-summary, .minimal-single-call').all()) {
        const label = summary.locator(':scope > .minimal-summary-text, :scope > .minimal-call-caption');
        const metrics = await label.evaluate(node => ({
          height: node.getBoundingClientRect().height,
          lineHeight: Number.parseFloat(getComputedStyle(node).lineHeight),
          labelWidth: node.clientWidth,
          textWidth: node.scrollWidth,
        }));
        expect(metrics.height).toBeLessThanOrEqual(metrics.lineHeight + 1);
        expect(metrics.textWidth).toBeGreaterThan(metrics.labelWidth);
        await expect(label).toHaveAttribute('title', completed ? `${description} · ${description}` : description);
        const status = summary.locator(':scope > .minimal-tool-status');
        await expect(status).toBeVisible();
        // Read all bounds in one frame while resizing can still animate the
        // surrounding layout, so the comparison uses the same row position.
        const [rowBox, labelBox, statusBox] = await summary.evaluate(node => [
          node.getBoundingClientRect().toJSON(),
          node.querySelector(':scope > .minimal-summary-text, :scope > .minimal-call-caption').getBoundingClientRect().toJSON(),
          node.querySelector(':scope > .minimal-tool-status').getBoundingClientRect().toJSON(),
        ]);
        expect(statusBox.x).toBeGreaterThanOrEqual(labelBox.x + labelBox.width);
        expect(statusBox.x + statusBox.width).toBeLessThanOrEqual(rowBox.x + rowBox.width + 1);
        if (completed) {
          await expect(status.locator('.minimal-failure-count')).toHaveCount(0);
          await expect(status).not.toContainText(/tool calls? failed/);
          await expect(status.getByRole('img', { name: 'Tool failed' })).toBeVisible();
        }
      }
    }
  }
  await page.screenshot({ animations: 'disabled', path: testInfo.outputPath('minimal-single-line.png') });
  expect(app.pageErrors).toEqual([]);
});

test('minimal transcript clears jump to latest when folded content fits the viewport', async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  app.sessionEvents[5].item.payload.content = Array.from(
    { length: 60 }, (_, index) => `Progress paragraph ${index}.`,
  ).join('\n\n');
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const transcript = page.locator('#transcript');
  const jump = page.getByTitle('Jump to latest', { exact: true });
  await expect.poll(() => transcript.evaluate(node => node.scrollHeight - node.clientHeight))
    .toBeGreaterThan(1000);
  await transcript.evaluate(node => { node.scrollTop = 0; });
  await expect(jump).toBeVisible();

  // Collapsing from scrollTop=0 changes the available range without a scroll
  // event. The old unpinned state must not leave a button over the summary.
  app.append('terminal', { kind: 'finished', message: 'Finished checking.' });
  await expect(page.locator('.minimal-process')).toHaveCount(1);
  await expect.poll(() => transcript.evaluate(node => node.scrollHeight - node.clientHeight)).toBe(0);
  await expect(jump).toBeHidden();

  const summary = page.locator('.minimal-process > summary');
  await summary.click();
  await expect.poll(() => transcript.evaluate(node => node.scrollHeight - node.clientHeight))
    .toBeGreaterThan(1000);
  // The reader was pinned while everything fit, so it follows the expansion
  // to the tail one render later. Scroll away only after that follow lands;
  // an earlier scroll is overridden and leaves the reader pinned.
  await expect.poll(() => transcript.evaluate(node => node.scrollHeight - node.scrollTop - node.clientHeight))
    .toBeLessThanOrEqual(4);
  await transcript.evaluate(node => { node.scrollTop = 0; });
  await expect(jump).toBeVisible();
  await summary.click();
  await expect.poll(() => transcript.evaluate(node => node.scrollHeight - node.clientHeight)).toBe(0);
  await expect(jump).toBeHidden();
  expect(app.pageErrors).toEqual([]);
});
