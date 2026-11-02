import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import http from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const buildRoot = path.resolve('build/web');
const profile = await mkdtemp(path.join(tmpdir(), 'nanotateczki-web-test-'));
const requests = [];
const browserErrors = [];
const mimeTypes = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.wasm': 'application/wasm', '.json': 'application/json',
};
const server = http.createServer(async (request, response) => {
  try {
    let pathname = new URL(request.url, 'http://localhost').pathname;
    const subpath = pathname.startsWith('/app/');
    if (subpath) pathname = pathname.slice(4);
    if (pathname === '/' || pathname.startsWith('/share/')) {
      let html = await readFile(path.join(buildRoot, 'index.html'), 'utf8');
      if (subpath) html = html.replace('<base href="/">', '<base href="/app/">');
      response.writeHead(200, { 'Content-Type': 'text/html' }).end(html);
      return;
    }
    const file = path.resolve(buildRoot, `.${pathname}`);
    assert(file.startsWith(`${buildRoot}${path.sep}`));
    const bytes = await readFile(file);
    response.writeHead(200, {
      'Content-Type': mimeTypes[path.extname(file)] ?? 'application/octet-stream',
    }).end(bytes);
  } catch {
    response.writeHead(404).end();
  }
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');
const origin = `http://127.0.0.1:${server.address().port}`;
const chrome = spawn(process.env.CHROME_EXECUTABLE ?? 'google-chrome', [
  '--headless=new', '--no-sandbox', '--disable-dev-shm-usage',
  '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank',
], { stdio: 'ignore' });
let socket;
const pending = new Map();
let nextId = 0;
function send(method, params = {}) {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`CDP timeout: ${method}`)), 30000);
    pending.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ id, method, params }));
  });
}
async function evaluate(expression) {
  const result = await send('Runtime.evaluate', {
    expression, awaitPromise: true, returnByValue: true,
  });
  assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
async function waitFor(check, description) {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (await check()) return;
    await delay(100);
  }
  console.error(await evaluate(`JSON.stringify({
    body: document.body.innerHTML.slice(0, 7000),
    canvasKit: Boolean(window.flutterCanvasKit),
    pdf: Boolean(globalThis.pdfjsLib),
  })`));
  console.error(browserErrors);
  throw new Error(`Timed out: ${description}`);
}

// A valid single-page PDF exercises a real module worker and rasterization.
const stream = '1 0 0 rg 5 5 40 30 re f\n';
const objects = [
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 80 60] /Resources << >> /Contents 4 0 R >>',
  `<< /Length ${stream.length} >>\nstream\n${stream}endstream`,
];
let pdf = '%PDF-1.7\n';
const offsets = [0];
for (const [index, object] of objects.entries()) {
  offsets.push(pdf.length);
  pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
}
const xref = pdf.length;
pdf += `xref\n0 5\n0000000000 65535 f \n`;
pdf += offsets.slice(1).map(offset => `${String(offset).padStart(10, '0')} 00000 n \n`).join('');
pdf += `trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;

try {
  let debugPort;
  await waitFor(async () => {
    try {
      debugPort = (await readFile(path.join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0];
      return true;
    } catch { return false; }
  }, 'Chrome debugging port');
  const targets = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
  socket = new WebSocket(targets.find(target => target.type === 'page').webSocketDebuggerUrl);
  await once(socket, 'open');
  socket.addEventListener('message', ({ data }) => {
    const message = JSON.parse(data);
    if (message.method === 'Network.requestWillBeSent') requests.push(message.params.request.url);
    if (message.method === 'Runtime.exceptionThrown') browserErrors.push(message.params);
    if (message.method === 'Network.loadingFailed') browserErrors.push(message.params);
    if (!message.id) return;
    const task = pending.get(message.id);
    if (!task) return;
    pending.delete(message.id);
    clearTimeout(task.timer);
    if (message.error) task.reject(new Error(JSON.stringify(message.error)));
    else task.resolve(message.result);
  });
  await send('Network.enable');
  await send('Runtime.enable');
  await send('Network.setBlockedURLs', {
    urls: ['*://*.gstatic.com/*', '*://cdn.jsdelivr.net/*'],
  });
  for (const route of ['/', '/share/test-session', '/app/share/test-session']) {
    const requestStart = requests.length;
    await send('Page.navigate', { url: `${origin}${route}` });
    await waitFor(() => evaluate(
      `Boolean(window.flutterCanvasKit && globalThis.pdfjsLib &&
        document.querySelector('flt-glass-pane')?.shadowRoot?.querySelector('canvas'))`,
    ), `Flutter frame at ${route}`);
    const result = await evaluate(`(async () => {
      const task = pdfjsLib.getDocument({
        data: Uint8Array.from(atob(${JSON.stringify(Buffer.from(pdf).toString('base64'))}), c => c.charCodeAt(0)),
        ...globalThis.pdfRenderOptions,
      });
      const document = await task.promise;
      const page = await document.getPage(1);
      const canvas = globalThis.document.createElement('canvas');
      canvas.width = 80; canvas.height = 60;
      const context = canvas.getContext('2d');
      await page.render({canvasContext: context, viewport: page.getViewport({scale: 1})}).promise;
      const pixel = Array.from(context.getImageData(10, 40, 1, 1).data);
      const cMapUrl = globalThis.pdfRenderOptions.cMapUrl;
      const cMapResponse = await fetch(cMapUrl + 'UniJIS-UTF16-H.bcmap');
      const mapSize = (await cMapResponse.arrayBuffer()).byteLength;
      await task.destroy();
      return {pixel, cMapUrl, mapSize};
    })()`);
    assert.deepEqual(result.pixel, [255, 0, 0, 255]);
    assert(result.mapSize > 1000);
    const prefix = route.startsWith('/app/') ? '/app/' : '/';
    assert.equal(result.cMapUrl, `${origin}${prefix}vendor/pdfjs/4.6.82/cmaps/`);
    const pageRequests = requests.slice(requestStart);
    assert(pageRequests.some(url => url.includes('/canvaskit/') && url.endsWith('.wasm')));
    assert(pageRequests.some(url => url.endsWith('/pdf.worker.min.mjs')));
    assert(!pageRequests.some(url => /gstatic\.com|cdn\.jsdelivr\.net/.test(url)));
    console.log(`PASS ${route}: Flutter frame, PDF worker/render and local CMap; CDN blocked`);
  }
} finally {
  if (socket) socket.close();
  for (const task of pending.values()) clearTimeout(task.timer);
  const stopped = once(chrome, 'exit');
  chrome.kill();
  await stopped;
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  await rm(profile, { recursive: true, force: true });
}
