// Chromium-shaped catching tests: onDeterminingFilename (suggest exactly once), click-time
// catching in the content script (with and without ⌥), catch everything, duplicate
// suppression, per-site never/always rules and the page-level fallback. Host.settings and
// Host.download are stubbed so results don't depend on the user's Parabolic preferences.
import assert from 'node:assert/strict';
import { tick } from './fake-browser.mjs';

const SETTINGS = {
  ok: true, catchDownloads: true, catchExtensions: 'zip dmg pdf torrent mp4', minSizeMB: 1,
  skipHosts: 'skip.me', presets: ['Best Video'], catchEverything: false, showCatchWindow: true,
};
const PAGE = 'https://shop.example/downloads';

export async function catchTests({ makeBrowser, test }) {
  let count = 0;
  const t = async (name, fn) => { await test(name, fn); count += 1; };
  const b = makeBrowser();
  const { chrome, calls, run, ask, store } = b;
  run(`Host.settings = async () => (${JSON.stringify(SETTINGS)});
    globalThis.sent = [];
    globalThis.okDownload = async (action, items) => { sent.push({ action, items }); return { ok: true, count: items.length }; };
    Host.download = okDownload;`);
  await run('Settings.get({ force: true })');
  const sent = () => run('sent');
  const names = () => calls.map((c) => c[0]);

  /** Fires onDeterminingFilename; returns { returned, suggestions() }. */
  function determine(download) {
    let suggestions = 0;
    const suggest = (...args) => { assert.equal(args.length, 0, 'suggest() keeps the browser’s name'); suggestions += 1; calls.push(['suggest']); };
    const returned = chrome.downloads.onDeterminingFilename.fns[0](download, suggest);
    return { returned, suggestions: () => suggestions };
  }

  await t('onDeterminingFilename: catch → cancel + erase, then suggest exactly once, then hand off', async () => {
    calls.length = 0;
    const d = determine({ id: 11, url: 'https://files.example/c.dmg', referrer: 'https://files.example/get',
      filename: 'c.dmg', totalBytes: 5e6, mime: 'application/x-apple-diskimage' });
    assert.equal(d.returned, true, 'async suggest');
    await tick(60);
    assert.equal(d.suggestions(), 1);
    assert.deepEqual(names().filter((n) => ['cancel', 'erase', 'suggest'].includes(n)), ['cancel', 'erase', 'suggest']);
    const last = sent().at(-1);
    assert.equal(last.action, 'catch');
    assert.deepEqual([last.items[0].url, last.items[0].filename, last.items[0].size], ['https://files.example/c.dmg', 'c.dmg', 5e6]);
    assert.equal(last.items[0].referrer, 'https://files.example/get');
  });

  await t('onDeterminingFilename: skip → suggest exactly once, nothing cancelled', async () => {
    calls.length = 0;
    const plain = determine({ id: 12, url: 'https://files.example/readme.txt', filename: 'readme.txt', totalBytes: 9e6 });
    const own = determine({ id: 13, url: 'https://files.example/x.zip', filename: 'x.zip', byExtensionId: chrome.runtime.id });
    assert.equal(own.returned, false, 'our own fallback download is released synchronously');
    assert.equal(own.suggestions(), 1);
    const small = determine({ id: 14, url: 'https://files.example/tiny.zip', filename: 'tiny.zip', totalBytes: 2000 });
    await tick(60);
    assert.equal(plain.suggestions(), 1);
    assert.equal(small.suggestions(), 1);
    assert.ok(!names().includes('cancel'));
    await ask({ cmd: 'setCatch', value: false });
    const off = determine({ id: 15, url: 'https://files.example/off.zip', filename: 'off.zip', totalBytes: 5e6 });
    await tick(60);
    assert.equal(off.suggestions(), 1);
    assert.ok(!names().includes('cancel'), 'catching off');
    await ask({ cmd: 'setCatch', value: true });
  });

  await t('host failure on a browser download: suggest once, downloads.download, never caught again', async () => {
    run("Host.download = async () => { throw new HostError('boom'); };");
    calls.length = 0;
    const url = 'https://dl.example.com/fail.zip?a=1';
    const d = determine({ id: 16, url, referrer: 'https://example.com/page', filename: 'fail.zip', totalBytes: 5e6 });
    await tick(60);
    assert.equal(d.suggestions(), 1);
    // A second page download would trip Chromium's "download multiple files" limiter.
    assert.ok(names().includes('download') && !names().includes('executeScript'), names().join(','));
    assert.ok(names().includes('notify'));
    const again = determine({ id: 17, url, referrer: 'https://example.com/page', filename: 'fail.zip', totalBytes: 5e6 });
    await tick(60);
    run('Host.download = okDownload;');
    assert.equal(again.suggestions(), 1);
    assert.equal(names().filter((n) => n === 'cancel').length, 1, 'the re-issued download is not caught again');
  });

  await t('onCreated fallback: only downloads onDeterminingFilename never saw', async () => {
    calls.length = 0;
    const before = sent().length;
    chrome.downloads.search = async ({ id }) => [{ id, url: `https://files.example/late-${id}.zip`, filename: `late-${id}.zip`, totalBytes: 5e6, state: 'in_progress' }];
    chrome.downloads.onCreated.fns[0]({ id: 11, url: 'https://files.example/c.dmg' }); // already decided
    chrome.downloads.onCreated.fns[0]({ id: 90, url: 'https://files.example/late-90.zip' });
    assert.ok(!names().includes('cancel'), 'onCreated waits for onDeterminingFilename');
    await tick(1700);
    assert.equal(sent().length, before + 1);
    assert.equal(sent().at(-1).items[0].url, 'https://files.example/late-90.zip');
  });

  await t('duplicate suppression: the same URL is handed off once within 10 s', async () => {
    calls.length = 0;
    const before = sent().length;
    const download = { url: 'https://files.example/twice.zip', filename: 'twice.zip', totalBytes: 5e6 };
    const first = determine({ ...download, id: 21 });
    await tick(60);
    const second = determine({ ...download, id: 22 });
    await tick(60);
    assert.equal(sent().length, before + 1);
    assert.equal(first.suggestions() + second.suggestions(), 2);
    assert.equal(names().filter((n) => n === 'cancel').length, 2, 'the duplicate browser download is cancelled too');
    assert.equal(run('Catcher.isDuplicate("https://files.example/twice.zip")'), true);
  });

  const page = b.loadContentScript({ pageURL: PAGE, frames: ['viewer'] });
  await tick(30);

  await t('click-time catching: matching links are stopped and handed off with cookies + referrer', async () => {
    const before = sent().length;
    assert.equal(page.click({ href: '/files/app.zip' }), true, 'preventDefault');
    assert.equal(page.click({ href: '/get?id=7', download: 'Report 2026.pdf' }), true, 'download attribute');
    assert.equal(page.click({ href: 'magnet:?xt=urn:btih:abc' }), true, 'magnet');
    assert.equal(page.click({ href: '/files/mid.zip' }, { type: 'auxclick', button: 1 }), true, 'middle click');
    await tick(60);
    const items = sent().slice(before).map((s) => { assert.equal(s.action, 'catch'); return s.items[0]; });
    const byURL = Object.fromEntries(items.map((i) => [i.url, i]));
    assert.deepEqual(Object.keys(byURL).sort(), ['https://shop.example/files/app.zip', 'https://shop.example/files/mid.zip',
      'https://shop.example/get?id=7', 'magnet:?xt=urn:btih:abc']);
    const zip = byURL['https://shop.example/files/app.zip'];
    assert.equal(zip.referrer, PAGE);
    assert.equal(zip.cookies, 'sid=42; lang=en');
    assert.equal(byURL['https://shop.example/get?id=7'].filename, 'Report 2026.pdf');
    assert.ok(calls.some((c) => c[0] === 'badge' && c[1].tabId === 7 && c[1].text === '✓'));
  });

  await t('click-time catching: skipped links reach the browser untouched', async () => {
    const before = sent().length;
    const skipped = [
      [{ href: '#top' }], [{ href: `${PAGE}#files` }], [{ href: 'javascript:void(0)' }],
      [{ href: 'blob:https://shop.example/1' }], [{ href: 'data:text/plain,hi' }], [{ href: 'mailto:a@b.example' }],
      [{ href: '/files/frame.zip', target: 'viewer' }], [{ href: '/about' }], [{ href: 'https://dl.skip.me/x.zip' }],
      [{ href: '/files/r.zip' }, { type: 'auxclick', button: 2 }], [{ href: '/files/u.zip' }, { isTrusted: false }],
      [{ href: '/files/handled.zip' }, { defaultPrevented: true }],
    ];
    for (const [attrs, init] of skipped) assert.equal(page.click(attrs, init), Boolean(init?.defaultPrevented), JSON.stringify(attrs));
    await tick(60);
    assert.equal(sent().length, before);
  });

  await t('host failure on a caught click: re-issued from the page, so its Referer is kept', async () => {
    const own = b.loadContentScript({ pageURL: 'https://example.com/page', tabId: 7 }); // the fake tab 7 shows this page
    await tick(30);
    run("Host.download = async () => { throw new HostError('boom'); };");
    calls.length = 0;
    assert.equal(own.click({ href: '/files/clicked.zip', download: 'Clicked.zip' }), true);
    await tick(60);
    run('Host.download = okDownload;');
    const injected = calls.find((c) => c[0] === 'executeScript' && c[1].func?.name === 'pbRedownload');
    assert.ok(injected, names().join(','));
    assert.equal(injected[1].target.tabId, 7);
    assert.deepEqual(JSON.parse(JSON.stringify(injected[1].args)), ['https://example.com/files/clicked.zip', 'Clicked.zip']);
    assert.ok(!names().includes('download'));
    const again = determine({ id: 61, url: 'https://example.com/files/clicked.zip', referrer: 'https://example.com/page', filename: 'Clicked.zip', totalBytes: 5e6 });
    await tick(60);
    assert.equal(again.suggestions(), 1);
    assert.ok(!names().includes('cancel'), 'the page re-download is not caught again');
  });

  await t('⌥ Option bypass: no click catch, and that page’s next download stays in the browser', async () => {
    calls.length = 0;
    assert.equal(page.click({ href: '/files/alt.zip' }, { altKey: true }), false);
    await tick(30);
    const download = { url: 'https://shop.example/files/alt.zip', referrer: PAGE, filename: 'alt.zip', totalBytes: 5e6 };
    assert.equal(run(`Catcher.isBypassed(${JSON.stringify(download)})`), true);
    const d = determine({ ...download, id: 31 });
    await tick(60);
    assert.equal(d.suggestions(), 1);
    assert.ok(!names().includes('cancel'));
    page.click({ href: '/about' }); // a plain click ends the bypass
    await tick(30);
    assert.equal(run(`Catcher.isBypassed(${JSON.stringify(download)})`), false);
  });

  await t('catch everything: popup toggle catches any type and size', async () => {
    let state = await ask({ cmd: 'setEverything', value: true, host: 'plain.example' });
    assert.equal(state.everything, true);
    assert.equal(state.everythingOverride, true);
    calls.length = 0;
    const d = determine({ id: 41, url: 'https://plain.example/notes.txt', filename: 'notes.txt', totalBytes: 12 });
    await tick(60);
    assert.equal(d.suggestions(), 1);
    assert.ok(names().includes('cancel'));
    assert.equal(sent().at(-1).items[0].url, 'https://plain.example/notes.txt');
    state = await ask({ cmd: 'setEverything', value: false });
    assert.equal(state.everything, false);
  });

  await t('per-site rules: never (popup) and always (context menu) for page and file hosts', async () => {
    let state = await ask({ cmd: 'setSiteRule', host: 'www.files.example', rule: 'never' });
    assert.deepEqual([state.site, state.siteRule], ['files.example', 'never']);
    calls.length = 0;
    const never = determine({ id: 51, url: 'https://files.example/n.zip', filename: 'n.zip', totalBytes: 5e6 });
    const fromPage = determine({ id: 52, url: 'https://cdn.other/n.zip', referrer: 'https://files.example/p', filename: 'n.zip', totalBytes: 5e6 });
    await tick(60);
    assert.equal(never.suggestions() + fromPage.suggestions(), 2);
    assert.ok(!names().includes('cancel'));
    const neverPage = b.loadContentScript({ pageURL: 'https://files.example/list', tabId: 8 });
    await tick(30);
    assert.equal(neverPage.click({ href: '/n2.zip' }), false, 'no click catching on a never site');
    state = await ask({ cmd: 'setSiteRule', host: 'files.example', rule: null });
    assert.equal(state.siteRule, null);

    const click = (pageUrl) => chrome.contextMenus.onClicked.fns[0]({ menuItemId: 'pb-site-always', pageUrl }, { id: 7, url: pageUrl });
    await click('https://always.example/page');
    await tick(30);
    assert.equal(store.siteRules['always.example'], 'always');
    calls.length = 0;
    const always = determine({ id: 53, url: 'https://always.example/a.txt', filename: 'a.txt', totalBytes: 10 });
    await tick(60);
    assert.equal(always.suggestions(), 1);
    assert.ok(names().includes('cancel'), 'always = catch everything for that host');
    await click('https://always.example/page'); // choosing it again clears the rule
    await tick(30);
    assert.equal(store.siteRules['always.example'], undefined);
  });

  await t('fresh profile (no cached rules): the first download still waits for the app and is caught', async () => {
    const fresh = makeBrowser();
    fresh.run(`Host.settings = () => new Promise((done) => setTimeout(() => done(${JSON.stringify(SETTINGS)}), 150));
      globalThis.sent = [];
      Host.download = async (action, items) => { sent.push({ action, items }); return { ok: true, count: items.length }; };`);
    let suggestions = 0;
    const returned = fresh.chrome.downloads.onDeterminingFilename.fns[0](
      { id: 61, url: 'https://files.example/first.dmg', filename: 'first.dmg', totalBytes: 5e6 },
      () => { suggestions += 1; });
    assert.equal(returned, true);
    await tick(400);
    assert.equal(suggestions, 1);
    assert.ok(fresh.calls.some((c) => c[0] === 'cancel'), 'caught, not left to the browser');
    assert.equal(fresh.run('sent').at(-1)?.items[0].url, 'https://files.example/first.dmg');
  });

  await t('fresh profile, app never answers: the download is released by the deadline', async () => {
    const fresh = makeBrowser();
    fresh.run('Host.settings = () => new Promise(() => {});');
    let suggestions = 0;
    fresh.chrome.downloads.onDeterminingFilename.fns[0](
      { id: 62, url: 'https://files.example/late.zip', filename: 'late.zip', totalBytes: 5e6 },
      () => { suggestions += 1; });
    await tick(1_800);
    assert.equal(suggestions, 1, 'suggest() once after the 1.5 s wait');
    assert.ok(!fresh.calls.some((c) => c[0] === 'cancel'));
  });

  return count;
}
