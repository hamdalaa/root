// Toolbar popup: download the current page, pick a preset, send sniffed media, watch the
// app's queue, and control download catching (everywhere, catch everything, this site).
// Everything goes through the background worker.
'use strict';

const REFRESH_MS = 2000;
const STATUS_LABELS = {
  queued: 'Queued', scheduled: 'Scheduled', running: 'Downloading', processing: 'Processing',
  paused: 'Paused', completed: 'Done', failed: 'Failed', stopped: 'Stopped',
};

const $ = (id) => document.getElementById(id);
let activeTab = null;
let connected = false;
let toastTimer = null;
let lastMediaKey = '';
let lastRecentKey = '';

function ask(cmd, payload = {}) {
  return api.runtime.sendMessage({ cmd, ...payload })
    .then((reply) => reply || { ok: false, error: 'No reply from the extension.' })
    .catch((error) => ({ ok: false, error: error?.message || String(error) }));
}

function toast(text, { error = false } = {}) {
  const el = $('toast');
  el.textContent = text;
  el.classList.toggle('error', error);
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 3500);
}

function flash(button, ok) {
  button.classList.toggle('done', ok);
  setTimeout(() => button.classList.remove('done'), 1400);
}

function isWebPage(url) {
  return /^https?:/i.test(url || '');
}

// ---- Header ---------------------------------------------------------------------------------

function renderHeader() {
  const platform = detectPlatform(activeTab?.url);
  $('site-name').textContent = platform.name;
  $('site-title').textContent = activeTab?.title || '';
  $('site-dot').style.setProperty('--dot-color', platform.color);
  const usable = connected && isWebPage(activeTab?.url);
  $('download-page').disabled = !usable;
  $('options').disabled = !usable;
}

async function loadPresets(presets) {
  const select = $('preset');
  const { lastPreset } = await api.storage.local.get('lastPreset');
  select.replaceChildren(select.options[0]);
  for (const name of presets) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    select.append(option);
  }
  if (presets.includes(lastPreset)) select.value = lastPreset;
}

async function sendPage(action, button) {
  button.disabled = true;
  button.classList.add('busy');
  const preset = $('preset').value || undefined;
  const reply = await ask('downloadPage', { tabId: activeTab.id, action, preset });
  button.classList.remove('busy');
  button.disabled = false;
  if (!reply.ok) {
    toast(reply.error, { error: true });
    if (reply.missing) showMissing(reply.error);
    return;
  }
  if (action === 'add') {
    window.close();
    return;
  }
  flash(button, true);
  toast('Sent to Root.');
  refreshRecent();
}

// ---- Media found ------------------------------------------------------------------------------

function formatBytes(bytes) {
  if (!bytes) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; }
  return `${value >= 10 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

function mediaName(url) {
  try {
    const parsed = new URL(url);
    const last = decodeURIComponent(parsed.pathname.split('/').filter(Boolean).pop() || '');
    return last || parsed.hostname;
  } catch { return url; }
}

function mediaRow(item) {
  const row = $('media-row').content.firstElementChild.cloneNode(true);
  const kind = row.querySelector('.kind');
  kind.textContent = item.kind;
  kind.classList.toggle('stream', item.kind === 'HLS' || item.kind === 'DASH');
  row.querySelector('.item-title').textContent = mediaName(item.url);
  row.querySelector('.item-title').title = item.url;
  row.querySelector('.item-sub').textContent = [hostOf(item.url), formatBytes(item.size)].filter(Boolean).join(' · ');
  const button = row.querySelector('button');
  button.disabled = !connected;
  button.addEventListener('click', async () => {
    button.disabled = true;
    const reply = await ask('downloadMedia', { url: item.url, pageURL: item.pageURL, title: item.title });
    button.disabled = false;
    if (reply.ok) { flash(button, true); toast('Sent to Root.'); refreshRecent(); }
    else toast(reply.error, { error: true });
  });
  return row;
}

async function refreshMedia() {
  if (!activeTab) return;
  const reply = await ask('media', { tabId: activeTab.id });
  const items = reply.ok ? reply.items : [];
  const key = items.map((i) => i.url).join('\n') + connected;
  if (key === lastMediaKey) return;
  lastMediaKey = key;
  $('media-card').hidden = items.length === 0;
  $('media-count').textContent = items.length ? String(items.length) : '';
  $('media-list').replaceChildren(...items.map(mediaRow));
}

// ---- Recent in Parabolic ----------------------------------------------------------------------

function formatSpeed(bytesPerSecond) {
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  let value = bytesPerSecond;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit += 1; }
  return `${value < 10 && unit > 0 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}

