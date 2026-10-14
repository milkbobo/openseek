import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

class CodexMinimalHarness extends DesktopBrowserHarness {
  constructor(page, extraItems = []) {
    super(page);
    this.extraItems = extraItems;
  }

  replyFor(request) {
    if (request.method === 'codex.turn.start') {
      return { turn: { id: 'codex-turn-e2e', status: 'completed', items: [
        { id: 'user', type: 'userMessage', content: [{ type: 'text', text: 'Explain the project' }] },
        { id: 'thought', type: 'reasoning', summary: [{ type: 'summary_text', text: 'HIDDEN_CODEX_REASONING' }] },
        { id: 'progress', type: 'agentMessage', phase: 'commentary', text: 'I will inspect the project.' },
        { id: 'command', type: 'commandExecution', command: 'HIDDEN_CODEX_COMMAND', status: 'completed', aggregatedOutput: 'HIDDEN_CODEX_OUTPUT', exitCode: 0 },
        { id: 'spawn', type: 'collabAgentToolCall', tool: 'spawnAgent', status: 'completed' },
        ...this.extraItems,
        { id: 'answer', type: 'agentMessage', phase: 'final_answer', text: 'The project is a desktop assistant.' },
      ] } };
    }
    return super.replyFor(request);
  }
}

test('detail toggle stays enabled when a Codex draft gains its working directory', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  app.codexModels = [{
    id: 'gpt-5.4-codex', displayName: 'GPT-5.4 Codex', isDefault: true,
    defaultReasoningEffort: 'medium',
    supportedReasoningEfforts: [{ reasoningEffort: 'medium', description: 'Balanced' }],
  }];
  // Keep the initial directory-less header visible before the draft reply
  // inserts its workspace label ahead of the buttons.
  app.rpcDelays.set('codex.draft.open', 1000);
  await app.install();
  await app.goto();
  await page.getByRole('button', { name: 'Model', exact: true }).click();
  await page.getByRole('option', { name: 'GPT-5.4 Codex' }).click();
  const terminal = page.getByTitle('Terminal requires an available Codex task placement', { exact: true });
  await expect(terminal).toBeDisabled();
  await expect(page.locator('.codex-topbar .topbar-workspace')).toBeVisible();
  const toggle = page.getByRole('button', { name: 'Detailed mode', exact: true });
  await expect(toggle).toBeEnabled();
  await toggle.click();
  await expect(toggle).toHaveAttribute('aria-pressed', 'true');
  await toggle.click();
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  expect(app.pageErrors).toEqual([]);
});

test('minimal transcript also collapses Codex final replies and recognizes subagent operations', async ({ page }) => {
  const app = new CodexMinimalHarness(page);
  app.codexModels = [{
    id: 'gpt-5.4-codex', displayName: 'GPT-5.4 Codex', isDefault: true,
    defaultReasoningEffort: 'medium',
    supportedReasoningEfforts: [{ reasoningEffort: 'medium', description: 'Balanced' }],
  }];
  await app.install();
  await app.goto();
  await page.getByRole('button', { name: 'Model', exact: true }).click();
  await page.getByRole('option', { name: 'GPT-5.4 Codex' }).click();
  // The model chip updates before the Codex composer replaces SeekMoon's.
  // Wait for the destination textbox rather than filling the shared old #task.
  await page.getByRole('textbox', { name: 'Ask Codex to inspect, edit, or explain this workspace.', exact: true }).fill('Explain the project');
  await page.getByTitle('Send', { exact: true }).click();
  const stream = page.locator('#stream');
  const process = stream.locator('.minimal-process');
  await expect(process).toHaveCount(1);
  await expect(process.locator(':scope > summary > .minimal-summary-text')).toHaveText('shell · Create subagent');
  await expect(stream.getByText('The project is a desktop assistant.', { exact: true })).toBeVisible();
  await expect(stream.getByText('I will inspect the project.', { exact: true })).toBeHidden();
  await process.locator(':scope > summary').click();
  await process.locator('.minimal-tools > summary').click();
  await expect(process.locator('.minimal-call-caption')).toHaveText(['shell', 'Create subagent']);
  await expect(stream).not.toContainText(/HIDDEN_CODEX_REASONING|HIDDEN_CODEX_OUTPUT|HIDDEN_CODEX_COMMAND/);
  // One preference serves both conversation sources.
  const toggle = page.getByRole('button', { name: 'Detailed mode', exact: true });
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  await toggle.click();
  await expect(toggle).toHaveAttribute('aria-pressed', 'true');
  // A click must update the current transcript without reopening the task.
  await expect(stream.locator('.minimal-process, .minimal-tools')).toHaveCount(0);
  await expect(stream.locator('details.tool-call').first()).toBeVisible();
  await app.openSession();
  await expect(page.locator('#stream .minimal-process, #stream .minimal-tools')).toHaveCount(0);
  await expect(page.locator('#stream details.tool-call').first()).toBeVisible();
  expect(app.pageErrors).toEqual([]);
});

