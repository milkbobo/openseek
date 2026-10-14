import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

test('sidebar sizes update immediately between toggles', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  await app.install();
  await app.goto();
  await expect(page.getByRole('button', { name: 'Hide sidebar', exact: true }))
    .toBeVisible();

  // No drag class is set: any requested size must take effect immediately,
  // while the separate toggle test continues to exercise open/close motion.
  const samples = await page.locator('.app').evaluate(async element => {
    const sidebar = element.querySelector(':scope > aside');
    const samples = [];
    for (const width of [300, 360, 420, 280]) {
      document.documentElement.style.setProperty('--sidebar-width', `${width}px`);
      samples.push({ requested: width, actual: sidebar.getBoundingClientRect().width });
      await new Promise(resolve => requestAnimationFrame(resolve));
    }
    return samples;
  });
  for (const sample of samples) {
    expect(Math.abs(sample.actual - sample.requested)).toBeLessThan(0.5);
  }
  expect(app.pageErrors).toEqual([]);
});

test('sidebar toggle stays fixed throughout the sidebar animation', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();

  for (const name of ['Hide sidebar', 'Show sidebar']) {
    const toggle = page.getByRole('button', { name, exact: true });
    const frames = await toggle.evaluate(button => new Promise(resolve => {
      const start = performance.now();
      const positions = [button.getBoundingClientRect().x];
      button.click();
      const sample = now => {
        positions.push(button.getBoundingClientRect().x);
        if (now - start < 250) requestAnimationFrame(sample);
        else resolve({ positions, connected: button.isConnected });
      };
      requestAnimationFrame(sample);
    }));
    expect(frames.connected).toBe(true);
    expect(Math.max(...frames.positions) - Math.min(...frames.positions)).toBeLessThan(0.5);
    await expect(page.getByRole('button', {
      name: name === 'Hide sidebar' ? 'Show sidebar' : 'Hide sidebar',
      exact: true,
    })).toBeVisible();
  }
  expect(app.pageErrors).toEqual([]);
});

