// Media sniffing: observes responses (never blocks or modifies them) and remembers media
// streams per tab — HLS/DASH manifests and direct audio/video files. The count shows on the
// toolbar badge; the popup lists them. Lists clear when the tab loads a new document.
'use strict';

/* exported Sniffer, SNIFF_BADGE_COLOR */
const MEDIA_PER_TAB = 30;
const SNIFF_BADGE_COLOR = '#0A84FF';
const MIN_MEDIA_BYTES = 512 * 1024;
const MANIFEST_TYPES = ['application/vnd.apple.mpegurl', 'application/x-mpegurl', 'audio/mpegurl',
  'audio/x-mpegurl', 'application/dash+xml'];
const SEGMENT_TYPES = ['video/mp2t', 'video/iso.segment', 'audio/aac'];
const MEDIA_EXTENSIONS = ['m3u8', 'mpd', 'mp4', 'm4v', 'webm', 'mp3', 'm4a', 'ogg', 'opus', 'flac', 'mov'];
const SEGMENT_PATTERN = /\.(ts|m4s|cmfv|cmfa|aac)(\?|$)|[?&](range|bytestart|byterange)=/i;

const Sniffer = (() => {
  const tabs = new Map(); // tabId → [{url, kind, mime, size, pageURL, title, at}]
  let restored = false;
  let saveTimer = null;
  const session = api.storage.session;

  function header(headers, name) {
    const found = (headers || []).find((h) => h.name.toLowerCase() === name);
    return found ? String(found.value || '') : '';
  }

  function urlExtension(url) {
    try {
      const path = new URL(url).pathname.toLowerCase();
      const dot = path.lastIndexOf('.');
      return dot > path.lastIndexOf('/') ? path.slice(dot + 1) : '';
    } catch { return ''; }
  }

  /** {kind, mime, size} for a media response, or null. Pure. */
  function classify(details) {
    if (details.tabId < 0 || details.statusCode >= 400) return null;
    if (!/^https?:/i.test(details.url)) return null;
    const mime = header(details.responseHeaders, 'content-type').toLowerCase().split(';')[0].trim();
    const size = Number(header(details.responseHeaders, 'content-length')) || 0;
    const ext = urlExtension(details.url);
    const manifest = MANIFEST_TYPES.includes(mime) || ext === 'm3u8' || ext === 'mpd';
    if (manifest) return { kind: ext === 'mpd' || mime === 'application/dash+xml' ? 'DASH' : 'HLS', mime, size };

    // Streaming players fetch segments via XHR/fetch; only documents and media elements count here.
    if (!['main_frame', 'sub_frame', 'media', 'object'].includes(details.type)) return null;
    if (SEGMENT_TYPES.includes(mime) || SEGMENT_PATTERN.test(details.url)) return null;
    if (details.statusCode === 206 && !header(details.responseHeaders, 'content-range').match(/^bytes 0-/)) return null;
    const isMedia = mime.startsWith('video/') || mime.startsWith('audio/') || MEDIA_EXTENSIONS.includes(ext);
    if (!isMedia) return null;
    const total = Number(header(details.responseHeaders, 'content-range').split('/')[1]) || size;
    if (total > 0 && total < MIN_MEDIA_BYTES) return null;
    const kind = (mime.split('/')[1] || ext || 'media').replace(/^x-/, '').toUpperCase();
    return { kind: kind.length > 6 ? (mime.startsWith('audio/') ? 'AUDIO' : 'VIDEO') : kind, mime, size: total };
  }

  async function restore() {
    if (restored) return;
    restored = true;
    if (!session) return;
    try {
      const { sniffed } = await session.get('sniffed');
      for (const [id, list] of Object.entries(sniffed || {})) if (!tabs.has(Number(id))) tabs.set(Number(id), list);
    } catch { /* storage.session unavailable */ }
  }

  function persist() {
    if (!session) return;
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      session.set({ sniffed: Object.fromEntries(tabs) }).catch(() => {});
    }, 300);
  }

  function badge(tabId) {
    const count = tabs.get(tabId)?.length || 0;
    const text = count === 0 ? '' : count > 9 ? '9+' : String(count);
    api.action.setBadgeText({ tabId, text }).catch(() => {});
  }

  function clear(tabId) {
    if (!tabs.has(tabId)) return;
    tabs.delete(tabId);
    badge(tabId);
    persist();
  }

  async function onHeaders(details) {
    await restore();
    if (details.type === 'main_frame') clear(details.tabId);
    const media = classify(details);
    if (!media) return;
    const list = tabs.get(details.tabId) || [];
    if (list.some((entry) => entry.url === details.url)) return;
    let title = '';
    let pageURL = details.documentUrl || details.originUrl || details.initiator || '';
    if (details.type === 'main_frame') {
      pageURL = details.url; // the tab opened the file itself
    } else {
      try {
        const tab = await api.tabs.get(details.tabId);
        title = tab.title || '';
        pageURL = tab.url || pageURL;
      } catch { /* tab closed */ }
    }
    const next = [...list, { url: details.url, ...media, pageURL, title, at: Date.now() }].slice(-MEDIA_PER_TAB);
    tabs.set(details.tabId, next);
    badge(details.tabId);
    persist();
  }

  async function list(tabId) {
    await restore();
    return [...(tabs.get(tabId) || [])].reverse();
  }

  function start() {
    const filter = { urls: ['<all_urls>'], types: ['main_frame', 'sub_frame', 'media', 'object', 'xmlhttprequest', 'other'] };
    api.webRequest.onHeadersReceived.addListener(
      (details) => { onHeaders(details).catch(() => {}); },
      filter,
      ['responseHeaders'],
    );
    api.tabs.onRemoved.addListener((tabId) => { tabs.delete(tabId); persist(); });
    api.action.setBadgeBackgroundColor({ color: SNIFF_BADGE_COLOR }).catch(() => {});
    api.action.setBadgeTextColor?.({ color: '#FFFFFF' })?.catch?.(() => {});
  }

  return { start, list, classify, clear, refreshBadge: badge };
})();
