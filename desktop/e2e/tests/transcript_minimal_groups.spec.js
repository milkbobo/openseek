import { test, expect } from '@playwright/test';
import { MinimalTranscriptHarness } from './support/minimal_transcript_harness.js';

test('minimal transcript groups live tools and folds completed work around user messages', async ({ page }, testInfo) => {
  const app = new MinimalTranscriptHarness(page);
  await app.install();
  await app.goto();
  await app.openSession();
  await expect(page.locator('.minimal-tools')).toHaveCount(1);
  await app.enableMinimal();
  const stream = page.locator('#stream');
  const tools = stream.locator('.minimal-tools');
  await expect(tools).toHaveCount(1);
  await expect(tools.locator('summary')).toHaveCSS('list-style-type', 'none');
  await expect(tools.locator('.minimal-chevron svg')).toHaveCount(1);
  await expect(tools.locator('summary > .minimal-summary-text')).toHaveText('Read the project manifest · Cannot read the second file · Check project details');
  const aggregate = tools.locator(':scope > summary > .minimal-tool-status');
  await expect(aggregate.locator('.minimal-failure-count')).toHaveCount(0);
  await expect(aggregate).not.toContainText(/tool calls? failed/);
  await expect(aggregate.getByRole('img', { name: 'Tool failed' })).toBeVisible();
  const spinner = aggregate.locator('.tool-status-spinner');
  await expect(spinner).toBeVisible();
  expect(await spinner.evaluate(node => node.getAnimations().some(animation =>
    animation.playState === 'running' && animation.effect.getTiming().iterations === Infinity))).toBe(true);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await expect(spinner).toHaveCSS('animation-name', 'none');
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  await expect(stream.getByText('I will explore this project.', { exact: true })).toBeVisible();
  await expect(stream.getByText('Now I can check the remaining details.', { exact: true })).toBeVisible();
  await expect(tools).not.toHaveAttribute('open', '');
  await page.screenshot({ animations: 'disabled', path: testInfo.outputPath('minimal-working.png') });
  await tools.locator('summary').focus();
  await page.keyboard.press('Enter');
  await expect(tools.locator('.minimal-call-caption')).toHaveText([
    'Read the project manifest', 'Cannot read the second file', 'Check project details',
  ]);
  await expect(tools.locator('.minimal-call .tool-status').last()).toHaveAttribute('aria-label', 'Tool in progress');
  const originalTools = await tools.elementHandle();
  app.append('tool_result', {
    tool_call_id: 'script', tool_name: 'mbtx', content: 'OUTPUT_SENTINEL', is_error: false,
    brief: 'mbtx (exit=0)',
  });
  await expect(tools.locator('.minimal-call-caption').last()).toHaveText('Check project details');
  await expect(aggregate.locator('.tool-status-spinner')).toHaveCount(0);
  await expect(aggregate.locator('.minimal-failure-count')).toHaveCount(0);
  await expect(aggregate).not.toContainText(/tool calls? failed/);
  await expect(tools.locator('summary > .minimal-summary-text')).toHaveText('Read the project manifest · Cannot read the second file · Check project details');
  await expect(tools).toHaveAttribute('open', '');
  expect(await originalTools.evaluate(node => node.isConnected)).toBe(true);
  await page.screenshot({ animations: 'disabled', path: testInfo.outputPath('minimal-running.png') });

  app.append('user', { content: 'Please focus on the architecture.' });
  app.append('assistant', { content: 'I will focus on architecture.', tool_calls: [
    { id: 'unknown', name: 'mcp__example__inspect', arguments: '{broken' },
  ] });
  app.append('tool_result', {
    tool_call_id: 'unknown', tool_name: 'mcp__example__inspect', content: 'OUTPUT_SENTINEL', is_error: true,
  });
  app.append('assistant', { content: 'Here is the **final summary**.' }, 1700000000000);
  app.append('terminal', { kind: 'finished', message: 'Here is the **final summary**.' });

  const processes = stream.locator('.minimal-process');
  await expect(processes).toHaveCount(2);
  await expect(processes.nth(0).locator(':scope > summary > .minimal-summary-text')).toHaveText('Read the project manifest · Cannot read the second file · Check project details');
  await expect(processes.nth(1).locator(':scope > summary > .minimal-summary-text')).toHaveText('mcp__example__inspect');
  await expect(processes.nth(0).locator(':scope > summary .minimal-failure-count')).toHaveCount(0);
  await expect(processes.nth(1).locator(':scope > summary .minimal-failure-count')).toHaveCount(0);
  await expect(processes.nth(0).locator(':scope > summary')).not.toContainText(/tool calls? failed/);
  await expect(processes.nth(1).locator(':scope > summary')).not.toContainText(/tool calls? failed/);
  await expect(processes.nth(0).locator(':scope > summary').getByRole('img', { name: 'Tool failed' })).toBeVisible();
  await expect(processes.nth(1).locator(':scope > summary').getByRole('img', { name: 'Tool failed' })).toBeVisible();
  await expect(stream.getByText('I will explore this project.', { exact: true })).toBeHidden();
  await expect(stream.getByText('Please focus on the architecture.', { exact: true })).toBeVisible();
  await expect(stream.locator('.msg-content strong')).toHaveText('final summary');
  await expect(stream.getByRole('button', { name: 'Copy assistant message as Markdown', exact: true })).toHaveCount(1);
  // Minimal mode mirrors detailed mode's finish line: the confirmed final
  // answer carries its durable commit instant beside the copy action.
  await expect(stream.locator('.assistant-message-actions .assistant-message-time')).toHaveCount(1);
  await page.screenshot({ animations: 'disabled', path: testInfo.outputPath('minimal-completed.png') });
  for (const process of await processes.all()) {
    await process.locator(':scope > summary').click();
    for (const group of await process.locator('.minimal-tools').all()) {
      await group.locator('summary').click();
    }
  }
  await expect(processes.nth(0).locator('.minimal-tools > summary > .minimal-summary-text')).toHaveText(
    'Read the project manifest · Cannot read the second file · Check project details',
  );
  // Prose keeps the outer process, but its single call needs no inner fold.
  await expect(processes.nth(1).locator('.minimal-tools')).toHaveCount(0);
  await expect(processes.nth(1).locator('.minimal-call .tool-status.failed')).toHaveAttribute('aria-label', 'Tool failed');
  await expect(stream.locator('.minimal-call-caption').filter({ hasText: /^mcp__example__inspect$/ })).toBeVisible();
  await expect(stream).not.toContainText(/REASONING_SENTINEL|PARAMETER_SENTINEL|OUTPUT_SENTINEL|SCRIPT_SENTINEL/);
  await expect(stream.locator('.tool-call-tabs, .activity-thinking')).toHaveCount(0);
  expect(app.pageErrors).toEqual([]);
});

