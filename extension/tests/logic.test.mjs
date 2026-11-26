// Loads the real background scripts into a Node vm with a fake `chrome` API whose
// connectNative spawns the BUILT ParabolicHost, so host.js/settings.js are exercised against
// the real protocol. Downloads are never sent to the app (Host.download is stubbed).
// Usage: node extension/tests/logic.test.mjs [path/to/ParabolicHost]
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { makeBrowser, tick } from './fake-browser.mjs';
import { catchTests } from './catch.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const hostPath = process.argv[2] || join(root, '.build/debug/ParabolicHost');
const manifest = JSON.parse(readFileSync(join(root, 'extension/manifest.base.json'), 'utf8'));

let passed = 0;
async function test(name, fn) {
  await fn();
  passed += 1;
  console.log(`PASS  ${name}`);
}

// ---- Firefox profile (IS_FIREFOX, no onDeterminingFilename): the onCreated path -------------
const ff = makeBrowser({ root, hostPath, manifest, firefox: true });
const { chrome, calls, run, ask } = ff;

await test('Host.handshake over the real host', async () => {
  const reply = await run('Host.handshake()');
  assert.equal(reply.ok, true);
  assert.equal(reply.app, 'Parabolic');
});

await test('Settings.get normalises real host settings (incl. catchEverything, showCatchWindow)', async () => {
  const rules = await run('Settings.get({ force: true })');
  assert.ok(rules.catchExtensions.includes('zip'));
  assert.ok(Array.isArray(rules.presets) && rules.presets.length >= 4);
  assert.equal(typeof rules.minSizeMB, 'number');
  assert.equal(typeof rules.catchEverything, 'boolean');
  assert.equal(typeof rules.showCatchWindow, 'boolean');
});

await test('popup bridge: handshake, status, catchState, setCatch', async () => {
  assert.equal((await ask({ cmd: 'handshake' })).ok, true);
  const status = await ask({ cmd: 'status' });
  assert.equal(status.ok, true);
  assert.ok(Array.isArray(status.items));
  const state = await ask({ cmd: 'setCatch', value: false });
  assert.equal(state.catching, false);
  assert.equal(state.override, false);
  assert.equal((await ask({ cmd: 'setCatch', value: true })).catching, true);
  await ask({ cmd: 'setEverything', value: false }); // deterministic regardless of the app's setting
});

await test('popup bridge ignores other senders', async () => {
  const handled = chrome.runtime.onMessage.fns[0]({ cmd: 'status' }, { id: 'evil', url: 'https://evil.test/' }, () => {});
  assert.equal(handled, false);
  const fromTab = chrome.runtime.onMessage.fns[0]({ cmd: 'setCatch', value: false },
    { id: chrome.runtime.id, url: 'https://page.test/', tab: { id: 3 } }, () => {});
  assert.equal(fromTab, false, 'content scripts cannot drive popup commands');
});

const rules = { catchExtensions: ['zip', 'dmg', 'mp4'], minSizeMB: 1, skipHosts: ['skip.me'], presets: [] };
const decide = (d, r = rules) => run(`Catcher.decide(${JSON.stringify(d)}, ${JSON.stringify(r)})`);
await test('Catcher.decide', async () => {
  assert.equal(decide({ url: 'https://a.com/x.zip', totalBytes: 5e6 }), 'catch');
  assert.equal(decide({ url: 'https://a.com/x.zip', totalBytes: 10 }), 'skip', 'below min size');
  assert.equal(decide({ url: 'https://a.com/x.torrent', totalBytes: 10 }), 'catch', 'torrents ignore size');
  assert.equal(decide({ url: 'https://a.com/get', mime: 'application/x-bittorrent' }), 'catch');
  assert.equal(decide({ url: 'https://a.com/dl?id=1', mime: 'application/zip', totalBytes: 0 }), 'catch', 'by MIME');
  assert.equal(decide({ url: 'https://cdn.skip.me/x.zip' }), 'skip', 'skip host');
  assert.equal(decide({ url: 'https://cdn.other/x.zip', referrer: 'https://www.skip.me/p' }), 'skip', 'skip host of the page');
  assert.equal(decide({ url: 'blob:https://a.com/1' }), 'skip');
  assert.equal(decide({ url: 'data:text/plain,hi' }), 'skip');
  assert.equal(decide({ url: 'file:///x.zip' }), 'skip');
  assert.equal(decide({ url: 'https://a.com/x.zip', byExtensionId: chrome.runtime.id }), 'skip', 'our own download');
  assert.equal(decide({ url: 'https://a.com/x.txt', filename: '/tmp/x.txt' }), 'skip');
  assert.equal(decide({ url: 'https://a.com/get' }), 'unknown', 'filename not known yet');
});

await test('unknown size: a type match is caught even when the size is 0 / -1', async () => {
  const big = { ...rules, minSizeMB: 500 };
  assert.equal(decide({ url: 'https://a.com/x.zip', filename: 'x.zip', totalBytes: 0, fileSize: -1 }, big), 'catch');
  assert.equal(decide({ url: 'https://a.com/x.zip', filename: 'x.zip', totalBytes: 0, fileSize: 9e6 }, big), 'skip', 'known small size');
  assert.equal(decide({ url: 'https://a.com/x.mp4', filename: 'x.mp4', totalBytes: 6e8 }, big), 'catch');
});

