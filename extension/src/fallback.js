// When Parabolic can't take a caught download, the browser downloads it instead. Re-issued URLs
// are remembered for a minute so they are never caught again.
//
// Referer: Chromium hides downloads started with downloads.download() from declarativeNetRequest
// and webRequest (browser-initiated requests), and rejects a Referer in its `headers` option. So
// a caught link click is re-issued from its page (a hidden <a download> click), which sends the
// page's Referer and cookies exactly like the original request. Only clicks: when the browser
// already started (and we cancelled) a download, a second page download trips Chromium's
// "download multiple files" limiter, so those use downloads.download() without a Referer — as
// does any click whose tab is gone, restricted, or now on another site (pass no tabId).
'use strict';

/* exported Fallback */
const REISSUE_TTL_MS = 60_000;

/** Injected into the page: requests `url` as a page download (the browser adds the Referer). */
function pbRedownload(url, filename) {
  const link = document.createElement('a');
  link.href = url;
  link.download = filename || '';
  link.rel = 'noopener';
  link.style.display = 'none';
  (document.body || document.documentElement).append(link);
  link.click();
  link.remove();
  return true;
}

const Fallback = (() => {
  const reissued = new Map(); // url → expiry

  function remember(url) {
    if (url) reissued.set(url, Date.now() + REISSUE_TTL_MS);
  }

  function wasReissued(url) {
    const now = Date.now();
    for (const [key, expiry] of reissued) if (expiry < now) reissued.delete(key);
    return Boolean(url) && reissued.has(url);
  }

  /** Re-issues from the tab when it still shows the referring site. True if it did. */
  async function fromPage(tabId, url, referrer, filename) {
    if (!api.scripting?.executeScript || !Number.isInteger(tabId) || tabId < 0) return false;
    if (!/^https?:\/\//i.test(url || '') || !/^https?:\/\//i.test(referrer || '')) return false;
    try {
      const tab = await api.tabs.get(tabId);
      if (!CatchRules.siteOf(tab?.url) || CatchRules.siteOf(tab.url) !== CatchRules.siteOf(referrer)) return false;
      const [injected] = await api.scripting.executeScript({
        target: { tabId },
        func: pbRedownload,
        args: [url, String(filename || '').split(/[\\/]/).pop()],
      });
      return injected?.result === true;
    } catch {
      return false; // restricted page or closed tab
    }
  }

  /** Lets the browser download `url` itself (it is never caught again). 'page' | 'browser'. */
  async function browserDownload({ url, finalUrl, referrer, tabId, filename }) {
    remember(url);
    remember(finalUrl);
    if (await fromPage(tabId, url, referrer, filename)) return 'page';
    await api.downloads.download({ url });
    return 'browser';
  }

  return { remember, wasReissued, browserDownload };
})();
