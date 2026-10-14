import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

test('settings change and preserve the visible font size', async ({ page }, testInfo) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();

  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  const fontSize = page.getByRole('slider', { name: 'Font size' });
  await expect(fontSize).toHaveValue('14');
  await expect(fontSize).toHaveAttribute('list', 'font-size-ticks');
  expect(await page.locator('#font-size-ticks option').evaluateAll(options =>
    options.map(option => option.value))).toEqual(['12', '13', '14', '15', '16', '17', '18']);
  await page.locator('.setting-row').filter({ has: fontSize }).screenshot({
    path: testInfo.outputPath('font-slider-ticks.png'),
  });
  await fontSize.focus();
  await fontSize.press('ArrowRight');
  await expect(fontSize).toHaveValue('15');
  await expect(fontSize).toHaveAttribute('aria-valuetext', '15px');
  await expect(page.locator('.setting-font-size-value')).toHaveText('15px');
  await fontSize.press('Home');
  await expect(fontSize).toHaveValue('12');
  await expect.poll(() => page.evaluate(() =>
    getComputedStyle(document.body).fontSize))
    .toBe('12px');

  await fontSize.fill('18');
  await expect.poll(() => page.evaluate(() =>
    getComputedStyle(document.body).fontSize))
    .toBe('18px');
  await page.reload();
  await page.getByRole('main').waitFor();
  await expect.poll(() => page.evaluate(() =>
    getComputedStyle(document.body).fontSize))
    .toBe('18px');
  expect(app.pageErrors).toEqual([]);
});

test('a covering modal dismisses an open custom select', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();

  const model = page.getByRole('button', { name: 'Model', exact: true });
  await model.click();
  await expect(page.getByRole('listbox', { name: 'Model' })).toBeVisible();
  app.notify('settings.changed', {
    ...app.hostSettings,
    revision: app.hostSettings.revision + 1,
    has_deepseek_key: false,
  });
  await expect(page.getByText('Set up your DeepSeek API key')).toBeVisible();
  await expect(page.getByRole('listbox', { name: 'Model' })).toHaveCount(0);
  await expect(model).toHaveAttribute('aria-expanded', 'false');
  expect(app.pageErrors).toEqual([]);
});

test('a bottom select flips above and yields to the narrow sidebar', async ({ page }) => {
  await page.setViewportSize({ width: 500, height: 320 });
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();

  const trigger = page.getByRole('button', { name: 'Model', exact: true });
  await trigger.click();
  const menu = page.getByRole('listbox', { name: 'Model' });
  await expect(menu).toBeVisible();
  const geometry = await page.evaluate(() => {
    const triggerRect = document.querySelector('#openseek-model-picker').getBoundingClientRect();
    const menu = document.querySelector('#openseek-model-picker-menu');
    const menuRect = menu.getBoundingClientRect();
    return {
      above: menuRect.bottom <= triggerRect.top,
      insideViewport: menuRect.top >= 0 && menuRect.bottom <= innerHeight,
      fullyExpanded: menu.clientHeight === menu.scrollHeight,
    };
  });
  expect(geometry).toEqual({
    above: true,
    insideViewport: true,
    fullyExpanded: true,
  });

  const shortcut = await page.evaluate(() =>
    navigator.platform.includes('Mac') ? 'Meta+B' : 'Control+B');
  await page.keyboard.press(shortcut);
  await expect(page.getByRole('button', { name: 'Hide sidebar' })).toBeVisible();
  await expect(menu).toHaveCount(0);
  expect(app.pageErrors).toEqual([]);
});

test('settings persist host API changes through settings.set', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();

  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
  await page.getByRole('button', { name: 'API endpoint' }).click();
  await page.getByRole('option', { name: 'Custom URL' }).click();
  await expect.poll(() => app.requests.some(request =>
    request.method === 'settings.set' &&
    request.params?.provider === 'custom')).toBe(true);

  await page.getByRole('textbox', { name: 'Endpoint URL' }).fill(
    'https://example.test/chat/completions',
  );
  await expect.poll(() => app.requests.some(request =>
    request.method === 'settings.set' &&
    request.params?.custom_api_url === 'https://example.test/chat/completions'))
    .toBe(true);
  await expect(page.getByRole('textbox', { name: 'Endpoint URL' })).toHaveValue(
    'https://example.test/chat/completions',
  );
  expect(app.pageErrors).toEqual([]);
});

