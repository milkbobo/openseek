import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

test('approval card mirrors host claims and sends an unclaimed decision', async ({ page }, testInfo) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();
  await app.openSession();

  app.notify('agent.started', {
    run_id: 'run-1',
    session: 'session-1',
    session_root: '/workspace/.openseek',
    model: 'deepseek-v4-pro',
    max_steps: 1000,
  });
  const pending = {
    run_id: 'run-1', session: 'session-1', answered: false,
    id: 'approval-1', tool_name: 'mbtx',
    detail: 'run this snippet with no sandbox policy',
    body: 'fn main { @myshell.Cmd("npm", ["ci"]) }',
  };
  app.notify('agent.approvals', { generation: 1, approvals: [pending] });

  const approval = page.locator('.composer-approval');
  await expect(approval).toBeVisible();
  await approval.screenshot({ path: testInfo.outputPath('approval-awaiting-answer.png') });
  // A different client answered: this page must stop offering either decision.
  app.notify('agent.approvals', { generation: 2, approvals: [{ ...pending, answered: true }] });
  await expect(approval.locator('.composer-approval-state')).toBeVisible();
  await expect(approval.getByRole('button')).toHaveCount(0);
  await approval.screenshot({ path: testInfo.outputPath('approval-answer-submitted.png') });
  app.notify('agent.approvals', { generation: 3, approvals: [] });
  await expect(approval).toHaveCount(0);

  // A subsequent, unclaimed question is still answerable through the bridge.
  app.notify('agent.approvals', { generation: 4, approvals: [{ ...pending, id: 'approval-2' }] });
  await approval.getByRole('button', { name: 'Allow once' }).click();
  await expect.poll(() => app.requests.some(request =>
    request.method === 'agent.approval' &&
    request.params?.run_id === 'run-1' &&
    request.params?.id === 'approval-2' &&
    request.params?.allow === true)).toBe(true);
  await expect(approval.locator('.composer-approval-state')).toBeVisible();
  expect(app.pageErrors).toEqual([]);
});

test('composer sends a turn and stops the accepted run', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();
  await app.openSession();

  const composer = page.locator('#task');
  await composer.fill('Run the browser E2E turn');
  await page.getByTitle('Send', { exact: true }).click();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'agent.start'))
    .toMatchObject({
      params: {
        task: 'Run the browser E2E turn',
        session: 'session-1',
      },
    });

  await composer.fill('Steer without losing the interrupt control');
  await expect(page.getByTitle('Stop', { exact: true })).toBeVisible();
  await expect(page.getByTitle('Steer the running task', { exact: true })).toBeVisible();
  await page.getByTitle('Stop', { exact: true }).click();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'agent.cancel'))
    .toMatchObject({ params: { run_id: 'run-e2e' } });
  expect(app.pageErrors).toEqual([]);
});

test('Codex creates a thread, sends its first turn, and stops it', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  app.codexModels = [
    {
      id: 'gpt-5.4-codex',
      displayName: 'GPT-5.4 Codex',
      isDefault: true,
      defaultReasoningEffort: 'medium',
      supportedReasoningEfforts: [
        { reasoningEffort: 'medium', description: 'Balanced' },
      ],
    },
  ];
  await app.install();
  await app.goto();

  // A model pick is the product's hand-off from a fresh OpenSeek draft to a
  // Codex draft. The rest of the test exercises the ordinary composer path.
  await page.getByRole('button', { name: 'Model', exact: true }).click();
  await page.getByRole('option', { name: 'GPT-5.4 Codex' }).click();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'codex.draft.open'))
    .toMatchObject({ params: { cwd: '/workspace' } });

  // The request leaves in the same update that selects the Codex draft, a
  // frame before the Codex composer replaces SeekMoon's in the shared #task.
  // Wait for the destination textbox rather than filling the old one.
  await page.getByRole('textbox', {
    name: 'Ask Codex to inspect, edit, or explain this workspace.',
    exact: true,
  }).fill('Run the Codex browser E2E turn');
  await page.getByTitle('Send', { exact: true }).click();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'codex.thread.start'))
    .toMatchObject({
      params: {
        cwd: '/workspace',
        model: 'gpt-5.4-codex',
      },
    });
  await expect.poll(() => app.requests.find(request =>
    request.method === 'codex.turn.start'))
    .toMatchObject({
      params: {
        threadId: 'codex-thread-e2e',
        input: [{ type: 'text', text: 'Run the Codex browser E2E turn' }],
      },
    });

  await page.getByTitle('Stop', { exact: true }).click();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'codex.turn.interrupt'))
    .toMatchObject({
      params: {
        threadId: 'codex-thread-e2e',
        turnId: 'codex-turn-e2e',
      },
    });
  expect(app.pageErrors).toEqual([]);
});