function recentRow(item) {
  const row = $('recent-row').content.firstElementChild.cloneNode(true);
  const status = String(item.status || '').toLowerCase();
  row.querySelector('.item-title').textContent = item.title || mediaName(item.url) || 'Untitled';
  const progress = Number(item.progress);
  const live = status === 'running' && progress >= 0;
  const speed = Number(item.speed) > 0 ? ` · ${formatSpeed(Number(item.speed))}` : '';
  row.querySelector('.item-sub').textContent = live
    ? `${Math.round(progress * 100)}%${speed}`
    : (item.statusText && status !== 'completed' ? item.statusText : (hostOf(item.url) || ''));
  if (live) {
    const bar = document.createElement('div');
    bar.className = 'progress';
    const fill = document.createElement('div');
    fill.className = 'progress-fill';
    fill.style.width = `${Math.max(2, Math.min(100, progress * 100))}%`;
    bar.append(fill);
    row.querySelector('.item-sub').after(bar);
  }
  const chip = row.querySelector('.chip');
  chip.textContent = STATUS_LABELS[status] || status || '—';
  chip.className = `chip ${status}`;
  const box = row.querySelector('.thumb-box');
  const img = box.querySelector('img');
  if (/^https:\/\//i.test(item.thumbnail || '')) {
    img.src = item.thumbnail;
    img.addEventListener('error', () => { box.hidden = true; }, { once: true });
  } else {
    box.hidden = true;
  }
  return row;
}

async function refreshRecent() {
  if (!connected) return;
  const reply = await ask('status');
  if (!reply.ok) {
    if (reply.missing) showMissing(reply.error);
    return;
  }
  const items = reply.items.slice(0, 8);
  const key = JSON.stringify(items.map((i) => [i.url, i.title, i.status, i.progress, i.speed]));
  if (key === lastRecentKey) return;
  lastRecentKey = key;
  $('recent-empty').hidden = items.length > 0;
  $('recent-list').replaceChildren(...items.map(recentRow));
}

// ---- Catching ---------------------------------------------------------------------------------

const siteHost = () => (isWebPage(activeTab?.url) ? CatchRules.siteOf(activeTab.url) : '');

function statusLine(state) {
  if (state.appSetting === null) return { text: 'Not connected to Root', tone: 'off' };
  if (!state.catching) return { text: 'Catching is off', tone: 'off' };
  if (!state.site) return { text: 'Catching downloads', tone: 'on' };
  if (state.siteRule === 'never' || state.appSkipped) return { text: 'Paused on this site', tone: 'paused' };
  if (state.siteRule === 'always' || state.everything) return { text: `Catching everything on · ${state.site}`, tone: 'on' };
  return { text: `Catching on · ${state.site}`, tone: 'on' };
}

function renderSiteRow(state, offline) {
  const label = state.site ? `Don’t catch on ${state.site}` : 'Don’t catch on this site';
  $('site-rule-title').textContent = label;
  $('site-rule-label').textContent = label;
  const toggle = $('site-rule');
  toggle.checked = state.siteRule === 'never' || state.appSkipped;
  toggle.disabled = offline || !state.site || state.appSkipped;
  let sub = 'Only in this browser';
  if (!state.site) sub = 'Open a website to choose';
  else if (state.appSkipped) sub = 'Excluded in Root’s settings';
  else if (state.siteRule === 'always') sub = 'Always catching everything here';
  $('site-rule-sub').textContent = sub;
}

function renderCatch(state) {
  const status = statusLine(state);
  $('catch-status-text').textContent = status.text;
  $('catch-status').dataset.tone = status.tone;

  const offline = state.appSetting === null; // never reached the app: nothing to hand off to
  const toggle = $('catch');
  toggle.checked = Boolean(state.catching);
  toggle.disabled = offline;
  let sub = 'Following Root’s setting';
  if (offline) sub = 'Available once Root is connected';
  else if (state.override !== null && state.override !== state.appSetting) sub = 'Overridden for this browser';
  $('catch-sub').textContent = sub;

  const everything = $('everything');
  everything.checked = Boolean(state.everything);
  everything.disabled = offline || !state.catching;
  const overridden = state.everythingOverride !== null && state.everythingOverride !== state.everythingApp;
  $('everything-sub').textContent = overridden ? 'Any file type and size · this browser' : 'Any file type and size';

  renderSiteRow(state, offline);
}

