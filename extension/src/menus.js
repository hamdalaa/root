// Right-click menus on links, video/audio, the page and selections, plus per-site catch
// rules. The "Download with preset" submenu is rebuilt from the presets Parabolic reports.
'use strict';

/* exported Menus */
const MENU_PRESET_PREFIX = 'pb-preset:';

/** Injected into the page: every anchor href (and <area>) in the document. */
function pbCollectAllLinks() {
  return Array.from(document.querySelectorAll('a[href], area[href]'), (a) => a.href);
}

/** Injected into the page: anchors inside the selection plus URLs typed in the selected text. */
function pbCollectSelectedLinks() {
  const selection = window.getSelection();
  const links = [];
  if (!selection) return links;
  for (let i = 0; i < selection.rangeCount; i += 1) {
    const range = selection.getRangeAt(i);
    const root = range.commonAncestorContainer;
    const scope = root.nodeType === Node.ELEMENT_NODE ? root : root.parentElement;
    const closest = scope?.closest?.('a[href]');
    if (closest) links.push(closest.href);
    for (const a of scope?.querySelectorAll?.('a[href], area[href]') || []) {
      if (range.intersectsNode(a)) links.push(a.href);
    }
  }
  const text = selection.toString();
  for (const match of text.matchAll(/\b(?:https?:\/\/|magnet:\?)[^\s"'<>]+/gi)) links.push(match[0]);
  return links;
}

const Menus = (() => {
  const create = (props) => new Promise((resolve) => {
    // Callback form works in both browsers; errors (e.g. duplicate ids) are non-fatal.
    api.contextMenus.create(props, () => { void api.runtime.lastError; resolve(); });
  });

  async function build(presets = []) {
    await api.contextMenus.removeAll();
    const target = ['link', 'video', 'audio'];
    await create({ id: 'pb-quick', title: 'Download with Root', contexts: target });
    await create({ id: 'pb-add', title: 'Download with options…', contexts: [...target, 'page'] });
    if (presets.length > 0) {
      await create({ id: 'pb-presets', title: 'Download with preset', contexts: [...target, 'page'] });
      for (const name of presets) {
        await create({ id: MENU_PRESET_PREFIX + name, parentId: 'pb-presets', title: name, contexts: [...target, 'page'] });
      }
    }
    await create({ id: 'pb-sep', type: 'separator', contexts: ['page', 'selection', 'video', 'audio'] });
    await create({ id: 'pb-page-video', title: 'Download this page’s video', contexts: ['page', 'video', 'audio'] });
    await create({ id: 'pb-selected', title: 'Download selected links', contexts: ['selection'] });
    await create({ id: 'pb-all', title: 'Download all links on page', contexts: ['page', 'selection'] });
    await create({ id: 'pb-site-sep', type: 'separator', contexts: ['page'] });
    await create({ id: 'pb-site-never', title: 'Never catch downloads from this site', contexts: ['page'] });
    await create({ id: 'pb-site-always', title: 'Always catch on this site', contexts: ['page'] });
  }

  const SITE_NOTES = {
    never: (site) => [`Not catching on ${site}`, 'Downloads from this site stay in the browser.'],
    always: (site) => [`Catching everything on ${site}`, 'Every download from this site goes to Root.'],
    null: (site) => [`${site} follows your settings`, 'Catching on this site is back to normal.'],
  };

  /** Sets (or, when chosen again, clears) this site's never/always rule. */
  async function toggleSiteRule(rule, pageURL) {
    const site = CatchRules.siteOf(pageURL);
    if (!/^https?:/i.test(pageURL || '') || !site) {
      Handoff.notify('Not a web page', 'Open a website to change catching for it.');
      return;
    }
    const current = (await Settings.siteRules())[site] || null;
    const next = current === rule ? null : rule;
    await Settings.setSiteRule(site, next);
    Handoff.notify(...SITE_NOTES[next](site));
  }

  /** The URL a click refers to: the link, else a real media src, else the page itself. */
  function targetURL(info, tab) {
    if (info.linkUrl) return info.linkUrl;
    if (info.srcUrl && /^https?:/i.test(info.srcUrl)) return info.srcUrl;
    return info.pageUrl || tab?.url || '';
  }

  async function collect(tab, info, func) {
    const target = Number.isInteger(info.frameId) ? { tabId: tab.id, frameIds: [info.frameId] } : { tabId: tab.id };
    const results = await api.scripting.executeScript({ target, func });
    return Handoff.uniqueLinks(results.flatMap((r) => (Array.isArray(r.result) ? r.result : [])));
  }

  async function sendBatch(tab, info, func, emptyMessage) {
    let links = [];
    try {
      links = await collect(tab, info, func);
    } catch (error) {
      Handoff.notify('Can’t read this page', error?.message || 'The browser doesn’t allow extensions here.');
      return;
    }
    if (links.length === 0) {
      Handoff.notify('Nothing to download', emptyMessage);
      return;
    }
    const pageURL = info.pageUrl || tab.url;
    // Batches only carry URLs (the app shows them in a list), so never attach cookies, and cap the size.
    const items = await Promise.all(links.slice(0, 2000).map((url) => Handoff.item(url, { pageURL, headers: false })));
    Handoff.send('batch', items);
  }

  async function onClicked(info, tab) {
    const pageURL = info.pageUrl || tab?.url;
    const id = String(info.menuItemId);
    if (id === 'pb-site-never' || id === 'pb-site-always') {
      return toggleSiteRule(id === 'pb-site-never' ? 'never' : 'always', pageURL);
    }
    if (id === 'pb-all') return sendBatch(tab, { ...info, frameId: 0 }, pbCollectAllLinks, 'This page has no links.');
    if (id === 'pb-selected') return sendBatch(tab, info, pbCollectSelectedLinks, 'The selection has no links.');
    if (id === 'pb-page-video') {
      return Handoff.send('quick', [await Handoff.item(pageURL, { title: tab?.title, headers: false })]);
    }
    const url = targetURL(info, tab);
    const isPage = url === pageURL;
    const entry = await Handoff.item(url, {
      pageURL,
      title: isPage ? tab?.title : undefined,
      headers: !isPage,
    });
    if (id === 'pb-quick') return Handoff.send('quick', [entry]);
    if (id === 'pb-add') return Handoff.send('add', [entry]);
    if (id.startsWith(MENU_PRESET_PREFIX)) {
      return Handoff.send('quick', [entry], { preset: id.slice(MENU_PRESET_PREFIX.length) });
    }
    return undefined;
  }

  // Builds never overlap (overlapping removeAll/create pairs produce duplicate-id errors).
  let queue = Promise.resolve();
  function rebuild(presets) {
    queue = queue.then(() => build(presets)).catch(() => {});
    return queue;
  }

  function start() {
    api.contextMenus.onClicked.addListener((info, tab) => { onClicked(info, tab).catch(() => {}); });
    Settings.onPresetsChanged((rules) => { rebuild(rules.presets); });
  }

  /** Builds menus from the cached (or freshly fetched) presets. */
  async function install() {
    const rules = await Settings.get();
    await rebuild(rules?.presets || []);
  }

  return { start, install };
})();