test('initial OpenRouter setup only needs an API key', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  app.hostSettings.has_deepseek_key = false;
  await app.install();
  await app.goto();

  await expect(page.getByText('Set up your DeepSeek API key')).toBeVisible();
  await page.getByRole('button', { name: 'API endpoint' }).click();
  await page.getByRole('option', { name: 'OpenRouter' }).click();
  await expect(page.getByLabel('OpenRouter model')).toHaveCount(0);
  await page.getByLabel('API key').fill('sk-openrouter-test');
  await page.getByRole('button', { name: 'Save API key' }).click();

  await expect.poll(() => app.requests.some(request =>
    request.method === 'settings.set' &&
    request.params?.provider === 'custom' &&
    request.params?.custom_api_url === 'https://openrouter.ai/api/v1/chat/completions')).toBe(true);
  await expect.poll(() => app.requests.some(request =>
    request.method === 'settings.set' &&
    request.params?.provider === 'custom' &&
    request.params?.custom_api_key === 'sk-openrouter-test')).toBe(true);
  await expect(page.getByText('Set up OpenRouter')).toBeHidden();
  expect(app.hostSettings.has_deepseek_key).toBe(false);
  expect(app.hostSettings.has_custom_key).toBe(true);

  // OpenRouter uses the ordinary chat model selector and persisted preference.
  await app.openSession();
  await page.getByRole('button', { name: 'Model', exact: true }).click();
  await page.getByRole('option', { name: 'DS Pro', exact: true }).click();
  await expect.poll(() => page.evaluate(() => localStorage.getItem('openseek.model')))
    .toBe('deepseek-v4-pro');
  await page.getByRole('button', { name: 'Model', exact: true }).click();
  await page.getByRole('option', { name: 'DS Flash', exact: true }).click();
  await expect.poll(() => page.evaluate(() => localStorage.getItem('openseek.model')))
    .toBe('deepseek-flash');
  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  await expect(page.getByLabel('OpenRouter model')).toHaveCount(0);
  expect(app.pageErrors).toEqual([]);
});

test('Codex account login can be started and cancelled from Settings', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  app.codexRequiresAuth = true;
  await app.install();
  await app.goto();

  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  await page.getByRole('button', { name: 'Sign in with ChatGPT' }).click();
  await expect.poll(() => app.requests.some(request =>
    request.method === 'codex.account.login.start')).toBe(true);
  await expect(page.getByRole('link', { name: 'Open' })).toHaveAttribute(
    'href',
    'https://example.test/codex-login',
  );

  await page.getByRole('button', { name: 'Cancel sign-in' }).click();
  await expect.poll(() => app.requests.some(request =>
    request.method === 'codex.account.login.cancel' &&
    request.params?.loginId === 'login-e2e')).toBe(true);
  await expect(page.getByRole('button', { name: 'Sign in with ChatGPT' })).toBeVisible();
  expect(app.pageErrors).toEqual([]);
});

