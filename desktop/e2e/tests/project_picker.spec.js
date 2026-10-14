import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';
import { sidebarAddProject } from './support/sidebar.js';

test('project picker adds the browsed folder with Enter', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();

  await (await sidebarAddProject(page)).click();
  const picker = page.getByRole('dialog', { name: 'Add a project' });
  await expect(picker).toBeVisible();
  await expect(
    picker.getByRole('button', { name: 'Add project', exact: true }),
  ).toBeEnabled();
  await page.keyboard.press('Enter');

  await expect.poll(() => app.requests.find(request =>
    request.method === 'workspace.add')).toMatchObject({
    params: { path: '/Users/test' },
  });
  await expect(picker).toBeHidden();
  app.notify('workspace.changed', { workspaces: app.workspaces });
  await expect(page.getByRole('button', { name: 'test', exact: true })).toBeVisible();
  expect(app.pageErrors).toEqual([]);
});

test('new-chat project title filters and switches registered projects', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  app.workspaces.push('/other');
  await app.install();
  await app.goto();

  const workspace = page.locator('.workspace-row[title="/workspace"]');
  const other = page.locator('.workspace-row[title="/other"]');
  const transcript = page.locator('#transcript');
  const bootSession = await transcript.getAttribute('data-transcript-session');
  await workspace.hover();
  await workspace.getByTitle('New conversation in this project').click();

  const title = page.locator('.empty-title');
  await expect(title).toHaveText('What should we build in workspace?');
  await expect(page.getByText(/SeekMoon plans the work/)).toHaveCount(0);
  // The click starts a fresh draft a beat after it returns, and the title
  // already matched the boot draft: wait for the rotation before recording.
  await expect(transcript).not.toHaveAttribute('data-transcript-session', bootSession);
  const originalSession = await transcript.getAttribute('data-transcript-session');

  // The picker borrows the app's select popup frame. Capture that frame from
  // the Model select and compare the two computed surfaces.
  const modelTrigger = page.getByRole('button', { name: 'Model', exact: true });
  await modelTrigger.click();
  const modelMenu = page.getByRole('listbox', { name: 'Model' });
  await expect(modelMenu).toBeVisible();
  const selectSurface = await modelMenu.evaluate(element => {
    const style = getComputedStyle(element);
    return [
      style.padding,
      style.border,
      style.borderRadius,
      style.backgroundColor,
      style.boxShadow,
      style.fontFamily,
    ];
  });
  await modelTrigger.click();
  await expect(modelMenu).toBeHidden();

  const trigger = page.getByRole('button', {
    name: 'Choose project, current project workspace',
  });
  await trigger.click();
  const picker = page.getByRole('dialog', { name: 'Choose a project' });
  const search = picker.getByRole('textbox', { name: 'Search projects' });
  const options = picker.getByRole('group', { name: 'Projects' });
  await expect(picker).toBeVisible();
  expect(await picker.evaluate(element => {
    const style = getComputedStyle(element);
    return [
      style.padding,
      style.border,
      style.borderRadius,
      style.backgroundColor,
      style.boxShadow,
      style.fontFamily,
    ];
  })).toEqual(selectSurface);
  await expect(search).toBeFocused();
  const triggerBounds = await trigger.boundingBox();
  const pickerBounds = await picker.boundingBox();
  const viewport = page.viewportSize();
  expect(triggerBounds).not.toBeNull();
  expect(pickerBounds).not.toBeNull();
  expect(viewport).not.toBeNull();
  expect(pickerBounds.y).toBeGreaterThanOrEqual(
    triggerBounds.y + triggerBounds.height,
  );
  expect(pickerBounds.x).toBeGreaterThanOrEqual(0);
  expect(pickerBounds.x + pickerBounds.width).toBeLessThanOrEqual(viewport.width);
  expect(pickerBounds.y + pickerBounds.height).toBeLessThanOrEqual(viewport.height);
  await expect(options.getByRole('button')).toHaveCount(2);
  await expect(
    options.getByRole('button', { name: /^workspace, current project/ }),
  ).toHaveAttribute('aria-current', 'true');
  await expect(
    options.getByRole('button', { name: /^other —/ }),
  ).toHaveAttribute('aria-current', 'false');
  await expect(picker.getByText("Don't work in a project")).toHaveCount(0);
  await expect(picker.getByRole('button', { name: 'New project' })).toBeVisible();

  await search.press('Escape');
  await expect(picker).toBeHidden();
  await expect(trigger).toBeFocused();
  await trigger.click();
  await expect(search).toBeFocused();

  await search.fill('oth');
  await expect(options.getByRole('button', { name: /^workspace/ })).toHaveCount(0);
  await expect(options.getByRole('button', { name: /^other —/ })).toBeVisible();
  await search.fill('');

  // The selected row only closes the picker; it must not rotate the draft.
  await options.getByRole('button', { name: /^workspace, current project/ }).click();
  await expect(picker).toBeHidden();
  await expect(transcript).toHaveAttribute('data-transcript-session', originalSession);
  await expect(trigger).toBeFocused();

  await trigger.click();
  await picker.getByRole('button', { name: /^other —/ }).click();
  await expect(other).toHaveClass(/\bactive\b/);
  await expect(title).toHaveText('What should we build in other?');
  await expect(transcript).not.toHaveAttribute('data-transcript-session', originalSession);

  await page.getByRole('button', {
    name: 'Choose project, current project other',
  }).click();
  await picker.getByRole('button', { name: 'New project' }).click();
  const addProject = page.getByRole('dialog', { name: 'Add a project' });
  await expect(addProject).toBeVisible();
  await expect(picker).toBeHidden();
  await addProject.getByRole('button', { name: 'Close project picker' }).click();
  await expect(addProject).toBeHidden();
  expect(app.pageErrors).toEqual([]);
});

