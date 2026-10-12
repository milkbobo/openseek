import { test, expect } from '@playwright/test';
import { DesktopBrowserHarness } from './support/desktop_browser_harness.js';

const configPath = '/home/user/.openseek/mcp.json';

function mcpGroup(page) {
  return page.locator('.settings-group', {
    has: page.getByRole('heading', { name: 'MCP', exact: true }),
  });
}

function statusRequests(app) {
  return app.requests.filter(request => request.method === 'mcp.status');
}

test('Settings lists MCP servers with what connecting to each one yields', async ({ page }, testInfo) => {
  const app = new DesktopBrowserHarness(page);
  app.mcpStatus = {
    config: 'loaded',
    path: configPath,
    servers: [
      {
        name: 'playwright',
        transport: 'stdio',
        target: 'npx',
        state: 'connected',
        tools: [
          { name: 'mcp__playwright__browser_navigate', description: 'Navigate to a URL' },
          { name: 'mcp__playwright__browser_click', description: 'Perform click on a web page' },
        ],
      },
      {
        name: 'docs',
        transport: 'http',
        target: 'https://example.com/mcp',
        state: 'failed',
        error: 'JSON-RPC error -32000: MCP endpoint exchange failed',
      },
      { name: 'notes', transport: 'stdio', target: 'notes-mcp', state: 'no_tools' },
    ],
  };
  await app.install();
  await app.goto();
  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  const group = mcpGroup(page);

  await expect(group.getByText('playwright', { exact: true })).toBeVisible();
  await expect(group.getByText('stdio · npx', { exact: true })).toBeVisible();
  await expect(group.getByText('Connected', { exact: true })).toBeVisible();
  await expect(group.getByText('Failed', { exact: true })).toBeVisible();
  await expect(group.getByText('JSON-RPC error -32000: MCP endpoint exchange failed')).toBeVisible();
  await expect(group.getByText('No tools', { exact: true })).toBeVisible();

  // The tools stay folded until asked for.
  const tool = group.getByText('mcp__playwright__browser_click', { exact: true });
  await expect(tool).toBeHidden();
  await group.getByText('2 tools', { exact: true }).click();
  await expect(tool).toBeVisible();
  await group.screenshot({ path: testInfo.outputPath('mcp-servers.png') });

  // Opening Settings asked the host exactly once.
  expect(statusRequests(app)).toHaveLength(1);
  expect(app.pageErrors).toEqual([]);
});

test('MCP status is asked again only on request, and says why a file is unusable', async ({ page }, testInfo) => {
  const app = new DesktopBrowserHarness(page);
  await app.install();
  await app.goto();
  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  const group = mcpGroup(page);
  await expect(group.getByText(`Nothing is configured yet. Create ${configPath} to add servers.`)).toBeVisible();

  // Leaving and reopening Settings must not start the user's servers again.
  await page.getByRole('button', { name: 'Skills', exact: true }).click();
  await page.getByRole('button', { name: 'Settings', exact: true }).click();
  await expect(group.getByRole('button', { name: 'Check again', exact: true })).toBeVisible();
  expect(statusRequests(app)).toHaveLength(1);

  app.mcpStatus = {
    config: 'rejected',
    path: configPath,
    reason: 'mcp config error: configuration is missing an `mcpServers` object',
  };
  await group.getByRole('button', { name: 'Check again', exact: true }).click();
  await expect(group.getByText(`${configPath} could not be loaded`, { exact: true })).toBeVisible();
  await expect(group.getByText('configuration is missing an `mcpServers` object')).toBeVisible();
  await group.screenshot({ path: testInfo.outputPath('mcp-config-rejected.png') });
  expect(statusRequests(app)).toHaveLength(2);

  // A check that cannot run is reported as that, not as an empty list.
  app.rpcErrors.set('mcp.status', 'checking the MCP servers timed out');
  await group.getByRole('button', { name: 'Check again', exact: true }).click();
  await expect(group.getByText('The check could not run', { exact: true })).toBeVisible();
  await expect(group.getByText('checking the MCP servers timed out')).toBeVisible();
  expect(app.pageErrors).toEqual([]);
});
