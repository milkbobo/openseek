import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

async function diagramViewportFillsHost(host) {
  return host.evaluate((element) => {
    const viewport = element.querySelector(
      ':scope > .moonbit-viewer-markdown-diagram-viewport',
    );
    if (!viewport) return false;
    const hostRect = element.getBoundingClientRect();
    const viewportRect = viewport.getBoundingClientRect();
    return [
      viewportRect.left - hostRect.left,
      viewportRect.top - hostRect.top,
      viewportRect.right - hostRect.right,
      viewportRect.bottom - hostRect.bottom,
    ].every((delta) => Math.abs(delta) <= 1);
  });
}

test('ordinary MBTI files default to source, render UML on demand, and reviews keep source surfaces', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  const path = 'api/pkg.generated.mbti';
  const working = [
    'package "fixture/api"',
    '',
    'pub struct Point {',
    '  x : Double',
    '  y : Double',
    '}',
    '',
    'pub trait Shape {',
    '  area(Self) -> Double',
    '}',
    '',
    'impl Shape for Point',
  ].join('\n');
  const baseline = working.replace('  y : Double\n', '');
  app.searchFiles = [path];
  app.workingFiles[path] = working;
  app.gitChanges = [{
    path,
    index_status: ' ',
    worktree_status: 'M',
    kind: 'modified',
  }];
  app.gitFilesByRevision[app.gitBaseline][path] = baseline;

  await app.install();
  await app.goto();
  await app.openSession();
  await app.openQuickOpen();
  await page.getByRole('option', { name: /pkg\.generated\.mbti/ }).click();

  const diagram = page.locator('#mbti-diagram-host');
  const view = page.getByRole('group', { name: 'MBTI view' });
  await expect(page.locator('#viewer-host')).toBeVisible();
  await expect(page.locator('#viewer-host')).toContainText('Point');
  await expect(view.getByRole('button', { name: 'Source' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await expect(diagram).toBeHidden();
  await view.getByRole('button', { name: 'Diagram' }).click();

  await expect(diagram).toBeVisible();
  await expect(page.locator('#viewer-host')).toBeHidden();
  await expect(diagram.locator('svg')).toBeVisible();
  await expect(diagram.locator('svg')).toContainText('Point');
  await expect(
    diagram.getByRole('toolbar', { name: 'UML diagram controls' }),
  ).toBeVisible();
  await expect(
    diagram.getByRole('button', { name: 'Zoom in' }),
  ).toBeVisible();
  await expect.poll(() => diagramViewportFillsHost(diagram)).toBe(true);
  await expect(
    diagram.getByRole('separator', { name: 'Resize diagram' }),
  ).toHaveCount(0);
  await expect(view.getByRole('button')).toHaveText(['Diagram', 'Source']);
  await expect(view.getByRole('button', { name: 'Diagram' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );

  await view.getByRole('button', { name: 'Source' }).click();
  await expect(diagram).toBeHidden();
  await expect(page.locator('#viewer-host')).toBeVisible();
  await expect(page.locator('#viewer-host')).toContainText('Point');
  await expect(view.getByRole('button', { name: 'Source' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await view.getByRole('button', { name: 'Diagram' }).click();
  await expect(diagram.locator('svg')).toBeVisible();

  await app.openReview();
  await page.getByRole('treeitem', { name: /View diff: api\/pkg\.generated\.mbti/ }).click();
  await expect(page.getByRole('group', { name: 'MBTI view' })).toHaveCount(0);
  await expect(diagram).toBeHidden();
  const review = page.getByRole('toolbar', { name: 'Review mode' });
  await expect(review.getByRole('button', { name: 'Line diff' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await review.getByRole('button', { name: 'File view' }).click();
  await expect(page.locator('#viewer-host')).toBeVisible();
  await expect(page.locator('#viewer-host')).toContainText('Point');
  await expect(diagram).toBeHidden();
  expect(app.pageErrors).toEqual([]);
});

test('ordinary moon.mod defaults to source and loads its package graph on demand', async ({ page }) => {
  const app = new DesktopBrowserHarness(page);
  const path = 'moon.mod';
  const working = [
    'name = "example/app"',
    'version = "0.1.0"',
    '',
  ].join('\n');
  app.searchFiles = [path];
  app.workingFiles[path] = working;

  await app.install();
  await app.goto();
  await app.openSession();
  await app.openQuickOpen();
  await page.getByRole('option', { name: /moon\.mod/ }).click();

  const diagram = page.locator('#package-diagram-host');
  const view = page.getByRole('group', { name: 'Moon module view' });
  await expect(page.locator('#viewer-host')).toBeVisible();
  await expect(page.locator('#viewer-host')).toContainText('example/app');
  await expect(view.getByRole('button', { name: 'Source' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  await expect(diagram).toBeHidden();
  expect(app.requests.filter(
    request => request.method === 'moon.package_graph',
  )).toHaveLength(0);
  await view.getByRole('button', { name: 'Dependency graph' }).click();

  await expect.poll(() => app.requests.find(
    request => request.method === 'moon.package_graph',
  )).toMatchObject({
    params: {
      session: 'session-1',
      root: '/workspace',
      path: 'moon.mod',
    },
  });
  await expect(diagram).toBeVisible();
  await expect(diagram.locator('svg')).toBeVisible();
  await expect(diagram.locator('svg')).toContainText('main');
  await expect(diagram.locator('svg')).toContainText('core');
  await expect(diagram.locator('svg')).toContainText('util');
  await expect(
    diagram.getByRole('toolbar', { name: 'UML diagram controls' }),
  ).toBeVisible();
  await expect(
    diagram.getByRole('button', { name: 'Fit diagram' }),
  ).toBeVisible();
  await expect.poll(() => diagramViewportFillsHost(diagram)).toBe(true);
  await expect(
    diagram.getByRole('separator', { name: 'Resize diagram' }),
  ).toHaveCount(0);

  await expect(view.getByRole('button')).toHaveText(['Dependency graph', 'Source']);
  await expect(
    view.getByRole('button', { name: 'Dependency graph' }),
  ).toHaveAttribute('aria-pressed', 'true');

  await view.getByRole('button', { name: 'Source' }).click();
  await expect(diagram).toBeHidden();
  await expect(page.locator('#viewer-host')).toBeVisible();
  await expect(page.locator('#viewer-host')).toContainText('example/app');
  await expect(view.getByRole('button', { name: 'Source' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );

  await view.getByRole('button', { name: 'Dependency graph' }).click();
  await expect(diagram.locator('svg')).toBeVisible();
  expect(app.requests.filter(
    request => request.method === 'moon.package_graph',
  )).toHaveLength(1);
  expect(app.pageErrors).toEqual([]);
});