test('minimal Codex activities render recorded patches without classifying foreign tools as edits', async ({ page }) => {
  const patch = 'diff --git a/main.mbt b/main.mbt\nindex abc..def 100644\n--- a/main.mbt\n+++ b/main.mbt\n@@ -1,2 +1,2 @@\n context\n-old\n\\ No newline at end of file\n+++ new\n\\ No newline at end of file';
  const app = new CodexMinimalHarness(page, [
    { id: 'edit', type: 'fileChange', status: 'completed', changes: [
      { path: 'src/main.mbt', kind: { type: 'update', move_path: null }, diff: patch },
    ] },
    { id: 'send', type: 'collabAgentToolCall', tool: 'sendMessage', status: 'completed' },
    { id: 'image', type: 'imageGeneration', status: 'completed' },
    { id: 'review', type: 'enteredReviewMode', review: 'Review current edits' },
    { id: 'dynamic', type: 'dynamicToolCall', namespace: 'example', tool: 'edit', status: 'completed', success: false,
      arguments: { changes: [{ path: 'FOREIGN_PATCH_SENTINEL', diff: patch }] } },
  ]);
  app.codexModels = [{ id: 'gpt-5.4-codex', displayName: 'GPT-5.4 Codex', isDefault: true,
    defaultReasoningEffort: 'medium', supportedReasoningEfforts: [{ reasoningEffort: 'medium', description: 'Balanced' }] }];
  await app.install();
  await app.goto();
  await page.getByRole('button', { name: 'Model', exact: true }).click();
  await page.getByRole('option', { name: 'GPT-5.4 Codex' }).click();
  // The model chip updates before the Codex composer replaces SeekMoon's.
  // Wait for the destination textbox rather than filling the shared old #task.
  await page.getByRole('textbox', { name: 'Ask Codex to inspect, edit, or explain this workspace.', exact: true }).fill('Explain the project');
  await page.getByTitle('Send', { exact: true }).click();
  const process = page.locator('#stream .minimal-process');
  await expect(process.locator(':scope > summary > .minimal-summary-text')).toHaveText('shell · Create subagent · Changed files · …');
  await expect(process.locator('.editor-diff-preview')).toBeHidden();
  await process.locator(':scope > summary').click();
  const diff = process.locator('.editor-diff-preview');
  await expect(diff).toBeHidden();
  await process.locator('.minimal-tools').filter({ has: page.locator('.editor-diff-preview') }).locator(':scope > summary').click();
  await expect(diff).toBeVisible();
  await expect(diff).toHaveCount(1);
  await expect(diff.locator('.removed .editor-diff-source')).toHaveText(['old']);
  await expect(diff.locator('.added .editor-diff-source')).toHaveText(['++ new']);
  await expect(diff.locator('.context .editor-diff-source')).toHaveText(['context']);
  await expect(diff.locator('.editor-diff-row.gap')).toHaveCount(0);
  await expect(diff.locator('.editor-diff-row')).toHaveCount(3);
  await expect(process.locator('.edit-path')).toHaveText('src/main.mbt');
  await expect(process.locator('.minimal-call-caption').last()).toHaveText('dynamic__example__edit');
  await expect(process.locator('.minimal-call .tool-status.failed')).toHaveAttribute('aria-label', 'Tool failed');
  await expect(process).not.toContainText('FOREIGN_PATCH_SENTINEL');
  expect(app.pageErrors).toEqual([]);
});
