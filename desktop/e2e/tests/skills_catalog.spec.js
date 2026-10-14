import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

test('skills installs a catalog entry and refreshes the installed library', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();

  await page.getByRole('button', { name: 'Skills', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Skills' })).toBeVisible();
  const registry = page.locator('.settings-group').filter({
    has: page.getByRole('heading', { name: 'Mooncakes registry' }),
  });
  const rabbita = registry.locator('.skill-row').filter({ hasText: /Rabbita/i });
  await rabbita.getByRole('button', { name: 'Install' }).click();
  await expect.poll(() => app.requests.some(request =>
    request.method === 'skills.install' &&
    request.params?.module_name === 'rabbita')).toBe(true);

  const installed = page.locator('.settings-group').filter({
    has: page.getByRole('heading', { name: 'Installed' }),
  });
  await expect(installed.locator('.skill-row').filter({ hasText: 'Rabbita' })).toBeVisible();
  await expect(rabbita).toContainText('Installed');
  expect(app.pageErrors).toEqual([]);
});

test('skills search, detail navigation, and hand-written protections use the mounted page', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();
  await page.getByRole('button', { name: 'Skills', exact: true }).click();

  const search = page.locator('.skills-search input');
  await search.fill('rabbita');
  const installed = page.locator('.settings-group').filter({
    has: page.getByRole('heading', { name: 'Installed' }),
  });
  const registry = page.locator('.settings-group').filter({
    has: page.getByRole('heading', { name: 'Mooncakes registry' }),
  });
  await expect(installed).toContainText('No installed skill matches the search.');
  await expect(registry.locator('.skill-row')).toContainText('rabbita');
  await expect(registry.locator('.skill-row')).toHaveCount(1);

  await search.fill('');
  const moonbit = installed.locator('.skill-row').filter({ hasText: 'MoonBit' });
  await expect(moonbit.getByRole('button', { name: 'Uninstall' })).toHaveCount(0);

  const rabbita = registry.locator('.skill-row').filter({ hasText: 'rabbita' });
  await rabbita.locator('.skill-summary').click();
  await expect(page.getByRole('button', { name: '← Back to skills' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'rabbita', exact: true })).toBeVisible();
  await page.getByRole('button', { name: '← Back to skills' }).click();

  await installed.locator('.skill-row').filter({ hasText: 'MoonBit' })
    .locator('.skill-summary').click();
  await expect(page.getByRole('button', { name: 'Uninstall' })).toHaveCount(0);
  expect(app.pageErrors).toEqual([]);
});
