import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

test('Review links hunk and file progress and reports the active hunk', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  app.gitFilesByRevision[app.gitBaseline]['src/main.mbt'] = [
    'fn main {',
    '  println("baseline")',
    '}',
    '',
    'fn spacer_one {',
    '  println("same one")',
    '}',
    '',
    'fn spacer_two {',
    '  println("same two")',
    '}',
    '',
    'fn tail {',
    '  println("baseline tail")',
    '}',
    '',
  ].join('\n');
  app.workingFiles['src/main.mbt'] = [
    'fn main {',
    '  println("working tree")',
    '}',
    '',
    'fn spacer_one {',
    '  println("same one")',
    '}',
    '',
    'fn spacer_two {',
    '  println("same two")',
    '}',
    '',
    'fn tail {',
    '  println("working tail")',
    '}',
    '',
  ].join('\n');

  await app.install();
  await app.goto();
  await app.openSession();
  await app.openReview();
  const changes = page.locator('#review-changes-body');
  await changes.getByRole('treeitem', { name: /View diff: src\/main\.mbt/ }).click();
  await page.getByRole('button', { name: 'Show file tree', exact: true }).click();

  await page.getByRole('toolbar', { name: 'Review mode' })
    .getByRole('button', { name: 'Line diff' }).click();
  const navigation = page.getByRole('group', { name: 'Diff change navigation' });
  const position = navigation.locator('.review-hunk-position');
  await expect(position).toHaveText('Change 1 of 2');
  await expect(page.getByRole('button', { name: 'Mark hunk viewed' }))
    .toHaveAttribute('aria-pressed', 'false');

  await page.getByRole('button', { name: 'Mark hunk viewed' }).click();
  await expect(page.getByRole('button', { name: 'Mark file reviewed' }))
    .toHaveAttribute('aria-pressed', 'mixed');
  await navigation.getByRole('button', { name: 'Next change' }).click();
  await expect(position).toHaveText('Change 2 of 2');
  await page.getByRole('button', { name: 'Mark hunk viewed' }).click();
  await expect(page.getByRole('button', { name: 'Mark file unreviewed' }))
    .toHaveAttribute('aria-pressed', 'true');
  await expect(changes.locator('.review-progress-summary')).toHaveText(
    '1 / 2 reviewed',
  );

  // Clearing the file clears every hunk; marking it again projects Viewed back
  // onto every hunk without depending on the currently selected group.
  await page.getByRole('button', { name: 'Mark file unreviewed' }).click();
  await expect(page.getByRole('button', { name: 'Mark hunk viewed' }))
    .toHaveAttribute('aria-pressed', 'false');
  await navigation.getByRole('button', { name: 'Previous change' }).click();
  await expect(position).toHaveText('Change 1 of 2');
  await expect(page.getByRole('button', { name: 'Mark hunk viewed' }))
    .toHaveAttribute('aria-pressed', 'false');
  await page.getByRole('button', { name: 'Mark file reviewed' }).click();
  await expect(page.getByRole('button', { name: 'Unmark hunk viewed' }))
    .toHaveAttribute('aria-pressed', 'true');
  await navigation.getByRole('button', { name: 'Next change' }).click();
  await expect(changes.getByRole('treeitem', { name: /View diff: src\/lib\.mbt/ }))
    .toHaveAttribute('aria-current', 'page');
  await changes.getByRole('treeitem', { name: /View diff: src\/main\.mbt/ }).click();
  await expect(position).toHaveText('Change 1 of 2');
  await expect(page.getByRole('button', { name: 'Unmark hunk viewed' }))
    .toHaveAttribute('aria-pressed', 'true');

  // Semantic review is a MultiDiff surface. Its counter is global across the
  // section-local editors, while file completion still projects into each
  // section's current hunk.
  const reviewToolbar = page.getByRole('toolbar', { name: 'Review mode' });
  await reviewToolbar.getByRole('button', { name: 'Token diff' }).click();
  await expect(reviewToolbar.getByRole('button', { name: 'Token diff' }))
    .toHaveAttribute('aria-pressed', 'true');
  await expect(position).toHaveText('Change 1 of 2');
  await expect(page.getByRole('button', { name: 'Unmark hunk viewed' }))
    .toHaveAttribute('aria-pressed', 'true');
  await navigation.getByRole('button', { name: 'Next change' }).click();
  await expect(changes.getByRole('treeitem', { name: /View diff: src\/lib\.mbt/ }))
    .toHaveAttribute('aria-current', 'page');
  await expect(page.getByRole('button', { name: 'Mark hunk viewed' }))
    .toHaveAttribute('aria-pressed', 'false');
  expect(app.pageErrors).toEqual([]);
});

