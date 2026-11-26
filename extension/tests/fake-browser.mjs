// A fake WebExtensions `chrome` API for the logic tests. connectNative spawns the BUILT
// ParabolicHost, so host.js/settings.js speak the real protocol. Each makeBrowser() call is an
// independent browser profile: its own storage, listeners and background-script context.
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

export const EXTENSION_ID = 'nijlimkbdkelhlhcaodjeiccbpbcneca';
export const event = () => {
  const fns = [];
  return { fns, addListener: (fn) => fns.push(fn) };
};
export const tick = (ms = 30) => new Promise((done) => setTimeout(done, ms));

function nativePort(hostPath) {
  const child = spawn(hostPath, [], { stdio: ['pipe', 'pipe', 'inherit'] });
  const onMessage = event();
  const onDisconnect = event();
  let buffer = Buffer.alloc(0);
  child.stdout.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32LE(0)) {
      const length = buffer.readUInt32LE(0);
      const message = JSON.parse(buffer.subarray(4, 4 + length).toString('utf8'));
      buffer = buffer.subarray(4 + length);
      onMessage.fns.forEach((fn) => fn(message));
    }
  });
  child.on('exit', () => onDisconnect.fns.forEach((fn) => fn({})));
  return {
    onMessage,
    onDisconnect,
    postMessage(message) {
      const body = Buffer.from(JSON.stringify(message));
      const header = Buffer.alloc(4);
      header.writeUInt32LE(body.length);
      child.stdin.write(Buffer.concat([header, body]));
    },
    disconnect() { child.stdin.end(); },
  };
}

/**
 * { chrome, calls, store, run, ask, loadContentScript }. `determining: true` adds
 * downloads.onDeterminingFilename (Chromium); `firefox: true` exposes the API as `browser` with
 * runtime.getBrowserInfo, so IS_FIREFOX is true (onCreated-only).
 */
export function makeBrowser({ root, hostPath, manifest, determining = false, firefox = false }) {
  const calls = [];
  const store = {};
  const record = (name) => async (...args) => { calls.push([name, ...args]); return undefined; };
  const onStorageChanged = event();
  const pick = (keys) => {
    if (keys == null) return { ...store };
    const list = Array.isArray(keys) ? keys : [keys];
    return Object.fromEntries(list.filter((key) => key in store).map((key) => [key, store[key]]));
  };
  const chrome = {
    runtime: {
      id: EXTENSION_ID,
      lastError: undefined,
      connectNative: (name) => { assert.equal(name, 'com.hamad.parabolic.host'); return nativePort(hostPath); },
      getURL: (p) => `chrome-extension://${EXTENSION_ID}/${p}`,
      onInstalled: event(), onStartup: event(), onMessage: event(),
      ...(firefox ? { getBrowserInfo: async () => ({ name: 'Firefox' }) } : {}),
    },
    storage: {
      local: {
        get: async (keys) => structuredClone(pick(keys)),
        set: async (obj) => {
          const changes = Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, { oldValue: store[k], newValue: v }]));
          Object.assign(store, structuredClone(obj));
          onStorageChanged.fns.forEach((fn) => fn(changes, 'local'));
        },
      },
      session: { get: async () => ({}), set: async () => {} },
      onChanged: onStorageChanged,
    },
    downloads: {
      onCreated: event(), onChanged: event(),
      ...(determining ? { onDeterminingFilename: event() } : {}),
      cancel: record('cancel'), erase: record('erase'), download: record('download'), search: async () => [],
    },
    cookies: { getAll: async () => [{ name: 'sid', value: '42' }, { name: 'lang', value: 'en' }] },
    tabs: {
      query: async () => [{ id: 7, url: 'https://example.com/page', title: 'Example' }],
      get: async (id) => ({ id, url: 'https://example.com/page', title: 'Example' }),
      update: record('tabUpdate'),
      onRemoved: event(),
    },
    webRequest: { onHeadersReceived: event() },
    action: { setBadgeText: record('badge'), setBadgeBackgroundColor: record('badgeColor'), setBadgeTextColor: async () => {} },
    contextMenus: { create: (p, cb) => { calls.push(['menu', p.id]); cb?.(); }, removeAll: async () => {}, onClicked: event() },
    scripting: {
      executeScript: async (options) => {
        calls.push(['executeScript', options]);
        return options.func?.name === 'pbRedownload' ? [{ result: true }] : [];
      },
    },
    notifications: { create: record('notify') },
    commands: { onCommand: event() },
  };

  const context = vm.createContext({
    chrome, ...(firefox ? { browser: chrome } : {}), console, setTimeout, clearTimeout, URL, structuredClone, navigator: { userAgent: 'TestAgent/1.0' },
  });
  for (const file of manifest.background_scripts) {
    vm.runInContext(readFileSync(join(root, 'extension/src', file), 'utf8'), context, { filename: file });
  }
  const run = (code) => vm.runInContext(code, context);
  const deliver = (message, sender) => new Promise((done) => {
    const handled = chrome.runtime.onMessage.fns[0](message, sender, done);
    if (handled !== true) done(undefined);
  });
  const ask = (message) => deliver(message, { id: EXTENSION_ID, url: chrome.runtime.getURL('popup.html') });

  /** Runs the manifest's content scripts in a fake page; returns { click(anchor, init) }. */
  function loadContentScript({ pageURL, tabId = 7, frames = [] }) {
    const listeners = { capture: [], bubble: [] };
    const sender = { id: EXTENSION_ID, url: pageURL, tab: { id: tabId, url: pageURL } };
    const page = {
      ...chrome,
      runtime: { ...chrome.runtime, sendMessage: (message) => deliver(message, sender) },
    };
    const window = {
      addEventListener: (type, fn, capture) => listeners[capture ? 'capture' : 'bubble'].push({ type, fn }),
      top: { frames: {} },
    };
    const document = {
      baseURI: pageURL,
      querySelector: (selector) => (frames.some((name) => selector.includes(`name="${name}"`)) ? {} : null),
    };
    const page$ = vm.createContext({ chrome: page, window, document, location: { href: pageURL }, URL, console });
    for (const file of manifest.content_scripts[0].js) {
      vm.runInContext(readFileSync(join(root, 'extension/src', file), 'utf8'), page$, { filename: file });
    }
    function click(attrs, init = {}) {
      const anchor = {
        localName: init.localName || 'a',
        href: attrs.href ? new URL(attrs.href, pageURL).href : '',
        hasAttribute: (name) => name in attrs,
        getAttribute: (name) => (name in attrs ? attrs[name] : null),
      };
      const evt = {
        type: init.type || 'click', button: init.button ?? 0, altKey: Boolean(init.altKey),
        isTrusted: init.isTrusted ?? true, defaultPrevented: Boolean(init.defaultPrevented),
        preventDefault() { this.defaultPrevented = true; },
        composedPath: () => [anchor],
      };
      for (const phase of ['capture', 'bubble']) {
        for (const { type, fn } of listeners[phase]) if (type === evt.type) fn(evt);
      }
      return evt.defaultPrevented;
    }
    return { click };
  }

  return { chrome, calls, store, run, ask, deliver, loadContentScript };
}
