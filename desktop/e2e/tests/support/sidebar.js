import { expect } from '@playwright/test';

// `goto()` returns once the shell is mounted, which can be before the host's
// project list arrives. Until then the main pane shows an onboarding card with
// its own "Add a project" button, so wait for the fixture project and address
// the sidebar's button through its landmark.
export async function sidebarAddProject(page) {
  const sidebar = page.getByRole('complementary');
  await expect(sidebar.getByRole('button', { name: 'workspace', exact: true })).toBeVisible();
  return sidebar.getByRole('button', { name: 'Add a project', exact: true });
}
