import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

test('Git history expands commits and opens an immutable historical diff', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();
  await app.openSession();
  await app.openReview();

  await expect.poll(() => app.requests.find(request => request.method === 'git.history'))
    .toMatchObject({
      params: {
        session: 'session-1',
        workspace: '/workspace',
      },
    });
  const history = page.getByRole('tree', { name: 'Git commit history', includeHidden: true });
  const head = history.getByRole('treeitem', { name: /Cover Desktop Git flows/ });
  const merge = history.getByRole('treeitem', { name: /Merge fixture lanes/ });
  const parent = history.getByRole('treeitem', { name: /Add Review surface/ });
  await head.focus();
  await page.keyboard.press('ArrowDown');
  await expect(merge).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(parent).toBeFocused();
  await page.keyboard.press('Home');
  await expect(head).toBeFocused();
  await page.keyboard.press('Enter');

  await expect.poll(() => app.requests.find(request =>
    request.method === 'git.commit_changes' && request.params?.commit === app.gitHead))
    .toMatchObject({
      params: {
        session: 'session-1',
        workspace: '/workspace',
        commit: app.gitHead,
      },
    });
  await expect(head).toHaveAttribute('aria-expanded', 'true');
  const historicalMain = history.getByRole('treeitem', { name: /src\/main\.mbt/, includeHidden: true });
  await historicalMain.click();
  await expect(history).toBeHidden();
  await expect(historicalMain).toHaveAttribute('aria-current', 'page');

  await expect.poll(() => app.requests.filter(request =>
    request.method === 'git.original_file' &&
    request.params?.path === 'src/main.mbt' &&
    [app.gitMerge, app.gitHead].includes(request.params?.revision)).length)
    .toBe(2);
  await expect(page.locator('.editor-tab.active')).toContainText('main.mbt (cccccccc)');
  const breadcrumb = page.locator('.history-breadcrumb');
  await expect(breadcrumb.locator('.history-commit-crumb')).toHaveText('cccccccc');
  await expect(breadcrumb.locator('.crumb-file')).toHaveText('src/main.mbt');
  const algorithms = page.getByRole('toolbar', { name: 'Comparison algorithm' });
  await expect(algorithms.getByRole('button', { name: 'Token diff' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await expect(algorithms.getByRole('button')).toHaveText(['Line', 'Token', 'Tree']);
  await expect(page.getByRole('button', { name: 'Ignore comments' })).toBeEnabled();
  await expect(page.getByRole('button', { name: 'Ignore tests' })).toBeEnabled();
  expect(app.pageErrors).toEqual([]);
});

test('Git history and commit failures retry through the browser transport', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  app.rpcErrors.set('git.history', 'unknown command');
  await app.install();
  await app.goto();
  await app.openSession();
  await app.openReview({ waitForHistory: false });

  await expect(page.getByText(/Could not load Git history:.*unknown command/)).toBeVisible();
  app.rpcErrors.delete('git.history');
  await page.getByRole('button', { name: 'Retry' }).click();
  const history = page.getByRole('tree', { name: 'Git commit history' });
  const head = history.getByRole('treeitem', { name: /Cover Desktop Git flows/ });
  await expect(head).toBeVisible();
  await expect.poll(() => app.requests.filter(request =>
    request.method === 'git.history').length).toBe(2);

  app.rpcErrors.set('git.commit_changes', 'object unavailable');
  await head.click();
  const commitFailure = page.locator('.git-commit-files-message.error');
  await expect(commitFailure).toContainText(
    'Could not load this commit: object unavailable.',
  );
  app.rpcErrors.delete('git.commit_changes');
  await commitFailure.getByRole('button', { name: 'Retry' }).click();
  await expect(
    history.getByRole('treeitem', { name: /src\/main\.mbt/ }),
  ).toBeVisible();
  await expect.poll(() => app.requests.filter(request =>
    request.method === 'git.commit_changes').length).toBe(2);
  expect(app.pageErrors).toEqual([]);
});
