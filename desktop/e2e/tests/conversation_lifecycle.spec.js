import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';
import { sidebarAddProject } from './support/sidebar.js';

test('new chat materializes on send, and archive and restore update the sidebar', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();

  const project = page.locator('.workspace-row', { hasText: 'workspace' });
  await project.hover();
  const newConversation = project.getByTitle('New conversation in this project');
  const addProject = await sidebarAddProject(page);
  const iconPaths = button => button.locator('svg path').evaluateAll(paths =>
    paths.map(path => path.getAttribute('d')),
  );
  // `evaluateAll` does not wait and returns [] for a locator that matches
  // nothing, so require both icons before comparing them.
  const newConversationIcon = await iconPaths(newConversation);
  const addProjectIcon = await iconPaths(addProject);
  expect(newConversationIcon).not.toEqual([]);
  expect(addProjectIcon).not.toEqual([]);
  expect(newConversationIcon).not.toEqual(addProjectIcon);

  await newConversation.click();
  await expect(project).toHaveClass(/\bactive\b/);
  await expect(page.locator('.conversation-row', { hasText: 'New chat' })).toHaveCount(0);
  await expect(page.locator('.empty-title')).toHaveText('What should we build in workspace?');
  await expect(page.locator('#task')).toHaveValue('');

  const firstPrompt = 'Explain the sidebar state';
  await page.locator('#task').fill(firstPrompt);
  await page.getByTitle('Send', { exact: true }).click();
  await expect(page.locator('.conversation-row.active')).toHaveCount(1);
  await expect(page.locator('.conversation-row', { hasText: 'New chat' })).toHaveCount(0);

  await page.getByText('Rabbita browser fixture', { exact: true }).first().click();
  const liveRow = page.locator('.conversation-row[title="session-1"]');
  await liveRow.hover();
  await liveRow.getByRole('button', { name: 'Conversation actions' }).click();
  await page.getByRole('menuitem', { name: 'Archive' }).click();
  await expect.poll(() => app.requests.some(request =>
    request.method === 'session.archive' &&
    request.params?.session === 'session-1')).toBe(true);

  const archivedHeading = page.locator('.section-heading', {
    hasText: 'Archived chats (1)',
  });
  await archivedHeading.click();
  const archivedRow = page.locator('.conversation-row[title="session-1"]');
  await expect(archivedRow).toBeVisible();
  await archivedRow.click();
  await expect(page.getByText('Archived conversation · Read only')).toBeVisible();
  await archivedRow.hover();
  await archivedRow.getByTitle('Restore this conversation to the sidebar').click();
  await expect.poll(() => app.requests.some(request =>
    request.method === 'session.unarchive' &&
    request.params?.session === 'session-1')).toBe(true);
  await expect(page.getByText('Rabbita browser fixture', { exact: true }).first()).toBeVisible();
  expect(app.pageErrors).toEqual([]);
});

test('archiving a selected chat restores the existing project draft', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();

  const workspace = page.locator('.workspace-row', { hasText: 'workspace' });
  await workspace.hover();
  await page.getByTitle('New conversation in this project').click();
  const newChat = page.locator('.conversation-row', { hasText: 'New chat' });
  await expect(newChat).toHaveCount(0);
  await expect(workspace).toHaveClass(/\bactive\b/);
  await page.locator('#task').fill('Keep this draft');

  const stored = page.locator('.conversation-row[title="session-1"]');
  await stored.click();
  await expect(newChat).toHaveCount(1);
  await expect(newChat).not.toHaveClass(/\bactive\b/);
  await expect(page.getByText('Browser result', { exact: true })).toBeVisible();
  await page.locator('#task').fill('Discard this archived draft');
  await stored.click({ button: 'right', position: { x: 18, y: 18 } });
  await page.getByRole('menuitem', { name: 'Archive' }).click();

  await expect.poll(() => app.requests.some(request =>
    request.method === 'session.archive' &&
    request.params?.session === 'session-1')).toBe(true);
  await expect(newChat).toHaveCount(0);
  await expect(workspace).toHaveClass(/\bactive\b/);
  await expect(page.locator('#task')).toHaveValue('Keep this draft');
  expect(app.pageErrors).toEqual([]);
});

test('removing a pending selection exits its loading state', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  app.liveSessions.push({
    id: 'session-2',
    title: 'Second browser fixture',
    updated_at_ms: 2,
  });
  await app.install();
  await app.goto();

  app.rpcDelays.set('session.load', 10000);
  const pending = page.locator('.conversation-row[title="session-2"]');
  await pending.click();
  await expect(pending).toHaveClass(/active/);
  await expect(page.getByText('Loading conversation…', { exact: true })).toBeVisible();
  await pending.click({ button: 'right', position: { x: 18, y: 18 } });
  await expect(page.getByRole('menu', { name: 'Conversation actions' })).toBeVisible();

  app.liveSessions = app.liveSessions.filter(session => session.id !== 'session-2');
  app.archivedSessions.push({
    id: 'session-2',
    title: 'Second browser fixture',
    updated_at_ms: 2,
  });
  app.notify('session.changed', {
    change: 'archived',
    session: 'session-2',
    workspace: '/workspace',
  });

  await expect(page.getByRole('menu')).toHaveCount(0);
  await expect(page.getByText('Loading conversation…', { exact: true })).toHaveCount(0);
  await expect(page.locator('#task')).toBeVisible();
  await expect(page.locator('.conversation-row', { hasText: 'New chat' })).toHaveCount(0);
  await expect(page.locator('.workspace-row', { hasText: 'workspace' })).toHaveClass(/\bactive\b/);
  await expect(page.locator('.empty-title')).toHaveText('What should we build in workspace?');
  expect(app.pageErrors).toEqual([]);
});

test('a failed first conversation load keeps selection and can retry', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  app.rpcErrors.set('session.load', 'fixture unavailable');
  await app.install();
  await app.goto();

  const row = page.locator('.conversation-row[title="session-1"]');
  await row.click();
  await expect(row).toHaveClass(/active/);
  await expect(page.getByText('Could not load conversation', { exact: true })).toBeVisible();
  await expect(page.getByText(/fixture unavailable/).last()).toBeVisible();
  await expect(row).toHaveClass(/load-failed/);

  app.rpcErrors.delete('session.load');
  await page.getByRole('button', { name: 'Retry' }).click();
  await expect(page.getByText('Browser result', { exact: true })).toBeVisible();
  await expect(row).toHaveClass(/active/);
  await expect(row).not.toHaveClass(/load-failed/);
  expect(app.pageErrors).toEqual([]);
});