test('minimal transcript folds background notices into the surrounding tool activity', async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  app.sessionEvents.pop(); // Leave the tool group at the tail.
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const notice = 'background job bg-1 finished (exit=0): Run the issue tests';
  app.append('runtime_notice', { content: notice });
  app.append('assistant', { content: '', tool_calls: [
    { id: 'output', name: 'job_output', arguments: '{"description":"Read test results"}' },
  ] });
  const tools = page.locator('#stream .minimal-tools-live');
  await expect(tools).toHaveCount(1);
  await expect(tools.locator('summary')).toHaveCount(0);
  await expect(page.getByText(notice, { exact: true })).toBeVisible();
  await expect(tools.locator('.minimal-call-caption, .minimal-note')).toHaveText([
    'Read the project manifest', 'Cannot read the second file', 'Check project details',
    notice, 'Read test results',
  ]);
  app.append('terminal', { kind: 'finished', message: 'The tests passed.' });
  const process = page.locator('#stream .minimal-process');
  await expect(process).toHaveCount(1);
  await expect(page.getByText(notice, { exact: true })).toBeHidden();
  await expect(process.locator(':scope > summary .minimal-failure-count')).toHaveCount(0);
  await expect(process.locator(':scope > summary')).not.toContainText(/tool calls? failed/);
  await expect(process.locator(':scope > summary').getByRole('img', { name: 'Tool failed' })).toBeVisible();
  await expect(process.locator(':scope > summary')).not.toContainText(/Background activity|Read job output|Wait for jobs|Stop jobs/);
  await process.locator(':scope > summary').click();
  await process.locator('.minimal-tools > summary').click();
  await expect(page.getByText(notice, { exact: true })).toBeVisible();

  // A notice arriving between turns remains independently expandable, without
  // moving it before an already completed answer or presenting it as prose.
  const lateNotice = 'background job bg-2 finished (exit=0): Run remaining checks';
  app.append('runtime_notice', { content: lateNotice });
  await expect(page.locator('#stream > .minimal-messages > .minimal-tools')).toHaveCount(1);
  await expect(page.getByText(lateNotice, { exact: true })).toBeHidden();
  await page.locator('#stream > .minimal-messages > .minimal-tools > summary').click();
  await expect(page.getByText(lateNotice, { exact: true })).toBeVisible();
  expect(app.pageErrors).toEqual([]);
});

