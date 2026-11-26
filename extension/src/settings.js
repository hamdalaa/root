// Catch rules from Parabolic → Settings → Browser, cached in storage.local and refreshed at
// most every 5 minutes. Local toggles (`catchOverride`, `catchEverythingOverride`) override the
// app for this browser; `siteRules` adds per-site never/always choices.
'use strict';

/* exported Settings */
const SETTINGS_TTL_MS = 5 * 60 * 1000;
/** How long a catch decision may wait for the app's rules when none are cached yet (< suggest deadline). */
const FIRST_RULES_WAIT_MS = 1_500;

const Settings = (() => {
  let memo = null;      // { rules, fetchedAt }
  let inflight = null;
  const listeners = new Set();

  function normalise(reply) {
    const split = (text) => String(text || '').toLowerCase().split(/[\s,;]+/).filter(Boolean);
    return {
      catchDownloads: reply.catchDownloads !== false,
      catchExtensions: split(reply.catchExtensions).map((ext) => ext.replace(/^\./, '')),
      minSizeMB: Math.max(0, Number(reply.minSizeMB) || 0),
      skipHosts: split(reply.skipHosts).map((host) => host.replace(/^\*?\./, '').replace(/^www\./, '')),
      catchEverything: reply.catchEverything === true,
      showCatchWindow: reply.showCatchWindow !== false,
      presets: Array.isArray(reply.presets) ? reply.presets.filter((p) => typeof p === 'string') : [],
    };
  }

  async function loadCached() {
    if (memo) return memo;
    const { hostSettings } = await api.storage.local.get('hostSettings');
    memo = hostSettings && hostSettings.rules ? hostSettings : null;
    return memo;
  }

  async function refresh() {
    if (inflight) return inflight;
    inflight = (async () => {
      try {
        const rules = normalise(await Host.settings());
        const before = JSON.stringify(memo?.rules?.presets || []);
        memo = { rules, fetchedAt: Date.now() };
        await api.storage.local.set({ hostSettings: memo });
        if (JSON.stringify(rules.presets) !== before) listeners.forEach((fn) => fn(rules));
        return memo;
      } finally {
        inflight = null;
      }
    })();
    return inflight;
  }

  /**
   * Current rules, or null if Parabolic has never answered. Stale caches refresh first;
   * if the refresh fails, the last good rules are used.
   */
  async function get({ force = false } = {}) {
    const cached = await loadCached();
    const stale = !cached || Date.now() - cached.fetchedAt > SETTINGS_TTL_MS;
    if (force || stale) {
      try { return (await refresh()).rules; } catch { return cached?.rules ?? null; }
    }
    return cached.rules;
  }

  /**
   * Rules without a long wait: the cache, refreshed in the background if stale. With no cache at
   * all (fresh install, cleared storage) it waits up to `waitMs` for the app, so the very first
   * download after installing isn't silently left to the browser (or another download manager).
   */
  async function peek({ waitMs = 0 } = {}) {
    const cached = await loadCached();
    if (cached && Date.now() - cached.fetchedAt <= SETTINGS_TTL_MS) return cached.rules;
    const pending = refresh().catch(() => null);
    if (cached || waitMs <= 0) return cached?.rules ?? null;
    let timer;
    const timeout = new Promise((done) => { timer = setTimeout(() => done(null), waitMs); });
    const fresh = await Promise.race([pending, timeout]);
    clearTimeout(timer);
    return fresh?.rules ?? null;
  }

  async function localBoolean(key) {
    const { [key]: value } = await api.storage.local.get(key);
    return typeof value === 'boolean' ? value : null;
  }

  /** The per-browser toggle: true/false, or null to follow the app. */
  const catchOverride = () => localBoolean('catchOverride');
  const everythingOverride = () => localBoolean('catchEverythingOverride');

  async function setCatchOverride(value) {
    await api.storage.local.set({ catchOverride: Boolean(value) });
  }

  async function setEverythingOverride(value) {
    await api.storage.local.set({ catchEverythingOverride: Boolean(value) });
  }

  /** { host: 'never' | 'always' } chosen in this browser (popup / context menu). */
  async function siteRules() {
    const { siteRules: value } = await api.storage.local.get('siteRules');
    return value && typeof value === 'object' ? value : {};
  }

  /** rule: 'never' | 'always' | null (follow the app). Returns the new map. */
  async function setSiteRule(host, rule) {
    const site = String(host || '').toLowerCase().replace(/^www\./, '');
    if (!site) throw new Error('No site to change.');
    const { [site]: _old, ...rest } = await siteRules();
    const next = rule === 'never' || rule === 'always' ? { ...rest, [site]: rule } : rest;
    await api.storage.local.set({ siteRules: next });
    return next;
  }

  /** App rules merged with this browser's overrides; null if Parabolic never answered. */
  async function effective({ cached = false } = {}) {
    const rules = cached ? await peek({ waitMs: FIRST_RULES_WAIT_MS }) : await get();
    if (!rules) return null;
    const [catchValue, everythingValue, sites] = await Promise.all([catchOverride(), everythingOverride(), siteRules()]);
    return CatchRules.effective(rules, { catchOverride: catchValue, everythingOverride: everythingValue, siteRules: sites });
  }

  /** Whether downloads should be caught right now (needs a reachable app at least once). */
  async function isCatching(rules) {
    if (!rules) return false;
    const override = await catchOverride();
    return override ?? rules.catchDownloads;
  }

  return {
    get,
    peek,
    effective,
    isCatching,
    catchOverride,
    setCatchOverride,
    everythingOverride,
    setEverythingOverride,
    siteRules,
    setSiteRule,
    onPresetsChanged: (fn) => listeners.add(fn),
  };
})();
