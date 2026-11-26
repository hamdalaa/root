// Pure catch rules shared by the background worker and the click-catching content script.
// No browser API calls here: everything depends only on the arguments, so it is unit-testable
// and safe to evaluate synchronously inside a click handler.
'use strict';

/* exported CatchRules */
// `var` so re-injecting the content script into an open tab doesn't throw on redeclaration.
// eslint-disable-next-line no-var
var CatchRules = globalThis.CatchRules || (() => {
  const MIME_EXTENSIONS = {
    'application/zip': 'zip', 'application/x-zip-compressed': 'zip',
    'application/vnd.rar': 'rar', 'application/x-rar-compressed': 'rar',
    'application/x-7z-compressed': '7z', 'application/x-apple-diskimage': 'dmg',
    'application/vnd.apple.installer+xml': 'pkg', 'application/x-iso9660-image': 'iso',
    'application/x-msdownload': 'exe', 'application/x-msdos-program': 'exe', 'application/x-msi': 'msi',
    'application/vnd.android.package-archive': 'apk', 'application/x-tar': 'tar',
    'application/gzip': 'gz', 'application/x-gzip': 'gz', 'application/x-bzip2': 'bz2',
    'application/x-xz': 'xz', 'application/x-bittorrent': 'torrent', 'application/pdf': 'pdf',
    'application/epub+zip': 'epub', 'video/mp4': 'mp4', 'video/x-matroska': 'mkv',
    'video/quicktime': 'mov', 'video/x-msvideo': 'avi', 'video/webm': 'webm', 'audio/mpeg': 'mp3',
    'audio/flac': 'flac', 'audio/x-flac': 'flac', 'audio/wav': 'wav', 'audio/x-wav': 'wav',
  };
  const NAMED_TARGETS = ['', '_self', '_blank', '_top', '_parent'];

  function extensionOf(nameOrURL) {
    let path = String(nameOrURL || '');
    try { path = new URL(path).pathname; } catch { /* already a filename/path */ }
    let base = path.split(/[\\/]/).pop() || '';
    try { base = decodeURIComponent(base); } catch { /* keep the raw name */ }
    base = base.toLowerCase();
    const dot = base.lastIndexOf('.');
    return dot > 0 ? base.slice(dot + 1) : '';
  }

  function mimeExtension(mime) {
    const type = String(mime || '').toLowerCase().split(';')[0].trim();
    return MIME_EXTENSIONS[type] || '';
  }

  /** Lower-cased hostname without a leading "www.", or ''. */
  function siteOf(url) {
    try { return new URL(url).hostname.toLowerCase().replace(/^www\./, ''); } catch { return ''; }
  }

  /** True when `host` is one of `list` or a subdomain of one. */
  function hostIn(host, list) {
    const bare = String(host || '').replace(/^www\./, '');
    if (!bare) return false;
    return (list || []).some((entry) => bare === entry || bare.endsWith(`.${entry}`));
  }

  /**
   * App rules + this browser's local choices → the rules every decision uses.
   * local: { catchOverride, everythingOverride, siteRules: { host: 'never' | 'always' } }
   */
  function effective(rules, local = {}) {
    if (!rules) return null;
    const siteRules = local.siteRules && typeof local.siteRules === 'object' ? local.siteRules : {};
    const hosts = (rule) => Object.keys(siteRules).filter((host) => siteRules[host] === rule);
    const pick = (value, fallback) => (typeof value === 'boolean' ? value : fallback);
    return {
      ...rules,
      catching: pick(local.catchOverride, rules.catchDownloads !== false),
      catchEverything: pick(local.everythingOverride, rules.catchEverything === true),
      appSkipHosts: rules.skipHosts || [],
      skipHosts: [...(rules.skipHosts || []), ...hosts('never')],
      alwaysHosts: hosts('always'),
      minSizeMB: Number(rules.minSizeMB) || 0,
      catchExtensions: rules.catchExtensions || [],
    };
  }

  /** The hosts a download "comes from": the file's server and the page that linked it. */
  function hostsOf(...urls) {
    return urls.map(siteOf).filter(Boolean);
  }

  /**
   * Verdict for a browser download: 'catch' | 'skip' | 'duplicate' | 'unknown' (no filename or
   * MIME yet; Chromium fills them in later). ctx: { ownId, pageURL, isReissued(url),
   * isBypassed(download), isDuplicate(url) }.
   */
  function decideDownload(download, rules, ctx = {}) {
    const url = download.finalUrl || download.url || '';
    if (!/^https?:\/\//i.test(url)) return 'skip';
    if (ctx.ownId && download.byExtensionId === ctx.ownId) return 'skip';
    if (ctx.isReissued?.(url) || ctx.isReissued?.(download.url)) return 'skip';
    if (ctx.isBypassed?.(download)) return 'skip';
    const hosts = hostsOf(url, download.referrer, ctx.pageURL);
    if (hosts.some((host) => hostIn(host, rules.skipHosts))) return 'skip';
    if (ctx.isDuplicate?.(url) || ctx.isDuplicate?.(download.url)) return 'duplicate';
    if (rules.catchEverything || hosts.some((host) => hostIn(host, rules.alwaysHosts))) return 'catch';

    const exts = [extensionOf(download.filename), extensionOf(url), mimeExtension(download.mime)].filter(Boolean);
    const isTorrent = exts.includes('torrent');
    if (!isTorrent) {
      // Unknown size (0) never blocks a type match; only a known, small size does.
      const size = download.totalBytes > 0 ? download.totalBytes : (download.fileSize > 0 ? download.fileSize : 0);
      if (size > 0 && size < rules.minSizeMB * 1024 * 1024) return 'skip';
    }
    if (isTorrent || exts.some((ext) => rules.catchExtensions.includes(ext))) return 'catch';
    return download.filename ? 'skip' : 'unknown';
  }

  /**
   * Verdict for a clicked link, decided synchronously in the page: 'catch' or a skip reason.
   * link: { href, download (attribute value or null), target, frameExists(name) }.
   */
  function decideLink(link, pageURL, rules, { altKey = false } = {}) {
    if (!rules || !rules.catching) return 'off';
    if (altKey) return 'bypass';
    const href = String(link.href || '').trim();
    if (!href) return 'empty';
    const isMagnet = /^magnet:\?/i.test(href);
    if (!isMagnet && !/^https?:\/\//i.test(href)) return 'scheme'; // javascript:, blob:, data:, mailto:…
    const target = String(link.target || '').trim().toLowerCase();
    if (!NAMED_TARGETS.includes(target) && link.frameExists?.(link.target)) return 'frame';
    if (!isMagnet) {
      const strip = (value) => String(value || '').replace(/#.*$/, '');
      if (strip(href) === strip(pageURL)) return 'same-page';
    }
    if (hostsOf(isMagnet ? '' : href, pageURL).some((host) => hostIn(host, rules.skipHosts))) return 'excluded';
    if (isMagnet) return 'catch';
    const exts = [link.download ? extensionOf(link.download) : '', extensionOf(href)].filter(Boolean);
    if (exts.includes('torrent') || exts.some((ext) => rules.catchExtensions.includes(ext))) return 'catch';
    return 'no-match';
  }

  return { extensionOf, mimeExtension, siteOf, hostIn, effective, decideDownload, decideLink };
})();
globalThis.CatchRules = CatchRules;
