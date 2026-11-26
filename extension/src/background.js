// Background entry point (Chromium service worker via sw.js, Firefox background scripts).
// Listeners are registered synchronously at top level so events wake the worker reliably.
'use strict';

Catcher.start();
Sniffer.start();
Menus.start();

/** Chromium only injects manifest content scripts into pages loaded after install. */
async function injectLinkCatcher() {
  if (IS_FIREFOX || !api.scripting?.executeScript) return;
  const tabs = await api.tabs.query({ url: ['http://*/*', 'https://*/*'] }).catch(() => []);
  for (const tab of tabs) {
    api.scripting.executeScript({
      target: { tabId: tab.id, allFrames: true },
      files: ['compat.js', 'catchrules.js', 'linkcatch.js'],
    }).catch(() => {}); // restricted pages (web store, discarded tabs)
  }
}

api.runtime.onInstalled.addListener(() => {
  Menus.install().catch(() => {});
  injectLinkCatcher().catch(() => {});
});
api.runtime.onStartup.addListener(() => { Menus.install().catch(() => {}); });

/** Sends the tab's page to Parabolic (yt-dlp resolves the media). */
async function downloadPage(tab, { action = 'quick', preset, quiet = false } = {}) {
  if (!tab?.url || !/^https?:/i.test(tab.url)) {
    if (quiet) throw new Error('Open a web page first.');
    Handoff.notify('Nothing to download', 'Open a web page first.');
    return null;
  }
  const entry = await Handoff.item(tab.url, { title: tab.title, headers: false });
  return Handoff.send(action, [entry], { preset, quiet });
}

api.commands.onCommand.addListener(async (command, tab) => {
  if (command !== 'download-page') return;
  const target = tab || (await api.tabs.query({ active: true, lastFocusedWindow: true }))[0];
  downloadPage(target).catch(() => {});
});

// ---- Popup bridge -------------------------------------------------------------------------

function errorReply(error) {
  return { ok: false, error: Handoff.failureText(error), missing: Boolean(error?.missing) };
}

/** A bare hostname from the popup ("www." dropped), or '' when it isn't one. */
function validSite(host) {
  const site = String(host || '').toLowerCase().replace(/^www\./, '');
  return site.length <= 253 && /^[a-z0-9.-]+$/.test(site) && site.includes('.') ? site : '';
}

const popupHandlers = {
  async handshake() {
    const reply = await Host.handshake();
    const rules = await Settings.get({ force: true });
    return { ok: true, hostVersion: reply.hostVersion, presets: rules?.presets || [] };
  },
  async status() {
    const reply = await Host.status();
    return { ok: true, items: Array.isArray(reply.items) ? reply.items : [] };
  },
  async catchState({ host } = {}) {
    const rules = await Settings.get();
    const merged = await Settings.effective({ cached: true });
    const site = validSite(host);
    const siteRule = site ? (await Settings.siteRules())[site] || null : null;
    return {
      ok: true,
      catching: Boolean(merged?.catching),
      appSetting: rules?.catchDownloads ?? null,
      override: await Settings.catchOverride(),
      everything: Boolean(merged?.catchEverything),
      everythingApp: rules ? rules.catchEverything === true : null,
      everythingOverride: await Settings.everythingOverride(),
      site,
      siteRule,
      appSkipped: Boolean(site && CatchRules.hostIn(site, merged?.appSkipHosts)),
    };
  },
  async setCatch({ value, host }) {
    await Settings.setCatchOverride(value);
    return popupHandlers.catchState({ host });
  },
  async setEverything({ value, host }) {
    await Settings.setEverythingOverride(value);
    return popupHandlers.catchState({ host });
  },
  async setSiteRule({ host, rule }) {
    const site = validSite(host);
    if (!site) throw new Error('Open a website to change catching for it.');
    await Settings.setSiteRule(site, rule === 'never' || rule === 'always' ? rule : null);
    return popupHandlers.catchState({ host: site });
  },
  async media({ tabId }) {
    return { ok: true, items: await Sniffer.list(Number(tabId)) };
  },
  async downloadPage({ tabId, action, preset }) {
    const tab = await api.tabs.get(Number(tabId));
    const reply = await downloadPage(tab, { action: action === 'add' ? 'add' : 'quick', preset, quiet: true });
    return { ok: true, count: reply?.count ?? 0 };
  },
  async downloadMedia({ url, pageURL, title, action }) {
    const entry = await Handoff.item(url, { pageURL, referrer: pageURL, title });
    const reply = await Handoff.send(action === 'add' ? 'add' : 'quick', [entry], { quiet: true });
    return { ok: true, count: reply?.count ?? 0 };
  },
};

// ---- Content-script bridge (link clicks) ----------------------------------------------------

const MAX_LINK_LENGTH = 8192;
const pageOf = (sender) => [sender.url, sender.tab?.url].find((url) => /^https?:/i.test(url || ''));

const contentHandlers = {
  async catchLink({ url, filename }, sender) {
    if (typeof url !== 'string' || url.length > MAX_LINK_LENGTH || !isDownloadableURL(url)) {
      return { ok: false, error: 'Not a downloadable link.' };
    }
    const name = typeof filename === 'string' ? filename.slice(0, 255) : undefined;
    return Catcher.catchLink({ url, filename: name, pageURL: pageOf(sender), tabId: sender.tab.id });
  },
  async clickState({ alt }, sender) {
    Catcher.noteClick(sender.tab.id, alt === true, pageOf(sender));
    return { ok: true };
  },
};

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== api.runtime.id || !message || typeof message.cmd !== 'string') return false;
  // The popup (this extension's own page) drives popupHandlers; content scripts in tabs only
  // report link clicks.
  const ownPage = String(sender.url || '').startsWith(api.runtime.getURL(''));
  const fromTab = !ownPage && Number.isInteger(sender.tab?.id) && sender.tab.id >= 0;
  let handler = null;
  if (ownPage && Object.hasOwn(popupHandlers, message.cmd)) handler = popupHandlers[message.cmd];
  if (fromTab && Object.hasOwn(contentHandlers, message.cmd)) handler = contentHandlers[message.cmd];
  if (!handler) return false;
  handler(message, sender).then(sendResponse, (error) => sendResponse(errorReply(error)));
  return true;
});