test('workspace settings dialog opens and persists per-workspace choices', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();

  // The project row's "⋮" menu opens its workspace settings dialog.
  await page.locator('.workspace-row', { hasText: 'workspace' }).hover();
  await page.getByTitle('More actions').click();
  await page.getByRole('menuitem', { name: 'Workspace settings' }).click();
  await expect(page.getByRole('dialog', { name: 'Workspace settings' })).toBeVisible();
  await expect(page.locator('.settings-subtitle')).toHaveText('/workspace');

  // The dialog reads the host's authoritative snapshot before enabling the
  // selects.
  await expect.poll(() => app.requests.find(request =>
    request.method === 'workspace.settings_get')).toMatchObject({
    params: { workspace: '/workspace' },
  });

  const launchMode = page.getByRole('button', { name: 'New chats' });
  await expect(launchMode).toBeEnabled();
  await launchMode.click();
  await page.getByRole('option', { name: 'Worktree' }).click();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'workspace.settings_set' &&
    request.params?.worktree_mode === true)).toBeTruthy();
  // Wait for the harness store to settle before replaying the commit
  // broadcast, so the optimistic mirror is never rolled back by a
  // pre-mutation payload.
  await expect.poll(() => app.workspaceSettingsFor('/workspace').worktree_mode).toBe(true);
  app.notify(
    'workspace.settings_changed',
    { ...app.workspaceSettingsFor('/workspace') },
  );
  await expect(launchMode).toHaveText('Worktree');

  const submodules = page.getByRole('button', { name: 'Submodules in worktrees' });
  await submodules.click();
  await page.getByRole('option', { name: 'Initialize', exact: true }).click();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'workspace.settings_set' &&
    request.params?.checkout_submodules === true)).toBeTruthy();
  await expect.poll(() => app.workspaceSettingsFor('/workspace').checkout_submodules).toBe(true);
  app.notify(
    'workspace.settings_changed',
    { ...app.workspaceSettingsFor('/workspace') },
  );

  const timeout = page.getByRole('button', { name: 'Submodule checkout timeout' });
  await timeout.click();
  await page.getByRole('option', { name: '60 seconds' }).click();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'workspace.settings_set' &&
    request.params?.submodule_checkout_timeout_seconds === 60)).toBeTruthy();
  await expect.poll(() =>
    app.workspaceSettingsFor('/workspace').submodule_checkout_timeout_seconds,
  ).toBe(60);
  app.notify(
    'workspace.settings_changed',
    { ...app.workspaceSettingsFor('/workspace') },
  );

  // Close and re-enter: the dialog keeps the committed values.
  await page.getByRole('button', { name: 'Close workspace settings' }).click();
  await page.locator('.workspace-row', { hasText: 'workspace' }).hover();
  await page.getByTitle('More actions').click();
  await page.getByRole('menuitem', { name: 'Workspace settings' }).click();
  await expect(page.getByRole('button', { name: 'New chats' })).toHaveText('Worktree');
  await expect(page.getByRole('button', { name: 'Submodules in worktrees' })).toHaveText('Initialize');
  await expect(page.getByRole('button', { name: 'Submodule checkout timeout' })).toHaveText('60 seconds');
  // Settings are stored per workspace: a sibling project keeps its own
  // defaults, never inheriting this workspace's committed values.
  expect(app.workspaceSettingsFor('/other')).toEqual({
    workspace: '/other',
    worktree_mode: false,
    checkout_submodules: false,
    submodule_checkout_timeout_seconds: 30,
  });

  // Detaching the workspace closes the dialog and its select menu. Reopening
  // starts with closed selects, so the first trigger click opens the menu.
  const reentered = page.getByRole('button', { name: 'New chats' });
  await reentered.click();
  await expect(reentered).toHaveAttribute('aria-expanded', 'true');
  app.notify('workspace.changed', { workspaces: [] });
  await expect(page.getByRole('button', { name: 'New chats' })).toHaveCount(0);
  app.notify('workspace.changed', { workspaces: ['/workspace'] });
  await page.locator('.workspace-row', { hasText: 'workspace' }).hover();
  await page.getByTitle('More actions').click();
  await page.getByRole('menuitem', { name: 'Workspace settings' }).click();
  const reopened = page.getByRole('button', { name: 'New chats' });
  await expect(reopened).toHaveAttribute('aria-expanded', 'false');
  await reopened.click();
  await expect(reopened).toHaveAttribute('aria-expanded', 'true');

  expect(app.pageErrors).toEqual([]);
});

for (const [platform, modifier] of [['MacIntel', 'Meta'], ['Win32', 'Control']]) {
  test(`font size shortcuts clamp and persist on ${platform}`, async ({ page }) => {
    await page.addInitScript(platform => {
      Object.defineProperty(navigator, 'platform', { get: () => platform });
      Object.defineProperty(navigator, 'userAgentData', { get: () => undefined });
    }, platform);
    const app = new DesktopBrowserHarness(page);
    await app.install();
    await app.goto();
    await page.getByRole('button', { name: 'Settings', exact: true }).click();
    const slider = page.getByRole('slider', { name: 'Font size' });
    await slider.focus();
    await page.keyboard.press(`${modifier}+Equal`);
    await expect(slider).toHaveValue('15');
    await page.keyboard.press(`${modifier}+Shift+Equal`);
    await expect(slider).toHaveValue('16');
    await page.keyboard.press(`${modifier}+Minus`);
    await expect(slider).toHaveValue('15');
    await page.keyboard.press(`${modifier}+Alt+Equal`);
    await expect(slider).toHaveValue('15');
    // Capture must prevent the browser's zoom even for held-key repeats.
    const prevented = await slider.evaluate((element, modifier) => {
      const event = new KeyboardEvent('keydown', {
        key: '+', code: 'Equal', shiftKey: true,
        metaKey: modifier === 'Meta', ctrlKey: modifier === 'Control',
        repeat: true, bubbles: true, cancelable: true,
      });
      element.dispatchEvent(event);
      return event.defaultPrevented;
    }, modifier);
    expect(prevented).toBe(true);
    await expect(slider).toHaveValue('16');
    for (let i = 0; i < 5; i++) await page.keyboard.press(`${modifier}+Equal`);
    await expect(slider).toHaveValue('18');
    for (let i = 0; i < 9; i++) await page.keyboard.press(`${modifier}+Minus`);
    await expect(slider).toHaveValue('12');
    await expect(page.locator('body')).toHaveCSS('font-size', '12px');
    await page.reload();
    await expect(page.locator('body')).toHaveCSS('font-size', '12px');
    expect(app.pageErrors).toEqual([]);
  });
}
