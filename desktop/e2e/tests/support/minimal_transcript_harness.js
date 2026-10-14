import { expect } from '@playwright/test';
import { DesktopBrowserHarness } from './desktop_browser_harness.js';

// Exercise the production transport and renderer with recorded events. Fixtures
// deliberately contain parameters, output, and reasoning that must never enter
// the minimal subtree, even after every disclosure has been opened.
export class MinimalTranscriptHarness extends DesktopBrowserHarness {
  constructor(page) {
    super(page);
    this.sessionEvents = [
      { sequence: 1, item: { kind: 'user', payload: { content: 'Show the browser fixture minimal mode' } } },
      { sequence: 2, item: { kind: 'assistant', payload: {
        content: 'I will explore this project.',
        reasoning_content: 'REASONING_SENTINEL',
        tool_calls: [
          { id: 'read-a', name: 'read', arguments: '{"path":"PARAMETER_SENTINEL"}' },
          { id: 'read-b', name: 'read', arguments: '{"path":"second"}' },
        ],
      } } },
      { sequence: 3, item: { kind: 'tool_result', payload: {
        tool_call_id: 'read-a', tool_name: 'read', content: 'OUTPUT_SENTINEL',
        is_error: false, brief: 'Read the project manifest',
      } } },
      { sequence: 4, item: { kind: 'tool_result', payload: {
        tool_call_id: 'read-b', tool_name: 'read', content: 'OUTPUT_SENTINEL',
        is_error: true, brief: 'Cannot read the second file',
      } } },
      { sequence: 5, item: { kind: 'assistant', payload: {
        content: '', tool_calls: [{ id: 'script', name: 'mbtx', arguments: JSON.stringify({
          description: 'Check project details', script: 'SCRIPT_SENTINEL',
        }) }],
      } } },
      { sequence: 6, item: { kind: 'assistant', payload: { content: 'Now I can check the remaining details.' } } },
    ];
  }

  replyFor(request) {
    if (request.method === 'host.open_path' && request.params.path === 'src/main.mbt') {
      return { opened: false, editor_target: { path: '/workspace/src/main.mbt' } };
    }
    return super.replyFor(request);
  }

  // The titlebar debug toggle is off while the minimal transcript is shown.
  async enableMinimal() {
    await this.openSession();
    await expect(this.page.locator('#stream .minimal-tools, #stream .minimal-tools-live, #stream .minimal-process, #stream .minimal-single-call').first()).toBeVisible();
  }

  detailedMode() {
    return this.page.getByRole('button', { name: 'Detailed mode', exact: true });
  }

  append(kind, payload, ts) {
    const sequence = (this.sessionEvents.at(-1)?.sequence || 0) + 1;
    const event = { sequence, ts, item: { kind, payload } };
    this.sessionEvents.push(event);
    this.notify('session.event', {
      session: 'session-1', session_root: '/workspace/.openseek', sequence, event,
    });
  }
}
