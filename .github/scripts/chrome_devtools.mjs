import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

export async function waitForChromePage(profile, {
  timeoutMs = 20000, pollIntervalMs = 100,
} = {}) {
  const deadline = performance.now() + timeoutMs;
  let lastStatus = 'DevToolsActivePort has not been written';
  while (performance.now() < deadline) {
    let activePort = '';
    try {
      activePort = await readFile(path.join(profile, 'DevToolsActivePort'), 'utf8');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (activePort) {
      const [port, browserPath] = activePort.split(/\r?\n/, 2);
      if (/^[1-9]\d{0,4}$/.test(port) && Number(port) <= 65535 &&
          browserPath?.startsWith('/devtools/browser/')) {
        let response;
        try {
          response = await fetch(`http://127.0.0.1:${port}/json/list`, {
            signal: AbortSignal.timeout(Math.max(1, Math.ceil(deadline - performance.now()))),
          });
        } catch (error) {
          if (error.cause?.code !== 'ECONNREFUSED' && error.name !== 'TimeoutError') {
            throw error;
          }
          lastStatus = `Chrome port ${port} has not answered: ${error.cause?.code ?? error.name}`;
        }
        if (response) {
          if (!response.ok) throw new Error(`Chrome DevTools returned HTTP ${response.status}`);
          const targets = await response.json();
          const page = targets.find(target => target.type === 'page' && target.webSocketDebuggerUrl);
          if (page) return page.webSocketDebuggerUrl;
          lastStatus = 'Chrome DevTools is listening but has not registered a page';
        }
      } else {
        lastStatus = 'DevToolsActivePort is incomplete or invalid';
      }
    }
    const remaining = deadline - performance.now();
    if (remaining > 0) await delay(Math.min(pollIntervalMs, remaining));
  }
  throw new Error(`Timed out waiting for a Chrome DevTools page: ${lastStatus}`);
}