test('shared WebView action menu supports context position, keyboard, and rename', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  app.workspaces.push('/other');
  await app.install();
  await app.goto();

  const firstWorkspace = page.locator('.workspace-row[title="/workspace"]');
  const secondWorkspace = page.locator('.workspace-row[title="/other"]');
  const firstWorkspaceMenu = firstWorkspace.getByTitle('More actions');
  const secondWorkspaceMenu = secondWorkspace.getByTitle('More actions');
  await firstWorkspace.hover();
  await firstWorkspaceMenu.click();
  await expect(firstWorkspaceMenu).toHaveAttribute('aria-expanded', 'true');
  let menu = page.getByRole('menu', { name: 'Workspace actions' });
  await expect(menu).toBeFocused();
  await expect(menu.getByRole('menuitem').first()).not.toBeFocused();
  await page.keyboard.press('Escape');
  await expect(menu).toHaveCount(0);
  await expect(firstWorkspaceMenu).toBeFocused();
  await secondWorkspace.hover();
  await secondWorkspaceMenu.click();
  await expect(firstWorkspaceMenu).toHaveAttribute('aria-expanded', 'false');
  await expect(secondWorkspaceMenu).toHaveAttribute('aria-expanded', 'true');
  menu = page.getByRole('menu', { name: 'Workspace actions' });
  await expect(menu).toBeFocused();
  await secondWorkspaceMenu.click();
  await expect(page.getByRole('menu')).toHaveCount(0);

  await secondWorkspaceMenu.focus();
  await page.keyboard.press('Enter');
  menu = page.getByRole('menu', { name: 'Workspace actions' });
  await expect(menu).toBeFocused();
  await expect(menu.getByRole('menuitem').first()).not.toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(menu.getByRole('menuitem').first()).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(menu).toHaveCount(0);
  await expect(secondWorkspaceMenu).toBeFocused();

  const liveRow = page.locator('.conversation-row[title="session-1"]');
  const actionsButton = liveRow.getByRole('button', { name: 'Conversation actions' });
  await liveRow.hover();
  await actionsButton.focus();
  await liveRow.click({ button: 'right', position: { x: 18, y: 18 } });
  menu = page.getByRole('menu', { name: 'Conversation actions' });
  await expect(menu).toBeVisible();
  const rename = menu.getByRole('menuitem', { name: 'Rename…' });
  const archive = menu.getByRole('menuitem', { name: 'Archive' });
  await expect(menu).toBeFocused();
  await expect(rename).not.toBeFocused();
  await expect(rename).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)');

  await page.keyboard.press('ArrowDown');
  await expect(rename).toBeFocused();

  const bounds = await menu.boundingBox();
  const viewport = page.viewportSize();
  expect(bounds).not.toBeNull();
  expect(bounds.x).toBeGreaterThanOrEqual(0);
  expect(bounds.y).toBeGreaterThanOrEqual(0);
  expect(bounds.x + bounds.width).toBeLessThanOrEqual(viewport.width);
  expect(bounds.y + bounds.height).toBeLessThanOrEqual(viewport.height);

  await page.keyboard.press('ArrowDown');
  await expect(archive).toBeFocused();
  await page.keyboard.press('Home');
  await expect(rename).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(menu).toHaveCount(0);
  await expect(actionsButton).toBeFocused();

  // The row's overflow trigger opens the same menu and toggles it closed.
  await actionsButton.click();
  await expect(actionsButton).toHaveAttribute('aria-expanded', 'true');
  await expect(menu).toBeFocused();
  await expect(menu.getByRole('menuitem')).toHaveText(['Rename…', 'Archive']);
  await expect(archive).toHaveAttribute('title', /Archive —/);
  await actionsButton.click();
  await expect(menu).toHaveCount(0);

  // Rename edits the title in the row itself, like the Finder: no dialog.
  const renameRequests = () => app.requests.filter(request =>
    request.method === 'session.rename');
  const input = liveRow.getByRole('textbox', { name: 'Rename conversation' });
  const startRename = async () => {
    await liveRow.hover();
    await actionsButton.click();
    await page.getByRole('menuitem', { name: 'Rename…' }).click();
    await expect(input).toBeFocused();
  };
  await liveRow.click({ button: 'right', position: { x: 18, y: 18 } });
  await page.getByRole('menuitem', { name: 'Rename…' }).click({ button: 'right' });
  await expect(input).toBeFocused();
  await expect(page.getByRole('dialog')).toHaveCount(0);
  await expect.poll(() => input.evaluate(element => ({
    start: element.selectionStart,
    end: element.selectionEnd,
    length: element.value.length,
  }))).toEqual({ start: 0, end: 23, length: 23 });

  // Escape discards the draft and hands focus back to the title.
  await input.fill('Discarded');
  await input.press('Escape');
  await expect(input).toHaveCount(0);
  const title = liveRow.getByRole('button', { name: 'Rabbita browser fixture', exact: true });
  await expect(title).toBeFocused();

  // A blank title keeps the current one.
  await startRename();
  await input.fill('   ');
  await input.press('Enter');
  await expect(input).toHaveCount(0);
  await expect(title).toBeVisible();
  expect(renameRequests()).toEqual([]);

  // Clicks inside the field belong to the field, not to the row or its menu.
  await startRename();
  await input.click();
  await input.click({ button: 'right' });
  await expect(menu).toHaveCount(0);
  await expect(input).toBeFocused();

  // Enter saves; the field is locked and only the host's answer ends the edit.
  app.rpcDelays.set('session.rename', 1200);
  await input.fill('Renamed in WebView');
  await input.press('Enter');
  await expect.poll(() => renameRequests()).toHaveLength(1);
  await expect(input).toHaveJSProperty('readOnly', true);
  await input.press('Escape');
  await input.press('Enter');
  await expect(input).toBeVisible();
  expect(renameRequests()).toHaveLength(1);
  await expect.poll(() => renameRequests()[0]).toMatchObject({
    params: {
      session: 'session-1',
      workspace: '/workspace',
      title: 'Renamed in WebView',
    },
  });
  await expect(input).toHaveCount(0);
  await expect(
    liveRow.getByRole('button', { name: 'Renamed in WebView', exact: true }),
  ).toBeFocused();

  // Moving on while the save is pending keeps focus where the user went.
  await startRename();
  await input.fill('Renamed while typing elsewhere');
  await input.press('Enter');
  await page.locator('#task').click();
  await expect(input).toHaveCount(0);
  await expect(page.locator('#task')).toBeFocused();
  app.rpcDelays.delete('session.rename');

  // Moving focus away saves too, and focus stays where the user put it.
  await startRename();
  await input.fill('Renamed by leaving');
  await page.locator('#task').click();
  await expect(input).toHaveCount(0);
  await expect(
    liveRow.getByRole('button', { name: 'Renamed by leaving', exact: true }),
  ).toBeVisible();
  expect(renameRequests()).toHaveLength(3);
  await expect(page.locator('#task')).toBeFocused();

  // So does a press on plain, unfocusable content.
  await startRename();
  await input.fill('Renamed by pressing elsewhere');
  await page.locator('.topbar').click({ position: { x: 300, y: 6 } });
  await expect(input).toHaveCount(0);
  expect(renameRequests()).toHaveLength(4);

  // A failed save leaves the title as it was and says why in a toast.
  app.rpcErrors.set('session.rename', 'fixture rename unavailable');
  await startRename();
  await input.fill('Rename that will fail');
  await input.press('Enter');
  await expect(page.locator('.notification')).toContainText(
    'Rename failed: fixture rename unavailable',
  );
  await expect(input).toHaveCount(0);
  await expect(
    liveRow.getByRole('button', { name: 'Renamed by pressing elsewhere', exact: true }),
  ).toBeFocused();
  expect(app.pageErrors).toEqual([]);
});