test('new-chat project picker stays clear of its title in a short window', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  for (let index = 0; index < 30; index += 1) {
    app.workspaces.push(`/project-${index}`);
  }
  await app.install();
  await page.setViewportSize({ width: 1000, height: 500 });
  await app.goto();

  const workspace = page.locator('.workspace-row[title="/workspace"]');
  await workspace.hover();
  await workspace.getByTitle('New conversation in this project').click();
  const trigger = page.getByRole('button', {
    name: 'Choose project, current project workspace',
  });
  await trigger.click();
  const picker = page.getByRole('dialog', { name: 'Choose a project' });
  await expect(picker).toBeVisible();

  const titleBounds = await page.locator('.empty-title').boundingBox();
  const pickerBounds = await picker.boundingBox();
  expect(titleBounds).not.toBeNull();
  expect(pickerBounds).not.toBeNull();
  expect(
    pickerBounds.y >= titleBounds.y + titleBounds.height ||
      pickerBounds.y + pickerBounds.height <= titleBounds.y,
  ).toBe(true);
  expect(pickerBounds.y).toBeGreaterThanOrEqual(0);
  expect(pickerBounds.y + pickerBounds.height).toBeLessThanOrEqual(500);
  const listSize = await picker.locator('.empty-project-options').evaluate((list) => ({
    client: list.clientHeight,
    overflowY: getComputedStyle(list).overflowY,
    scroll: list.scrollHeight,
  }));
  expect(listSize.scroll).toBeGreaterThan(listSize.client);
  expect(listSize.overflowY).toBe('auto');
  expect(app.pageErrors).toEqual([]);
});

test('desktop shell and modal stay inside a narrow browser viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();

  await page.getByRole('button', { name: 'Show sidebar' }).click();
  await (await sidebarAddProject(page)).click();
  const bounds = await page.locator('.picker-modal').boundingBox();
  expect(bounds).not.toBeNull();
  expect(bounds.x).toBeGreaterThanOrEqual(0);
  expect(bounds.y).toBeGreaterThanOrEqual(0);
  expect(bounds.x + bounds.width).toBeLessThanOrEqual(390);
  expect(bounds.y + bounds.height).toBeLessThanOrEqual(844);
  await expect.poll(() => page.evaluate(() =>
    document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true);
  expect(app.pageErrors).toEqual([]);
});

test('project picker capture preserves focused controls and is removed on close', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();
  const open = await sidebarAddProject(page);
  const picker = page.getByRole('dialog', { name: 'Add a project', exact: true });
  for (let i = 0; i < 2; i++) {
    await open.click();
    await expect(picker).toBeVisible();
    await page.keyboard.press('Control+l');
    const path = page.locator('#project-picker-path-input');
    await expect(path).toBeFocused();
    // Escape belongs to the focused editor first, not to the modal capture.
    await path.press('Escape');
    await expect(path).toBeHidden();
    await expect(picker).toBeVisible();
    // Enter on Cancel must activate that button, not register the directory.
    const cancel = picker.getByRole('button', { name: 'Cancel', exact: true });
    await cancel.focus();
    await cancel.press('Enter');
    await expect(picker).toBeHidden();
  }
  expect(app.requests.filter(request => request.method === 'workspace.add')).toHaveLength(0);
  // A removed capture listener must not consume later key or paste events.
  const handled = await page.evaluate(() => {
    const key = new KeyboardEvent('keydown', { key: 'l', ctrlKey: true, bubbles: true, cancelable: true });
    const paste = new ClipboardEvent('paste', { bubbles: true, cancelable: true });
    document.dispatchEvent(key);
    document.dispatchEvent(paste);
    return [key.defaultPrevented, paste.defaultPrevented];
  });
  expect(handled).toEqual([false, false]);
  expect(app.pageErrors).toEqual([]);
});
