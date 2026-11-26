// Shared by every context (background, popup). Firefox exposes promise-based `browser`;
// Chromium MV3 exposes promise-capable `chrome`. Everything else uses `api`.
'use strict';

/* exported api, HOST_NAME, IS_FIREFOX, PB_ICON, isDownloadableURL, hostOf */
var api = globalThis.browser ?? globalThis.chrome;
var HOST_NAME = 'com.hamad.parabolic.host';
var IS_FIREFOX = typeof globalThis.browser !== 'undefined' && typeof api.runtime.getBrowserInfo === 'function';
var PB_ICON = 'icons/icon-128.png';

/** True for links Parabolic accepts (the host rejects anything else). */
function isDownloadableURL(url) {
  return typeof url === 'string' && /^(https?:\/\/|magnet:\?)/i.test(url);
}

/** Lower-cased hostname, or '' for unparsable URLs. */
function hostOf(url) {
  try { return new URL(url).hostname.toLowerCase(); } catch { return ''; }
}