test('sidebar menu dismissal and pending selection follow the clicked row', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  app.liveSessions.push({
    id: 'session-2',
    title: 'Second browser fixture',
    updated_at_ms: 2,
  });
  await app.install();
  await app.goto();

  const workspace = page.locator('.workspace-row', { hasText: 'workspace' });
  await workspace.click({ button: 'right', position: { x: 24, y: 16 } });
  await expect(page.getByRole('menu', { name: 'Workspace actions' })).toBeVisible();

  const first = page.locator('.conversation-row[title="session-1"]');
  // The menu opens at the pointer and can cover the rows below it, so click
  // the row's leading padding, left of where the menu starts. Not its right
  // end: that is the hover-revealed actions trigger, and the row's width is
  // platform-dependent.
  await first.click({ position: { x: 4, y: 10 } });
  await expect(page.getByRole('menu')).toHaveCount(0);
  await expect(first).toHaveClass(/active/);
  await expect(page.getByText('Browser result', { exact: true })).toBeVisible();

  app.rpcDelays.set('session.load', 10000);
  await first.click({ button: 'right', position: { x: 18, y: 18 } });
  await expect(page.getByRole('menu', { name: 'Conversation actions' })).toBeVisible();
  const second = page.locator('.conversation-row[title="session-2"]');
  await second.click();
  await expect(page.getByRole('menu')).toHaveCount(0);
  await expect(second).toHaveClass(/active/);
  await expect(first).not.toHaveClass(/active/);
  await expect(second.getByRole('status', { name: 'Loading conversation' })).toBeVisible();
  await expect(page.getByText('Loading conversation…', { exact: true })).toBeVisible();
  const rowSpinner = second.locator('.conversation-load-spinner');
  const panelSpinner = page.locator('.conversation-load-state-spinner');
  await expect(rowSpinner).toHaveCSS('animation-name', 'conversation-load-spin');
  await expect(panelSpinner).toHaveCount(0);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await expect(rowSpinner).toHaveCSS('animation-name', 'none');
  await expect(page.getByText('Browser result', { exact: true })).toHaveCount(0);
  await expect.poll(() => app.requests.some(request =>
    request.method === 'session.load' && request.params?.session === 'session-2'))
    .toBe(true);
  expect(app.pageErrors).toEqual([]);
});
