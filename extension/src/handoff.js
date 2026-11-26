// Builds the items Parabolic receives ({url, pageURL, referrer, cookies, userAgent, filename,
// title}) and sends them through the host, notifying the user when it fails.
'use strict';

/* exported Handoff */
const Handoff = (() => {
  /** "a=b; c=d" for every cookie the browser would send to `url`, or '' when none / not allowed. */
  async function cookieHeader(url) {
    if (!/^https?:/i.test(url)) return '';
    let cookies = [];
    try {
      cookies = await api.cookies.getAll({ url });
    } catch {
      // Firefox with first-party isolation insists on firstPartyDomain.
      try { cookies = IS_FIREFOX ? await api.cookies.getAll({ url, firstPartyDomain: null }) : []; } catch { cookies = []; }
    }
    return cookies.map((c) => `${c.name}=${c.value}`).join('; ');
  }

  function cleanFilename(name) {
    if (!name) return undefined;
    const base = String(name).split(/[\\/]/).pop().trim();
    return base || undefined;
  }

  /**
   * One hand-off item. `headers: true` attaches cookies, referrer and user agent so the app can
   * replay an authenticated request; pass false for plain page URLs (yt-dlp handles those).
   */
  async function item(url, { pageURL, referrer, filename, title, headers = true } = {}) {
    const entry = { url };
    if (pageURL && /^https?:/i.test(pageURL)) entry.pageURL = pageURL;
    if (title) entry.title = String(title).slice(0, 300);
    const name = cleanFilename(filename);
    if (name) entry.filename = name;
    if (headers && /^https?:/i.test(url)) {
      const ref = referrer || pageURL;
      if (ref && /^https?:/i.test(ref)) entry.referrer = ref;
      const cookies = await cookieHeader(url);
      if (cookies) entry.cookies = cookies;
      entry.userAgent = navigator.userAgent;
    }
    return entry;
  }

  function notify(title, message) {
    return api.notifications.create({
      type: 'basic',
      iconUrl: api.runtime.getURL(PB_ICON),
      title,
      message: String(message || '').slice(0, 300),
    }).catch(() => {});
  }

  function failureText(error) {
    if (error?.missing) return 'Root isn’t connected. Open Root → Settings → Browser → Connect.';
    return error?.message || String(error);
  }

  /**
   * Sends items to Parabolic. Resolves to the host reply, or null after notifying on failure.
   * `quiet` suppresses the notification (callers that handle errors themselves).
   */
  async function send(action, items, { preset, quiet = false } = {}) {
    const usable = items.filter((entry) => isDownloadableURL(entry?.url));
    if (usable.length === 0) {
      if (!quiet) notify('Nothing to download', 'No http(s) or magnet links were found.');
      return null;
    }
    try {
      return await Host.download(action, usable, preset);
    } catch (error) {
      if (!quiet) notify('Couldn’t send to Root', failureText(error));
      if (quiet) throw error;
      return null;
    }
  }

  /** De-duplicates links, keeping only http(s)/magnet, in first-seen order. */
  function uniqueLinks(urls) {
    const seen = new Set();
    const out = [];
    for (const raw of urls) {
      if (typeof raw !== 'string') continue;
      const url = raw.trim().replace(/#.*$/, '');
      if (!isDownloadableURL(url) || seen.has(url)) continue;
      seen.add(url);
      out.push(url);
    }
    return out;
  }

  return { item, send, notify, failureText, uniqueLinks, cookieHeader };
})();