test('composer selects queue for one message and preserves queued controls', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();
  await app.openSession();
  const composer = page.locator('#task');
  await composer.fill('Start a turn');
  await page.getByTitle('Send', { exact: true }).click();
  const choice = page.getByRole('button', { name: 'Follow-up action', exact: true });
  await expect(choice).toContainText('Steer now');
  await composer.fill('Do this after the turn');
  await choice.click();
  await page.getByRole('option', { name: 'Queue next', exact: true }).click();
  await expect(choice).toContainText('Queue next');
  await expect(page.getByTitle('Queue for the next turn', { exact: true })).toBeVisible();
  await composer.press('Enter');
  await expect.poll(() => app.requests.find(r => r.method === 'agent.queue'))
    .toMatchObject({ params: { action: 'add', text: 'Do this after the turn', run_id: 'run-e2e' } });
  await expect(choice).toContainText('Steer now');
  const queued = page.locator('.queued-input-row');
  await expect(queued).toContainText('Do this after the turn');
  await queued.getByTitle('Edit', { exact: true }).click();
  await expect(choice).toBeHidden();
  await composer.fill('Edited follow-up');
  app.rpcErrors.set('agent.queue', 'Queue edit rejected');
  await page.getByTitle('Save queued message', { exact: true }).click();
  await expect(page.getByText('Queue action failed: Queue edit rejected', { exact: false }).first()).toBeVisible();
  await expect(composer).toHaveValue('Edited follow-up');
  await expect(queued).toContainText('Do this after the turn');
  app.rpcErrors.delete('agent.queue');
  await page.getByTitle('Save queued message', { exact: true }).click();
  await expect(queued).toContainText('Edited follow-up');
  await expect(choice).toContainText('Steer now');
  await expect(composer).toHaveValue('');
  await queued.getByTitle('Delete', { exact: true }).click();
  await expect(queued).toHaveCount(0);
  await composer.fill('An immediate correction');
  await page.getByTitle('Steer the running task', { exact: true }).click();
  await expect.poll(() => app.requests.find(r => r.method === 'agent.steer'))
    .toMatchObject({ params: { text: 'An immediate correction', run_id: 'run-e2e' } });
  expect(app.requests.filter(r => r.method === 'settings.set')).toEqual([]);
  expect(app.pageErrors).toEqual([]);
});

test('composer follow-up menu supports keyboard choice and a queue default', async ({ page }, testInfo) => {
  const app = new DesktopBrowserHarness(page);
  app.hostSettings.followup_behavior = 'queue';
  await app.install();
  await app.goto();
  await app.openSession();
  const composer = page.locator('#task');
  await composer.fill('Start a turn');
  await page.getByTitle('Send', { exact: true }).click();
  const choice = page.getByRole('button', { name: 'Follow-up action', exact: true });
  await expect(choice).toContainText('Queue next');
  await composer.fill('Correct the current turn');
  await choice.focus();
  await choice.press('ArrowDown');
  await expect(page.getByRole('option', { name: /Queue next/ })).toBeFocused();
  await expect(page.getByRole('listbox', { name: 'Follow-up action' })).toBeVisible();
  await page.keyboard.press('Home');
  await expect(page.getByRole('option', { name: 'Steer now', exact: true })).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(choice).toContainText('Steer now');
  await composer.press('Enter');
  await expect.poll(() => app.requests.find(r => r.method === 'agent.steer'))
    .toMatchObject({ params: { text: 'Correct the current turn' } });
  await expect(choice).toContainText('Queue next');
  await page.setViewportSize({ width: 800, height: 800 });
  await composer.fill('A queued follow-up');
  await choice.click();
  const menu = page.getByRole('listbox', { name: 'Follow-up action' });
  await expect(menu).toBeVisible();
  const box = await menu.boundingBox();
  expect(box.x).toBeGreaterThanOrEqual(0);
  expect(box.x + box.width).toBeLessThanOrEqual(800);
  await page.screenshot({ path: testInfo.outputPath('followup-menu.png') });
  await page.keyboard.press('Escape');
  await expect(menu).toBeHidden();
  await expect(choice).toBeFocused();
  expect(app.requests.filter(r => r.method === 'settings.set')).toEqual([]);
  expect(app.pageErrors).toEqual([]);
});
