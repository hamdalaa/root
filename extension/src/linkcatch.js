// Content script: catches clicks on download links before the browser starts its own download.
// The decision is synchronous (CatchRules + rules mirrored from storage), so preventDefault()
// happens in the same click. Holding ⌥ Option skips catching; the modifier state of the last
// click is also reported so the background leaves that tab's next download to the browser.
'use strict';

(() => {
  if (globalThis.__parabolicLinkCatch) return; // injected twice (install + manifest)
  globalThis.__parabolicLinkCatch = true;

  const KEYS = ['hostSettings', 'catchOverride', 'catchEverythingOverride', 'siteRules'];
  let rules = null;
  let lastAlt = false;

  async function load() {
    try {
      const stored = await api.storage.local.get(KEYS);
      rules = CatchRules.effective(stored.hostSettings?.rules || null, {
        catchOverride: stored.catchOverride,
        everythingOverride: stored.catchEverythingOverride,
        siteRules: stored.siteRules,
      });
    } catch {
      rules = null; // extension reloaded: the browser downloads normally
    }
  }

  function send(message) {
    try {
      const pending = api.runtime.sendMessage(message);
      if (pending?.catch) pending.catch(() => {});
    } catch { /* extension context invalidated */ }
  }

  function anchorFrom(event) {
    const path = typeof event.composedPath === 'function' ? event.composedPath() : [event.target];
    for (const node of path) {
      const name = node?.localName;
      if ((name === 'a' || name === 'area') && node.hasAttribute?.('href')) return node;
    }
    return null;
  }

  function hrefOf(anchor) {
    if (typeof anchor.href === 'string') return anchor.href;
    try { return new URL(anchor.getAttribute('href'), document.baseURI).href; } catch { return ''; } // SVG <a>
  }

  function frameExists(name) {
    try {
      const escaped = globalThis.CSS?.escape ? CSS.escape(name) : String(name).replace(/["\\]/g, '\\$&');
      if (document.querySelector(`iframe[name="${escaped}"], frame[name="${escaped}"]`)) return true;
      return Boolean(window.top?.frames?.[name]);
    } catch { return false; }
  }

  const relevant = (event) => (event.type === 'click' ? event.button === 0 : event.button === 1);

  /** Capture phase: runs before the page's handlers, so ⌥ is reported even if they stop the event. */
  function onCaptureClick(event) {
    if (!relevant(event) || !event.isTrusted) return;
    const altKey = Boolean(event.altKey);
    if (!altKey && !lastAlt) return;
    lastAlt = altKey;
    send({ cmd: 'clickState', alt: altKey });
  }

  /** Bubble phase: if the page didn't handle the click itself, a matching link is caught. */
  function onClick(event) {
    if (!relevant(event) || !event.isTrusted || event.defaultPrevented) return;
    const anchor = anchorFrom(event);
    if (!anchor) return;
    const download = anchor.getAttribute('download');
    const link = { href: hrefOf(anchor), download, target: anchor.getAttribute('target'), frameExists };
    const verdict = CatchRules.decideLink(link, location.href, rules, { altKey: event.altKey });
    if (verdict !== 'catch') return;
    event.preventDefault();
    send({ cmd: 'catchLink', url: link.href, filename: download || undefined, pageURL: location.href });
  }

  api.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && KEYS.some((key) => key in changes)) load();
  });
  for (const type of ['click', 'auxclick']) {
    window.addEventListener(type, onCaptureClick, true);
    window.addEventListener(type, onClick, false);
  }
  load();
})();
