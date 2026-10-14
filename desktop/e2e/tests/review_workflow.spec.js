import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

test('Review loads changed files and preserves its interactive diff workflow', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();
  await app.openSession();
  await app.openReview();

  await expect(page.getByRole('tab', { name: 'Changes 2', exact: true }))
    .toHaveAttribute('aria-selected', 'true');
  await expect.poll(() => app.requests.find(request => request.method === 'git.changes'))
    .toMatchObject({
      params: {
        session: 'session-1',
        workspace: '/workspace',
      },
    });
  const changes = page.locator('#review-changes-body');
  await expect(changes.locator('.review-progress-summary')).toHaveText(
    '0 / 2 reviewed',
  );
  const main = changes.getByRole('treeitem', { name: /View diff: src\/main\.mbt/ });
  const library = changes.getByRole('treeitem', { name: /View diff: src\/lib\.mbt/ });
  await expect(main).toHaveAttribute('aria-current', 'false');
  await main.click();
  await page.getByRole('button', { name: 'Show file tree', exact: true }).click();

  await expect.poll(() => app.requests.find(request =>
    request.method === 'fs.read_file' && request.params?.path === '/workspace/src/main.mbt'))
    .toBeTruthy();
  await expect.poll(() => app.requests.find(request =>
    request.method === 'git.original_file' &&
    request.params?.path === 'src/main.mbt' &&
    request.params?.revision === app.gitBaseline))
    .toBeTruthy();
  const reviewToolbar = page.getByRole('toolbar', { name: 'Review mode' });
  await expect(reviewToolbar.getByRole('button', { name: 'Token diff' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await expect(page.locator('.semantic-review[data-mode="token"]')).toBeVisible();

  // Line diff keeps semantic-only filters inert. Token and Tree make those
  // user controls available.
  await reviewToolbar.getByRole('button', { name: 'Line diff' }).click();
  const ignoreComments = page.getByRole('button', { name: 'Ignore comments' });
  const ignoreTests = page.getByRole('button', { name: 'Ignore tests' });
  await expect(ignoreComments).toBeDisabled();
  await expect(ignoreTests).toBeDisabled();

  await reviewToolbar.getByRole('button', { name: 'File view' }).click();
  await expect(reviewToolbar.getByRole('button', { name: 'File view' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await reviewToolbar.getByRole('button', { name: 'Line diff' }).click();

  await reviewToolbar.getByRole('button', { name: 'Token diff' }).click();
  await expect(reviewToolbar.getByRole('button', { name: 'Token diff' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await expect(ignoreComments).toHaveAttribute('aria-pressed', 'true');
  await expect(ignoreTests).toHaveAttribute('aria-pressed', 'true');
  await ignoreComments.click();
  await ignoreTests.click();
  await expect(ignoreComments).toHaveAttribute('aria-pressed', 'false');
  await expect(ignoreTests).toHaveAttribute('aria-pressed', 'false');

  await reviewToolbar.getByRole('button', { name: 'Tree diff' }).click();
  await expect(reviewToolbar.getByRole('button', { name: 'Tree diff' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );

  const layout = page.getByRole('group', { name: 'Diff layout' });
  await layout.getByRole('button', { name: 'Unified diff layout' }).click();
  await expect(layout.getByRole('button', { name: 'Unified diff layout' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  const semantic = page.locator(
    '.semantic-review[data-mode="tree"][data-layout="unified"]',
  );
  await expect(semantic).toBeVisible();
  const semanticDiffCandidate = semantic.locator('.semantic-diff-editor-host').filter({
    has: page.locator(
      '.moonbit-diff-editor-modified '
        + '.view-lines[data-view-part="view-lines"] > .view-line',
      { hasText: 'working tree' },
    ),
  }).first();
  await expect(semanticDiffCandidate).toBeVisible();
  const semanticDiffId = await semanticDiffCandidate.getAttribute('id');
  expect(semanticDiffId).not.toBeNull();
  const semanticDiff = semantic.locator(`[id=${JSON.stringify(semanticDiffId)}]`);
  const semanticOriginal = semanticDiff.locator('.moonbit-diff-editor-original');
  const semanticModified = semanticDiff.locator('.moonbit-diff-editor-modified');
  await expect(semanticDiff).toBeVisible();
  await expect(semanticDiff.locator('.moonbit-diff-editor').first())
    .toHaveAttribute('data-render-mode', 'inline');
  await expect(semanticOriginal.locator('.line-numbers:visible').first())
    .toBeVisible();
  await expect.poll(() => semanticOriginal.evaluate((node) => {
    const host = node.getBoundingClientRect();
    const margin = node.querySelector('.margin');
    const lineNumber = Array.from(node.querySelectorAll('.line-numbers'))
      .map((element) => element.getBoundingClientRect())
      .find((rect) => rect.width > 0);
    if (!margin || !lineNumber) return null;
    const marginRect = margin.getBoundingClientRect();
    return {
      lineNumberAligned:
        Math.abs(host.width - (lineNumber.right - host.left)) <= 0.5,
      decorationsClipped: host.width < marginRect.width,
    };
  })).toEqual({ lineNumberAligned: true, decorationsClipped: true });

  const feedbackLine = semanticModified.locator(
    '.view-lines[data-view-part="view-lines"] > .view-line',
  ).filter({ hasText: 'working tree' }).first();
  await expect(feedbackLine).toBeVisible();
  const feedbackLineBox = await feedbackLine.boundingBox();
  const modifiedBox = await semanticModified.boundingBox();
  expect(feedbackLineBox).not.toBeNull();
  expect(modifiedBox).not.toBeNull();
  await page.mouse.move(
    Math.min(
      feedbackLineBox.x + 20,
      modifiedBox.x + modifiedBox.width - 10,
    ),
    feedbackLineBox.y + feedbackLineBox.height / 2,
  );
  const feedbackGlyph = semanticModified.locator(
    '.agent-feedback-glyph.line-hover',
  );
  await expect(feedbackGlyph).toBeVisible();
  const feedbackGlyphBox = await feedbackGlyph.boundingBox();
  expect(feedbackGlyphBox).not.toBeNull();
  await page.mouse.click(
    feedbackGlyphBox.x + feedbackGlyphBox.width / 2,
    feedbackGlyphBox.y + feedbackGlyphBox.height / 2,
  );
  const feedbackInput = semanticDiff.locator(
    '.agent-feedback-input-widget textarea',
  );
  await expect(feedbackInput).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(feedbackInput).toBeHidden();

  await reviewToolbar.getByRole('button', { name: 'Line diff' }).click();
  await expect(reviewToolbar.getByRole('button', { name: 'Line diff' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await expect(layout.getByRole('button', { name: 'Unified diff layout' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );

  const progress = page.getByRole('button', { name: 'Mark file reviewed' });
  await progress.click();
  await expect(page.getByRole('button', { name: 'Mark file unreviewed' }))
    .toHaveAttribute('aria-pressed', 'true');
  await expect(changes.locator('.review-progress-summary')).toHaveText(
    '1 / 2 reviewed',
  );
  await page.getByRole('button', { name: 'Next change' }).click();
  await expect(library).toHaveAttribute('aria-current', 'page');
  await expect(page.locator('.review-nav-position')).toHaveText('File 2 of 2');
  await expect.poll(() => app.requests.find(request =>
    request.method === 'git.original_file' &&
    request.params?.path === 'src/lib.mbt' &&
    request.params?.revision === app.gitBaseline))
    .toBeTruthy();
  expect(app.pageErrors).toEqual([]);
});

for (const pendingMethod of ['git.original_file', 'fs.read_file']) {
  test(`Review navigation remains visible while ${pendingMethod} and diff computation finish`, async ({ page }) => {
    const app = new DesktopBrowserHarness(page);
    await page.setViewportSize({ width: 1120, height: 760 });
    const baseline = Array.from({ length: 15 }, (_, i) => [
      `fn changed_${i}() -> Int { 0 }`,
      ...Array.from({ length: 8 }, (_, j) => `fn same_${i}_${j}() -> Int { ${j} }`),
    ].join('\n')).join('\n');
    const contents = pendingMethod === 'fs.read_file' ? baseline.replaceAll('\n', '\r\n') : baseline;
    app.gitFilesByRevision[app.gitBaseline]['src/lib.mbt'] = contents;
    app.workingFiles['src/lib.mbt'] = contents.replaceAll('-> Int { 0 }', '-> Int { 10 }');
    const { promise: pending, resolve: release } = Promise.withResolvers();
    const replyFor = app.replyFor.bind(app);
    app.replyFor = async (request) => {
      if (request.method === pendingMethod && request.params?.path?.endsWith('/lib.mbt')) {
        await pending;
      }
      return replyFor(request);
    };
    await app.install();
    await app.goto();
    await app.openSession();
    await app.openReview();
    const changes = page.locator('#review-changes-body');
    await changes.getByRole('treeitem', { name: /View diff: src\/main\.mbt/ }).click();
    await page.getByRole('button', { name: 'Show file tree', exact: true }).click();
    const mode = page.getByRole('toolbar', { name: 'Review mode' });
    const line = mode.getByRole('button', { name: 'Line diff' });
    const layout = page.getByRole('group', { name: 'Diff layout' });
    const split = layout.getByRole('button', { name: 'Split diff layout' });
    await expect(line).toBeEnabled();
    await line.click();
    await changes.hover();
    await expect(split).toBeEnabled();
    await expect(page.locator('.review-hunk-position')).toHaveText('Change 1 of 1');

    const geometry = () => page.locator('.viewer-breadcrumb').evaluate(element => {
      const rect = element.getBoundingClientRect();
      const row = element.querySelector('.review-command-row')?.getBoundingClientRect();
      return { height: rect.height, rowY: row?.y, rowHeight: row?.height };
    });
    const navigationAppearance = () => page.locator('.review-command-row').evaluate(group =>
      Array.from(group.querySelectorAll('span, button')).map(element => {
        const style = getComputedStyle(element);
        return { text: element.textContent, color: style.color, background: style.backgroundColor, opacity: style.opacity };
      }));
    const appearanceBefore = await navigationAppearance();
    const before = await geometry();
    expect(before.rowY).toBeGreaterThan(0);
    // Sample rendered frames, including the gap after reads finish but before
    // the editor publishes its computed hunks. Never expose partial navigation.
    await page.evaluate(() => {
      window.reviewNavigationFrames = [];
      window.sampleReviewNavigation = true;
      const sample = () => {
        const group = document.querySelector('.review-navigation-controls');
        window.reviewNavigationFrames.push({
          visible: !!group?.getClientRects().length,
          breadcrumbLoading: document.querySelector('.viewer-breadcrumb')?.textContent.includes('Loading diff'),
          file: group?.querySelector('.review-nav-position')?.textContent,
          change: group?.querySelector('.review-hunk-position')?.textContent,
          buttons: Array.from(group?.querySelectorAll('button') ?? []).map(b => b.textContent.trim() || b.getAttribute('aria-label')),
        });
        if (window.sampleReviewNavigation) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    });
    try {
      await changes.getByRole('treeitem', { name: /View diff: src\/lib\.mbt/ }).click();
      await expect(page.locator('.crumb-file')).toHaveText('lib.mbt');
      await expect.poll(() => app.requests.some(request =>
        request.method === pendingMethod && request.params?.path?.endsWith('/lib.mbt')))
        .toBe(true);
      await expect(line).toBeDisabled();
      await expect(split).toBeDisabled();
      await expect(mode.getByRole('button', { name: 'Token diff' })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Ignore comments' })).toBeVisible();
      await expect(page.getByRole('button', { name: 'Ignore tests' })).toBeVisible();
      await expect(page.locator('.review-navigation-controls')).toBeVisible();
      await expect(page.locator('.review-navigation-controls')).toHaveAttribute('aria-busy', 'true');
      await expect(page.locator('.review-nav-position')).toHaveText('File 1 of 2');
      await expect(page.locator('.review-hunk-position')).toHaveText('Change 1 of 1');
      await expect(page.locator('.review-navigation-controls')).toHaveAttribute('inert', '');
      expect(await navigationAppearance()).toEqual(appearanceBefore);
      await expect(page.locator('.viewer-breadcrumb')).not.toContainText('Loading diff');
      // A deliberately held read eventually shows the delayed overlay. Its
      // timing is independent of whether navigation retains a complete display.
      await expect(page.locator('.viewer-notice')).toHaveText('Loading diff for lib.mbt…');
      await expect(page.locator('.review-navigation-controls')).toContainText('File 1 of 2');
      expect(await geometry()).toEqual(before);
    } finally {
      release();
    }
    await expect(line).toBeEnabled();
    await expect(split).toBeEnabled();
    await expect(page.locator('.review-hunk-position')).toHaveText('Change 1 of 15');
    await expect(page.locator('.review-navigation-controls')).toContainText('Mark viewed');
    await expect(page.locator('.review-nav-position')).toHaveText('File 2 of 2');
    await expect(page.locator('.review-navigation-controls')).toHaveAttribute('aria-busy', 'false');
    await expect(page.locator('.viewer-notice')).not.toContainText('Loading diff');
    const frames = await page.evaluate(() => {
      window.sampleReviewNavigation = false;
      return window.reviewNavigationFrames;
    });
    for (const frame of frames) {
      expect(frame.visible).toBe(true);
      expect(frame.breadcrumbLoading).toBe(false);
      expect(frame.change).toBe(frame.file === 'File 1 of 2' ? 'Change 1 of 1' : 'Change 1 of 15');
      expect(frame.buttons).toEqual(['Previous change', 'Next change', 'Mark viewed']);
    }
    expect(frames.length).toBeGreaterThan(0);
    expect(await geometry()).toEqual(before);
    expect(app.pageErrors).toEqual([]);
  });
}

test('Review routes Markdown source and keeps non-MoonBit comparisons on Line diff', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  const path = 'docs/Guide.MD';
  app.gitChanges = [{
    path,
    index_status: ' ',
    worktree_status: 'M',
    kind: 'modified',
  }];
  app.workingFiles[path] = '# Guide\n\nWorking tree documentation.\n';
  app.gitFilesByRevision[app.gitBaseline][path] = '# Guide\n\nBaseline documentation.\n';

  await app.install();
  await app.goto();
  await app.openSession();
  await app.openReview();

  await page.getByRole('treeitem', { name: /View diff: docs\/Guide\.MD/ }).click();
  const toolbar = page.getByRole('toolbar', { name: 'Review mode' });
  await expect(toolbar.getByRole('button')).toHaveText(['File', 'Line']);
  await expect(toolbar.getByRole('button', { name: 'Line diff' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await expect(page.getByRole('button', { name: 'Ignore comments' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Ignore tests' })).toHaveCount(0);

  await toolbar.getByRole('button', { name: 'File view' }).click();
  await expect(
    page.getByLabel('Readonly Markdown viewer')
      .getByText('Working tree documentation.', { exact: true }),
  ).toBeVisible();

  await toolbar.getByRole('button', { name: 'Line diff' }).click();
  await expect(toolbar.getByRole('button', { name: 'Line diff' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  expect(app.pageErrors).toEqual([]);
});