for (const mode of ['Token', 'Tree']) {
  test(`${mode} review links file progress after opening another file`, async ({ page }) => {
    const app = new DesktopBrowserHarness(page);
    await app.install();
    await app.goto();
    await app.openSession();
    await app.openReview();
    const changes = page.locator('#review-changes-body');
    await changes.getByRole('treeitem', { name: /View diff: src\/main\.mbt/ }).click();
    await page.getByRole('button', { name: 'Show file tree', exact: true }).click();
    const modeButton = page.getByRole('button', { name: `${mode} diff`, exact: true });
    await modeButton.click();
    await changes.getByRole('treeitem', { name: /View diff: src\/lib\.mbt/ }).click();
    await expect(modeButton).toHaveAttribute('aria-pressed', 'true');
    await expect(page.locator('.review-hunk-position')).toHaveText('Change 1 of 1');

    await page.getByRole('button', { name: 'Mark hunk viewed', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Mark file unreviewed' }))
      .toHaveAttribute('aria-pressed', 'true');

    await page.getByRole('button', { name: 'Mark file unreviewed' }).click();
    await page.getByRole('button', { name: 'Mark file reviewed', exact: true }).click();
    const unmarkHunk = page.getByRole('button', { name: 'Unmark hunk viewed' });
    await expect(unmarkHunk).toBeEnabled();
    await unmarkHunk.click();
    await expect(page.getByRole('button', { name: 'Mark file reviewed', exact: true }))
      .toHaveAttribute('aria-pressed', 'false');
    expect(app.pageErrors).toEqual([]);
  });
}

for (const mode of ['Line', 'Token', 'Tree']) {
  test(`${mode} hunk actions and navigation follow manual scrolling`, async ({ page }) => {
    const app = new DesktopBrowserHarness(page);
    const block = (name) => [`fn ${name} {`, ...Array.from({ length: 70 }, (_, i) => `  println("${name} ${i}")`), '}', ''];
    const baseline = [...block('first'), ...block('second')].join('\n');
    app.gitFilesByRevision[app.gitBaseline]['src/main.mbt'] = baseline;
    app.workingFiles['src/main.mbt'] = baseline.replace('first 5', 'first changed').replace('second 60', 'second changed');
    await app.install();
    await app.goto();
    await app.openSession();
    await app.openReview();
    await page.locator('#review-changes-body').getByRole('treeitem', { name: /View diff: src\/main\.mbt/ }).click();
    const toolbar = page.getByRole('toolbar', { name: 'Review mode' });
    await toolbar.getByRole('button', { name: `${mode} diff` }).click();
    const position = page.locator('.review-hunk-position');
    await expect(position).toHaveText('Change 1 of 2');
    // Wheel input must update the counter without moving the cursor or marking
    // coverage. The last hunk's action must then affect exactly that hunk.
    const visibleEditor = page.locator('.moonbit-diff-editor:visible').last();
    await visibleEditor.hover();
    await page.mouse.wheel(0, 10000);
    await expect(position).toHaveText('Change 2 of 2');
    await expect(page.getByRole('button', { name: 'Mark hunk viewed', exact: true })).toHaveAttribute('aria-pressed', 'false');
    const localAction = page.locator('.moonbit-diff-hunk-action:visible .review-hunk-marker').last();
    await localAction.click();
    await expect(localAction).toBeFocused();
    await expect(page.getByRole('button', { name: 'Unmark hunk viewed', exact: true })).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByRole('button', { name: 'Mark file reviewed', exact: true })).toHaveAttribute('aria-pressed', 'mixed');
    await page.mouse.wheel(0, -10000);
    await expect(position).toHaveText('Change 1 of 2');
    await expect(page.getByRole('button', { name: 'Mark hunk viewed', exact: true })).toHaveAttribute('aria-pressed', 'false');
    await visibleEditor.hover();
    await page.mouse.wheel(0, 10000);
    await expect(position).toHaveText('Change 2 of 2');
    await expect(page.getByRole('button', { name: 'Unmark hunk viewed', exact: true })).toHaveAttribute('aria-pressed', 'true');
    await page.locator('.moonbit-diff-hunk-action:visible .review-hunk-marker').last().click();
    await expect(page.getByRole('button', { name: 'Mark file reviewed', exact: true })).toHaveAttribute('aria-pressed', 'false');
    await visibleEditor.hover();
    await page.mouse.wheel(0, -10000);
    await expect(position).toHaveText('Change 1 of 2');
    await page.getByRole('button', { name: 'Next change', exact: true }).click();
    await expect(position).toHaveText('Change 2 of 2');
    await expect(page.getByRole('button', { name: 'Mark hunk viewed', exact: true })).toHaveAttribute('aria-pressed', 'false');
    expect(app.pageErrors).toEqual([]);
  });
}

for (const mode of ['Token', 'Tree']) {
  test(`${mode} navigation enters the boundary after every section is collapsed`, async ({ page }) => {
    const app = new DesktopBrowserHarness(page);
    const baseline = ['fn first() -> Int { 1 }', '', 'fn second() -> Int { 2 }', ''].join('\n');
    app.gitFilesByRevision[app.gitBaseline]['src/main.mbt'] = baseline;
    app.workingFiles['src/main.mbt'] = baseline.replace('{ 1 }', '{ 10 }').replace('{ 2 }', '{ 20 }');
    await app.install();
    await app.goto();
    await app.openSession();
    await app.openReview();
    await page.locator('#review-changes-body').getByRole('treeitem', { name: /View diff: src\/main\.mbt/ }).click();
    await page.getByRole('toolbar', { name: 'Review mode' }).getByRole('button', { name: `${mode} diff` }).click();
    const sections = page.locator('.semantic-diff-entry');
    const headers = sections.locator('.semantic-entry-header-content');
    await expect(sections).toHaveCount(2);
    for (const header of await headers.all()) {
      await header.click();
      await expect(header).toHaveAttribute('aria-expanded', 'false');
    }
    const position = page.locator('.review-hunk-position');
    for (const next of ['button', 'F7']) {
      if (next === 'button') {
        await page.getByRole('button', { name: 'Next change', exact: true }).click();
      } else {
        await page.keyboard.press('F7');
      }
      await expect(headers.nth(0)).toHaveAttribute('aria-expanded', 'true');
      await expect(headers.nth(1)).toHaveAttribute('aria-expanded', 'false');
      await expect(position).toHaveText('Change 1 of 2');
      await headers.nth(0).click();
      await expect(headers.nth(0)).toHaveAttribute('aria-expanded', 'false');
    }
    await page.keyboard.press('Shift+F7');
    await expect(headers.nth(0)).toHaveAttribute('aria-expanded', 'false');
    await expect(headers.nth(1)).toHaveAttribute('aria-expanded', 'true');
    await expect(position).toHaveText('Change 2 of 2');
    expect(app.pageErrors).toEqual([]);
  });
}

for (const layout of ['Split', 'Unified']) {
  test(`${layout} pure deletion has a local hunk action at its deleted line`, async ({ page }) => {
    const app = new DesktopBrowserHarness(page);
    const before = ['fn main {', '  println("keep")', '  println("delete me")', '  println("keep too")', '}', ''].join('\n');
    app.gitFilesByRevision[app.gitBaseline]['src/main.mbt'] = before;
    app.workingFiles['src/main.mbt'] = before.replace('  println("delete me")\n', '');
    await app.install();
    await app.goto();
    await app.openSession();
    await app.openReview();
    await page.locator('#review-changes-body').getByRole('treeitem', { name: /View diff: src\/main\.mbt/ }).click();
    await page.getByRole('button', { name: 'Line diff', exact: true }).click();
    await page.getByRole('button', { name: `${layout} diff layout`, exact: true }).click();
    const action = page.locator('.moonbit-diff-hunk-action:visible .review-hunk-marker');
    await expect(action).toBeVisible();
    const deleted = page.locator(layout === 'Split' ? '.moonbit-diff-editor-original .view-line' : '.diff-editor-inline-deleted-line').filter({ hasText: 'delete me' });
    // Layout switching can leave the original pane mounted but hidden for a
    // frame. Retry the complete geometry assertion until both boxes exist.
    await expect(deleted).toBeVisible();
    await expect(async () => {
      const [button, line] = await Promise.all([action.boundingBox(), deleted.boundingBox()]);
      expect(button).not.toBeNull();
      expect(line).not.toBeNull();
      expect(Math.abs(button.y - line.y)).toBeLessThan(3);
    }).toPass({ timeout: 5_000 });
    // The marker has its own gutter, before even the original line numbers.
    // Check actual rendered boxes: moving an overlay left would fail this.
    await expect.poll(() => action.evaluate(button => {
      const panes = button.closest('.moonbit-diff-editor').querySelector('.moonbit-diff-editor-panes');
      return button.getBoundingClientRect().right <= panes.getBoundingClientRect().left;
    })).toBe(true);
    await action.click();
    await expect(action).toHaveText('✓');
    const panelBox = await page.locator('.editor').boundingBox();
    const clip = { ...panelBox, height: Math.min(panelBox.height, 320) };
    await page.screenshot({ path: `/tmp/hunk-gutter-${layout.toLowerCase()}-viewed.png`, clip });
    await expect(page.getByRole('button', { name: 'Mark file unreviewed', exact: true })).toHaveAttribute('aria-pressed', 'true');
    await action.click();
    await expect(page.getByRole('button', { name: 'Mark file reviewed', exact: true })).toHaveAttribute('aria-pressed', 'false');
    await page.screenshot({ path: `/tmp/hunk-gutter-${layout.toLowerCase()}.png`, clip });
    expect(app.pageErrors).toEqual([]);
  });
}