test('minimal transcript folds context summaries separately from final guidance', async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  await app.install();
  await app.goto();
  await app.enableMinimal();
  app.append('summary', {
    content: '# Handoff Summary\n\nKeep implementing the project.', from_sequence: 1, to_sequence: 6,
  });
  const checkpoint = page.locator('#stream > .minimal-messages > .minimal-context-summary');
  await expect(checkpoint).toHaveCount(1);
  await expect(checkpoint.locator('summary .minimal-summary-text')).toHaveText('Context summary');
  await expect(checkpoint.getByRole('heading', { name: 'Handoff Summary' })).toBeHidden();
  await checkpoint.locator(':scope > summary').click();
  const originalCheckpoint = await checkpoint.elementHandle();
  const guidance = '[context ceiling] Continue in a new turn.';
  app.append('terminal', { kind: 'finished', message: guidance });
  await expect(page.getByText(guidance, { exact: true })).toBeVisible();
  await expect(checkpoint).toHaveCount(1);
  await expect(page.locator('#stream > .minimal-messages > .minimal-process')).toHaveCount(1);
  expect(await originalCheckpoint.evaluate(node => node.isConnected)).toBe(true);
  await expect(checkpoint.getByRole('heading', { name: 'Handoff Summary' })).toBeVisible();
  await checkpoint.locator('summary').focus();
  await expect(checkpoint.getByText('Keep implementing the project.', { exact: true })).toBeVisible();
  await page.keyboard.press('Enter');
  await expect(checkpoint.getByRole('heading', { name: 'Handoff Summary' })).toBeHidden();

  // Some producers record their checkpoint after the terminal guidance.
  app.append('summary', { content: 'A later checkpoint.', from_sequence: 1, to_sequence: 8 });
  await expect(checkpoint).toHaveCount(2);
  await expect(page.getByText('A later checkpoint.', { exact: true })).toBeHidden();
  await expect(page.getByText(guidance, { exact: true })).toBeVisible();
  expect(app.pageErrors).toEqual([]);
});

test('minimal transcript retains stopped failed and empty-success processes across later completion', async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  app.sessionEvents = [
    { item: { kind: 'user', payload: { content: 'Show the browser fixture boundaries' } } },
    { item: { kind: 'assistant', payload: { content: 'Stopped process' } } },
    { item: { kind: 'terminal', payload: { kind: 'interrupted', message: '' } } },
    { item: { kind: 'user', payload: { content: 'Try again' } } },
    { item: { kind: 'assistant', payload: { content: 'Failed process' } } },
    { item: { kind: 'terminal', payload: { kind: 'failed', message: 'Connection failed' } } },
    { item: { kind: 'user', payload: { content: 'Try empty completion' } } },
    { item: { kind: 'assistant', payload: { content: 'Answerless process' } } },
    { item: { kind: 'terminal', payload: { kind: 'finished', message: '' } } },
    { item: { kind: 'user', payload: { content: 'A final attempt' } } },
    { item: { kind: 'assistant', payload: { content: 'Successful process' } } },
    { item: { kind: 'terminal', payload: { kind: 'finished', message: 'A real answer' } } },
    { item: { kind: 'user', payload: { content: 'One quick answer' } } },
    { item: { kind: 'terminal', payload: { kind: 'finished', message: 'Only a final answer' } } },
  ].map((event, index) => ({ ...event, sequence: index + 1 }));
  await app.install();
  await app.goto();
  await app.enableMinimal();
  const stream = page.locator('#stream');
  for (const text of ['Stopped process', 'Failed process', 'Answerless process', 'Connection failed', 'A real answer', 'Only a final answer']) {
    await expect(stream.getByText(text, { exact: true })).toBeVisible();
  }
  await expect(stream.getByText('Successful process', { exact: true })).toBeHidden();
  await expect(stream.locator('.minimal-process')).toHaveCount(1);
  await expect(stream.locator('.minimal-process > summary .minimal-summary-text')).toHaveText('Work completed');
  expect(app.pageErrors).toEqual([]);
});

test('minimal transcript is the default and detailed mode persists', async ({ page }) => {
  const app = new MinimalTranscriptHarness(page);
  await app.install();
  await app.goto();
  await app.enableMinimal();
  await expect(page.locator('.minimal-tools')).toHaveCount(1);
  await page.reload();
  await app.openSession();
  await expect(page.locator('.minimal-tools')).toHaveCount(1);
  const toggle = app.detailedMode();
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  await expect(toggle).not.toHaveClass(/active/);
  await expect(toggle.locator('svg')).toBeVisible();
  await expect(toggle.locator('svg')).toHaveAttribute('viewBox', '0 0 24 24');
  await toggle.click();
  await expect(toggle).toHaveAttribute('aria-pressed', 'true');
  await expect(toggle).toHaveClass(/active/);
  // A click must update the current transcript without reopening the task.
  await expect(page.locator('#stream .minimal-tools')).toHaveCount(0);
  await expect(page.locator('#stream details.tool-call').first()).toBeVisible();
  await app.openSession();
  await expect(page.locator('.minimal-tools')).toHaveCount(0);
  await expect(page.locator('#stream')).toContainText('REASONING_SENTINEL');
  await expect(page.locator('#stream details.tool-call').first()).toBeVisible();
  await page.reload();
  await app.openSession();
  await expect(page.locator('.minimal-tools')).toHaveCount(0);
  await expect(toggle).toHaveAttribute('aria-pressed', 'true');
  await toggle.focus();
  await page.keyboard.press('Space');
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  await app.openSession();
  await expect(page.locator('.minimal-tools')).toHaveCount(1);
  await page.reload();
  await app.openSession();
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  expect(app.pageErrors).toEqual([]);
});
