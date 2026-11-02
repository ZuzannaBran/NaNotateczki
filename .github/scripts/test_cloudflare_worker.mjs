import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { writeFile } from 'node:fs/promises';
import net from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';

const version = '4.156.1';
const wrangler = ['--yes', `--package=wrangler@${version}`, 'wrangler'];
const environment = { ...process.env, WRANGLER_SEND_METRICS: 'false' };
async function run(command, args, env = environment) {
  const child = spawn(command, args, { stdio: 'inherit', env });
  const [code] = await once(child, 'exit');
  assert.equal(code, 0, `${command} ${args.join(' ')} failed`);
}
await run('npx', [...wrangler, 'deploy', '--dry-run', '--config', 'wrangler.jsonc',
  '--outdir', 'build/worker-dry-run']);

const reservation = net.createServer();
reservation.listen(0, '127.0.0.1');
await once(reservation, 'listening');
const port = reservation.address().port;
await new Promise(resolve => reservation.close(resolve));
const origin = `http://127.0.0.1:${port}`;
const worker = spawn('npx', [...wrangler, 'dev', '--local', '--config', 'wrangler.jsonc',
  '--ip', '127.0.0.1', '--port', String(port), '--inspector-port', '0',
  '--persist-to', 'build/worker-local-state'], {
  env: environment, detached: process.platform !== 'win32',
  stdio: ['ignore', 'pipe', 'pipe'],
});
let log = '';
worker.stdout.on('data', chunk => { log += chunk; });
worker.stderr.on('data', chunk => { log += chunk; });
try {
  let ready = false;
  for (let attempt = 0; attempt < 300; attempt++) {
    assert.equal(worker.exitCode, null, log);
    try {
      const response = await fetch(`${origin}/nanotateczki-release.json`);
      if (response.ok) { ready = true; break; }
    } catch {}
    await delay(100);
  }
  assert(ready, `Workers runtime did not start.\n${log}`);
  assert(!/invalid redirect|Infinite loop|invalid header/i.test(log), log);
  assert(/Parsed 2 valid redirect rules/.test(log), log);
  await run('node', ['.github/scripts/test_web_local_assets.mjs'], {
    ...environment, WEB_ORIGIN: origin,
  });
  console.log('PASS Workers: dry-run, redirect/header validation and real browser runtime');
} catch (error) {
  console.error(log);
  throw error;
} finally {
  const stopped = once(worker, 'exit');
  if (process.platform === 'win32') worker.kill();
  else process.kill(-worker.pid, 'SIGTERM');
  await stopped;
  await writeFile('build/cloudflare-worker-test.log', log);
}
