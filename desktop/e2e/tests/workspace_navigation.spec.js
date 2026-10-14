import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

test('workspace search supports toggles and keyboard navigation', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();
  // The query field is rendered once the project's checkout is known, and the
  // shortcut focuses it only once. Pressed earlier, the panel keeps the focus
  // and the field that appears later is left unfocused. The composer offers a
  // retry for the worktree list for as long as the checkout is unknown.
  await expect(page.getByRole('complementary').getByRole('button', { name: 'workspace', exact: true })).toBeVisible();
  await expect(page.getByTitle("Request this workspace's worktree list again", { exact: true })).toBeHidden();

  const shortcut = await page.evaluate(() =>
    navigator.platform.includes('Mac') ? 'Meta+Shift+F' : 'Control+Shift+F');
  await page.keyboard.press(shortcut);

  const tabs = page.getByRole('tablist', { name: 'Explorer views' });
  const filesTab = tabs.getByRole('tab', { name: 'Files' });
  const searchTab = tabs.getByRole('tab', { name: 'Search' });
  await expect(searchTab).toHaveAttribute('aria-selected', 'true');
  // Icon-only tabs keep their existing accessible names and native tooltips.
  for (const [name, title] of [
    ['Files', 'Workspace files'],
    ['Changes', 'Changed files (click again to refresh)'],
    ['Search', 'Search across the workspace'],
  ]) {
    const tab = tabs.getByRole('tab', { name: new RegExp('^' + name) });
    await expect(tab).toHaveAttribute('title', title);
    await expect(tab.locator('.icon')).toHaveAttribute('aria-hidden', 'true');
    await expect(tab.locator('.icon svg')).toHaveAttribute('fill', 'currentColor');
    await expect(tab.locator('.visually-hidden')).toHaveText(name);
  }

  const query = page.getByRole('textbox', { name: 'Search' });
  await expect(query).toBeFocused();

  const wholeWord = page.getByRole('button', { name: 'Match Whole Word' });
  await expect(wholeWord).toHaveAttribute('aria-pressed', 'false');
  await wholeWord.click();
  await expect(wholeWord).toHaveAttribute('aria-pressed', 'true');

  await searchTab.focus();
  await page.keyboard.press('ArrowRight');
  await expect(filesTab).toBeFocused();
  await expect(filesTab).toHaveAttribute('aria-selected', 'true');
  await page.keyboard.press('End');
  await expect(searchTab).toHaveAttribute('aria-selected', 'true');
  await expect(query).toBeFocused();
  expect(app.pageErrors).toEqual([]);
});

test('quick open moves its keyboard selection and opens the chosen file', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();
  await app.openSession();
  await app.openQuickOpen();
  const input = page.getByRole('combobox', { name: 'Search workspace files' });
  await expect(input).toBeFocused();
  const mainResult = page.getByRole('option', { name: /main\.mbt/ });
  const readmeResult = page.getByRole('option', { name: /README\.md/ });
  await expect(mainResult).toBeVisible();
  await expect(readmeResult).toBeVisible();
  await expect(mainResult).toHaveAttribute('aria-selected', 'true');
  await input.press('ArrowDown');
  await expect(readmeResult).toHaveAttribute('aria-selected', 'true');
  await input.press('ArrowUp');
  await expect(mainResult).toHaveAttribute('aria-selected', 'true');
  await input.press('Enter');

  await expect(input).toBeHidden();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'fs.read_file' &&
    request.params?.path === '/workspace/src/main.mbt')).toBeTruthy();
  expect(app.pageErrors).toEqual([]);
});

test('tab strip closes every tab type into the New Tab launcher', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();
  await app.openSession();

  await app.openQuickOpen();
  await page.getByRole('option', { name: /main\.mbt/ }).click();
  await app.openQuickOpen();
  await page.locator('#quick-open-input').fill('README');
  await page.getByRole('option', { name: /README\.md/ }).click();

  const fileTabs = page.locator('.editor-tab');
  await expect(fileTabs).toHaveCount(2);
  await fileTabs.filter({ hasText: 'main.mbt' }).click();
  await expect(fileTabs.filter({ hasText: 'main.mbt' })).toHaveClass(/active/);
  await app.openReview();
  await expect(fileTabs).toHaveCount(3);
  const closeAll = page.getByRole('button', { name: 'Close all tabs' });
  await expect(closeAll).toBeEnabled();
  await closeAll.click();
  await expect(fileTabs).toHaveCount(0);
  await expect(page.locator('.dock-launcher')).toBeVisible();
  await expect(closeAll).toBeDisabled();
  expect(app.pageErrors).toEqual([]);
});

test('file breadcrumbs browse cached directories with keyboard navigation', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  app.directoryEntries['/workspace/src'] = [
    { name: 'docs', is_dir: true },
    { name: 'main.mbt', is_dir: false },
  ];
  app.directoryEntries['/workspace/src/docs'] = [];
  await app.install();
  await app.goto();
  await app.openSession();
  await app.openQuickOpen();
  await page.locator('#quick-open-input').fill('main');
  await page.getByRole('option', { name: /main\.mbt/ }).click();

  const breadcrumb = page.locator('.viewer-breadcrumb');
  const sourceDirectory = breadcrumb.getByTitle('Show files in src');
  await sourceDirectory.click();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'fs.read_directory' && request.params?.path === '/workspace/src'))
    .toBeTruthy();
  const menu = page.getByRole('menu', { name: 'Files in src' });
  await expect(menu.getByRole('menuitem').last()).toHaveAttribute('aria-current', 'page');
  await expect(menu.getByRole('menuitem').first()).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(menu.getByRole('menuitem').last()).toBeFocused();
  await page.keyboard.press('Home');
  await expect(menu.getByRole('menuitem').first()).toBeFocused();
  await page.keyboard.press('ArrowRight');

  await expect.poll(() => app.requests.find(request =>
    request.method === 'fs.read_directory' &&
    request.params?.path === '/workspace/src/docs'))
    .toBeTruthy();
  const nested = page.getByRole('menu', { name: 'Files in docs' });
  await expect(nested).toContainText('This folder is empty.');
  expect(app.pageErrors).toEqual([]);
});