await test('catch everything: any http(s) type and size, never blob:/data:/file:', async () => {
  const all = { ...rules, catchEverything: true };
  assert.equal(decide({ url: 'https://a.com/notes.txt', filename: 'notes.txt', totalBytes: 12 }, all), 'catch');
  assert.equal(decide({ url: 'https://a.com/get?id=1', totalBytes: 0 }, all), 'catch', 'no name or size yet');
  assert.equal(decide({ url: 'http://a.com/page.html', filename: 'page.html' }, all), 'catch');
  for (const url of ['blob:https://a.com/1', 'data:text/plain,hi', 'file:///x.txt']) assert.equal(decide({ url }, all), 'skip', url);
  assert.equal(decide({ url: 'https://cdn.skip.me/a.txt' }, all), 'skip', 'excluded hosts still win');
  assert.equal(decide({ url: 'https://a.com/x.txt', byExtensionId: chrome.runtime.id }, all), 'skip');
});

await test('catch flow: cancel + erase + hand off with headers', async () => {
  run('globalThis.sent = []; Host.download = async (action, items, preset) => { sent.push({ action, items, preset }); return { ok: true, count: items.length }; };');
  calls.length = 0;
  await chrome.downloads.onCreated.fns[0]({ id: 3, url: 'https://files.example/app.dmg', referrer: 'https://files.example/', totalBytes: 9e9, filename: '' });
  await tick(50);
  const sent = run('sent');
  assert.deepEqual(calls.map((c) => c[0]).slice(0, 2), ['cancel', 'erase']);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].action, 'catch');
  const [item] = sent[0].items;
  assert.equal(item.url, 'https://files.example/app.dmg');
  assert.equal(item.cookies, 'sid=42; lang=en');
  assert.equal(item.referrer, 'https://files.example/');
  assert.equal(item.userAgent, 'TestAgent/1.0');
  assert.ok(calls.some((c) => c[0] === 'badge' && c[1].text === '✓'), 'green check badge');
  assert.ok(calls.some((c) => c[0] === 'badgeColor' && c[1].color === '#34C759'));
});

await test('catch flow: host failure re-issues once and notifies', async () => {
  run("Host.download = async () => { throw new HostError('boom'); };");
  calls.length = 0;
  const download = { id: 4, url: 'https://files.example/b.zip', referrer: 'https://files.example/', totalBytes: 9e9, filename: '' };
  await chrome.downloads.onCreated.fns[0](download);
  await tick(50);
  const names = calls.map((c) => c[0]);
  assert.ok(names.includes('download') && names.includes('notify'), names.join(','));
  assert.equal(decide({ ...download, id: 5 }), 'skip', 're-issued URL is not caught again');
});

await test('Sniffer.classify', async () => {
  const classify = (d) => run(`Sniffer.classify(${JSON.stringify(d)})`);
  const h = (type, len) => [{ name: 'Content-Type', value: type }, { name: 'Content-Length', value: String(len) }];
  assert.equal(classify({ tabId: 1, statusCode: 200, type: 'xmlhttprequest', url: 'https://v.com/master.m3u8', responseHeaders: h('application/vnd.apple.mpegurl', 900) }).kind, 'HLS');
  assert.equal(classify({ tabId: 1, statusCode: 200, type: 'xmlhttprequest', url: 'https://v.com/m', responseHeaders: h('application/dash+xml', 900) }).kind, 'DASH');
  assert.equal(classify({ tabId: 1, statusCode: 200, type: 'media', url: 'https://v.com/a.mp4', responseHeaders: h('video/mp4', 5e6) }).kind, 'MP4');
  assert.equal(classify({ tabId: 1, statusCode: 200, type: 'media', url: 'https://v.com/tiny.mp4', responseHeaders: h('video/mp4', 1000) }), null);
  assert.equal(classify({ tabId: 1, statusCode: 200, type: 'xmlhttprequest', url: 'https://v.com/seg1.ts', responseHeaders: h('video/mp2t', 5e6) }), null);
  assert.equal(classify({ tabId: -1, statusCode: 200, type: 'media', url: 'https://v.com/a.mp4', responseHeaders: h('video/mp4', 5e6) }), null);
  assert.equal(classify({ tabId: 1, statusCode: 200, type: 'image', url: 'https://v.com/a.png', responseHeaders: h('image/png', 5e6) }), null);
});

await test('Sniffer tracks per tab, de-dupes, clears on navigation', async () => {
  const fire = (d) => chrome.webRequest.onHeadersReceived.fns[0](d);
  const media = { tabId: 9, statusCode: 200, type: 'media', url: 'https://v.com/a.webm', responseHeaders: [{ name: 'content-type', value: 'video/webm' }] };
  fire(media); fire(media);
  await tick();
  assert.equal((await ask({ cmd: 'media', tabId: 9 })).items.length, 1);
  fire({ tabId: 9, statusCode: 200, type: 'main_frame', url: 'https://v.com/next', responseHeaders: [{ name: 'content-type', value: 'text/html' }] });
  await tick();
  assert.equal((await ask({ cmd: 'media', tabId: 9 })).items.length, 0);
});

await test('context menus include preset submenu and per-site rules', async () => {
  calls.length = 0;
  await run('Menus.install()');
  const ids = calls.filter((c) => c[0] === 'menu').map((c) => c[1]);
  for (const id of ['pb-quick', 'pb-add', 'pb-presets', 'pb-page-video', 'pb-selected', 'pb-all', 'pb-site-never', 'pb-site-always']) {
    assert.ok(ids.includes(id), id);
  }
  assert.ok(ids.includes('pb-preset:Best Video'));
});

// ---- Chromium-shaped profile: onDeterminingFilename, click catching, per-site rules ----------
passed += await catchTests({ makeBrowser: () => makeBrowser({ root, hostPath, manifest, determining: true }), test: async (name, fn) => {
  await fn();
  console.log(`PASS  ${name}`);
} });

console.log(`\n${passed} passed`);
process.exit(0);