async function refreshCatch() {
  const state = await ask('catchState', { host: siteHost() });
  if (state.ok) renderCatch(state);
}

async function updateCatch(cmd, payload) {
  const reply = await ask(cmd, { ...payload, host: siteHost() });
  if (reply.ok) {
    renderCatch(reply);
  } else {
    toast(reply.error, { error: true });
    refreshCatch();
  }
}

// ---- Connection + permissions -----------------------------------------------------------------

function showMissing(detail) {
  connected = false;
  $('missing').hidden = false;
  $('recent-card').hidden = true;
  $('missing-detail').textContent = detail || '';
  renderHeader();
}

async function connect() {
  const reply = await ask('handshake');
  if (!reply.ok) {
    if (reply.missing) showMissing(reply.error);
    else { connected = false; toast(reply.error, { error: true }); renderHeader(); }
    return false;
  }
  connected = true;
  $('missing').hidden = true;
  $('recent-card').hidden = false;
  renderHeader();
  return reply;
}

// ---- Other download managers ------------------------------------------------------------------
// Their extensions cancel the same browser downloads Root catches, and whoever cancels first wins.
// Root never turns them off by itself: the user clicks "Turn It Off" (undo at chrome://extensions).

const RIVAL_CATCHERS = {
  ahmpjcflkgiildlgicmcieglgoilbfdp: 'Free Download Manager',
  mdfcjfioplkdchnhcpcobaheocanedjg: 'Free Download Manager',
  ngpampappnmepgilojfohadhhmbhlaek: 'Internet Download Manager',
};

async function enabledRivals() {
  if (!api.management?.getAll) return [];
  try {
    const all = await api.management.getAll();
    return all.filter((ext) => ext.enabled && Object.hasOwn(RIVAL_CATCHERS, ext.id));
  } catch { return []; }
}

async function renderRivals() {
  const rivals = await enabledRivals();
  $('rival').hidden = rivals.length === 0;
  if (rivals.length === 0) return;
  const names = [...new Set(rivals.map((ext) => RIVAL_CATCHERS[ext.id]))].join(' and ');
  $('rival-text').textContent = `${names} also catches downloads in this browser, so files can go there instead of Root.`;
  const button = $('rival-off');
  button.disabled = false;
  button.onclick = async () => {
    button.disabled = true;
    try {
      for (const ext of rivals) await api.management.setEnabled(ext.id, false);
      toast(`${names} turned off. Root catches downloads now.`);
    } catch (error) {
      toast(error?.message || String(error), { error: true });
    }
    renderRivals();
  };
}

async function checkHostPermission() {
  if (!api.permissions?.contains) return;
  const granted = await api.permissions.contains({ origins: ['<all_urls>'] }).catch(() => true);
  $('permission').hidden = granted;
  $('grant').onclick = async () => {
    const ok = await api.permissions.request({ origins: ['<all_urls>'] }).catch(() => false);
    $('permission').hidden = ok;
  };
}

async function init() {
  [activeTab] = await api.tabs.query({ active: true, currentWindow: true });
  renderHeader();
  $('download-page').addEventListener('click', (e) => sendPage('quick', e.currentTarget));
  $('options').addEventListener('click', (e) => sendPage('add', e.currentTarget));
  $('preset').addEventListener('change', (e) => api.storage.local.set({ lastPreset: e.target.value }));
  $('retry').addEventListener('click', async () => {
    const reply = await connect();
    if (reply) { await loadPresets(reply.presets || []); refreshCatch(); refreshRecent(); refreshMedia(); }
  });
  $('catch').addEventListener('change', (e) => updateCatch('setCatch', { value: e.target.checked }));
  $('everything').addEventListener('change', (e) => updateCatch('setEverything', { value: e.target.checked }));
  $('site-rule').addEventListener('change', (e) => updateCatch('setSiteRule', { rule: e.target.checked ? 'never' : null }));

  checkHostPermission();
  renderRivals();
  const reply = await connect();
  if (reply) await loadPresets(reply.presets || []);
  await refreshCatch();
  refreshMedia();
  refreshRecent();
  setInterval(() => { refreshRecent(); refreshMedia(); }, REFRESH_MS);
}

init();
