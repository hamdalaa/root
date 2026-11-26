// Download catching. On Chromium, downloads.onDeterminingFilename decides before the browser's
// "Ask where to save" dialog: caught downloads are cancelled + erased, everything else gets
// suggest() so the browser carries on. onCreated is the fallback (Firefox, or downloads the
// listener never saw). Link clicks caught by the content script come in through catchLink().
// If Parabolic can't take a download, the browser downloads it instead (Fallback).
'use strict';

/* exported Catcher */
const FILENAME_WAIT_MS = 4_000;
const DUPLICATE_MS = 10_000;
const BYPASS_MS = 3_000;
const DETERMINE_FALLBACK_MS = 1_500;
const SUGGEST_DEADLINE_MS = 2_500;
const SEEN_TTL_MS = 5 * 60_000;

const Catcher = (() => {
  const waiting = new Map(); // download id → timer (waiting for Chromium to pick a filename)
  const recent = new Map();  // url → time it was handed to Parabolic
  const bypass = new Map();  // tabId → { until, site } after an ⌥-click
  const seen = new Map();    // download id → time it was decided (never decide twice)
  const hasDetermining = () => !IS_FIREFOX && Boolean(api.downloads.onDeterminingFilename);

  function markSeen(id) {
    const now = Date.now();
    for (const [key, at] of seen) if (now - at > SEEN_TTL_MS) seen.delete(key);
    seen.set(id, now);
  }

  function markCaught(url) {
    if (url) recent.set(url, Date.now());
  }

  /** True when `url` was handed to Parabolic less than 10 s ago. */
  function isDuplicate(url) {
    const now = Date.now();
    for (const [key, at] of recent) if (now - at >= DUPLICATE_MS) recent.delete(key);
    return Boolean(url) && recent.has(url);
  }

  /** The content script reports whether the last click in `tabId` held ⌥ Option. */
  function noteClick(tabId, altKey, pageURL) {
    if (altKey) bypass.set(tabId, { until: Date.now() + BYPASS_MS, site: CatchRules.siteOf(pageURL) });
    else bypass.delete(tabId);
  }

  /** A download that starts within 3 s of an ⌥-click on its page is left to the browser. */
  function isBypassed(download) {
    const now = Date.now();
    for (const [key, entry] of bypass) if (entry.until < now) bypass.delete(key);
    if (bypass.size === 0) return false;
    const fromPage = CatchRules.siteOf(download.referrer);
    const fromFile = CatchRules.siteOf(download.finalUrl || download.url);
    return [...bypass.values()].some((entry) => !fromPage || !entry.site
      || entry.site === fromPage || entry.site === fromFile);
  }

  function context(pageURL) {
    return { ownId: api.runtime.id, pageURL, isReissued: Fallback.wasReissued, isBypassed, isDuplicate };
  }

  /** Verdict for `download` under `rules` (raw app rules or Settings.effective output). */
  function decide(download, rules, pageURL) {
    const merged = typeof rules.catching === 'boolean' ? rules : CatchRules.effective(rules, {});
    return CatchRules.decideDownload(download, merged, context(pageURL));
  }

  /**
   * The tab a download most likely came from: the focused tab, unless the download's referrer
   * belongs to another site, then a (preferably active) tab showing that site.
   */
  async function sourceTab(referrer) {
    try {
      const [focused] = await api.tabs.query({ active: true, lastFocusedWindow: true });
      const site = CatchRules.siteOf(referrer);
      if (!site || CatchRules.siteOf(focused?.url) === site) return focused || null;
      const tabs = await api.tabs.query({ url: ['http://*/*', 'https://*/*'] });
      const same = tabs.filter((tab) => CatchRules.siteOf(tab.url) === site);
      return same.find((tab) => tab.active) || same[0] || focused || null;
    } catch { return null; }
  }

  function pageFor(download, tab) {
    if (download.referrer && /^https?:/i.test(download.referrer)) return download.referrer;
    return tab?.url && /^https?:/i.test(tab.url) ? tab.url : undefined;
  }

  async function discard(download) {
    try { await api.downloads.cancel(download.id); } catch { /* already finished */ }
    try { await api.downloads.erase({ id: download.id }); } catch { /* not in history */ }
  }

  async function fallBack({ url, finalUrl, referrer, tabId, filename, viaPage = false }) {
    try {
      if (/^magnet:/i.test(url)) {
        if (Number.isInteger(tabId) && tabId >= 0) await api.tabs.update(tabId, { url }); // the system handler
        return;
      }
      await Fallback.browserDownload({ url, finalUrl, referrer, tabId: viaPage ? tabId : undefined, filename });
    } catch { /* the browser refused too; the notification explains */ }
  }

  /** Hands one link to Parabolic's catch window; the browser takes over if that fails. */
  async function handOff({ url, finalUrl, referrer, filename, size, mime, tabId, viaPage = false }) {
    markCaught(url);
    markCaught(finalUrl);
    const entry = await Handoff.item(finalUrl || url, { referrer, pageURL: referrer, filename });
    // What the browser already knows about the file: shown instantly in Parabolic's catch window.
    if (size) entry.size = size;
    if (mime) entry.mime = String(mime).slice(0, 100);
    try {
      await Handoff.send('catch', [entry], { quiet: true });
      Feedback.caught(tabId);
      return true;
    } catch (error) {
      recent.delete(url);
      recent.delete(finalUrl);
      await fallBack({ url, finalUrl, referrer, tabId, filename, viaPage });
      Handoff.notify('Downloading in the browser instead', Handoff.failureText(error));
      return false;
    }
  }

  function takeOver(download, tab) {
    const size = download.totalBytes > 0 ? download.totalBytes : (download.fileSize > 0 ? download.fileSize : 0);
    return handOff({
      url: download.url,
      finalUrl: download.finalUrl && download.finalUrl !== download.url ? download.finalUrl : undefined,
      referrer: pageFor(download, tab),
      filename: download.filename,
      size,
      mime: download.mime,
      tabId: tab?.id,
    });
  }

  /** onCreated path (Firefox, or a download onDeterminingFilename never saw). */
  async function evaluate(download) {
    if (seen.has(download.id)) return;
    const rules = await Settings.effective();
    if (!rules?.catching) return;
    const tab = await sourceTab(download.referrer);
    const verdict = CatchRules.decideDownload(download, rules, context(pageFor(download, tab)));
    if (verdict === 'duplicate' || verdict === 'catch') {
      markSeen(download.id);
      await discard(download);
      if (verdict === 'catch') await takeOver(download, tab);
    } else if (verdict === 'unknown' && !IS_FIREFOX) {
      // Chromium often reports the filename only after onCreated (Content-Disposition).
      waiting.set(download.id, setTimeout(() => waiting.delete(download.id), FILENAME_WAIT_MS));
    }
  }

  async function onChanged(delta) {
    if (!waiting.has(delta.id) || !delta.filename?.current) return;
    clearTimeout(waiting.get(delta.id));
    waiting.delete(delta.id);
    const [download] = await api.downloads.search({ id: delta.id });
    if (download && download.state === 'in_progress') await evaluate(download);
  }

  function onCreated(download) {
    if (!hasDetermining()) return evaluate(download);
    // Chromium: onDeterminingFilename normally decides; only downloads it never saw end up here.
    setTimeout(() => {
      if (seen.has(download.id)) return;
      api.downloads.search({ id: download.id })
        .then(([current]) => (current?.state === 'in_progress' ? evaluate(current) : undefined))
        .catch(() => {});
    }, DETERMINE_FALLBACK_MS);
    return undefined;
  }

  /**
   * Chromium, before the save dialog. suggest() is called exactly once on every path: after
   * cancelling a caught download, straight away for a skipped one, or by the deadline.
   */
  function onDetermining(download, suggest) {
    let suggested = false;
    const proceed = () => {
      if (suggested) return;
      suggested = true;
      try { suggest(); } catch { /* the download is gone */ }
    };
    markSeen(download.id);
    if (download.byExtensionId && download.byExtensionId === api.runtime.id) {
      proceed(); // our own fallback download
      return false;
    }
    const deadline = setTimeout(proceed, SUGGEST_DEADLINE_MS);
    (async () => {
      const rules = await Settings.effective({ cached: true });
      if (!rules?.catching) return;
      const tab = await sourceTab(download.referrer);
      const verdict = CatchRules.decideDownload(download, rules, context(pageFor(download, tab)));
      if (verdict !== 'catch' && verdict !== 'duplicate') return;
      await discard(download);
      clearTimeout(deadline);
      proceed();
      if (verdict === 'catch') await takeOver(download, tab);
    })().catch(() => {}).finally(() => { clearTimeout(deadline); proceed(); });
    return true; // suggest() is called asynchronously
  }

  /** A link click the content script already stopped (it never reached the browser). */
  async function catchLink({ url, filename, pageURL, tabId }) {
    const referrer = /^https?:/i.test(pageURL || '') ? pageURL : undefined;
    if (isDuplicate(url)) return { ok: true, duplicate: true };
    const rules = await Settings.effective({ cached: true });
    const verdict = rules
      ? CatchRules.decideLink({ href: url, download: filename }, pageURL, rules)
      : 'off';
    if (verdict !== 'catch') {
      // The page's cached rules were out of date: don't lose the click.
      await fallBack({ url, referrer, tabId, filename, viaPage: true });
      return { ok: false, verdict };
    }
    return { ok: await handOff({ url, referrer, filename, tabId, viaPage: true }) };
  }

  function reset() {
    recent.clear();
    bypass.clear();
    seen.clear();
  }

  function start() {
    api.downloads.onCreated.addListener((download) => { Promise.resolve(onCreated(download)).catch(() => {}); });
    api.downloads.onChanged.addListener((delta) => { onChanged(delta).catch(() => {}); });
    if (hasDetermining()) api.downloads.onDeterminingFilename.addListener(onDetermining);
  }

  return {
    start,
    decide,
    catchLink,
    noteClick,
    isBypassed,
    isDuplicate,
    reset,
    remember: Fallback.remember,
    extensionOf: CatchRules.extensionOf,
    mimeExtension: CatchRules.mimeExtension,
  };
})();
