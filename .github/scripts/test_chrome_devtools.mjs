import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { waitForChromePage } from './chrome_devtools.mjs';

async function profile(t) {
  const dir = await mkdtemp(path.join(tmpdir(), 'test-chrome-devtools-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}

test('waits for DevTools to listen and then for a page to appear', async t => {
  const dir = await profile(t);
  const portFile = path.join(dir, 'DevToolsActivePort');
  await writeFile(portFile, '9222\n/devtools/browser/test\n');
  const url = 'ws://127.0.0.1:9222/devtools/page/test';
  const fetch = t.mock.method(globalThis, 'fetch', async () => {
    switch (fetch.mock.callCount()) {
      case 0:
        throw new TypeError('fetch failed', { cause: { code: 'ECONNREFUSED' } });
      case 1:
        return Response.json([{ type: 'worker', webSocketDebuggerUrl: url }]);
      default:
        return Response.json([{ type: 'page', webSocketDebuggerUrl: url }]);
    }
  });
  assert.equal(await waitForChromePage(dir, { pollIntervalMs: 5 }), url);
  assert.equal(fetch.mock.callCount(), 3);
  for (const call of fetch.mock.calls) {
    assert.equal(call.arguments[0], 'http://127.0.0.1:9222/json/list');
  }
});

test('incomplete file cannot send requests to the default HTTP port', async t => {
  const dir = await profile(t);
  await writeFile(path.join(dir, 'DevToolsActivePort'), '\n');
  const fetch = t.mock.method(globalThis, 'fetch');
  await assert.rejects(
    waitForChromePage(dir, { timeoutMs: 30, pollIntervalMs: 5 }),
    /Timed out.*DevToolsActivePort is incomplete or invalid/,
  );
  assert.equal(fetch.mock.callCount(), 0);
});

test('an actual DevTools HTTP error is not retried as startup delay', async t => {
  const dir = await profile(t);
  await writeFile(path.join(dir, 'DevToolsActivePort'), '9222\n/devtools/browser/test');
  const fetch = t.mock.method(globalThis, 'fetch', async () => new Response(null, { status: 403 }));
  await assert.rejects(waitForChromePage(dir), /Chrome DevTools returned HTTP 403/);
  assert.equal(fetch.mock.callCount(), 1);
});
