// A brief green check on the toolbar icon whenever a download was handed to Parabolic. The
// media count badge (Sniffer) comes back afterwards.
'use strict';

/* exported Feedback */
const CAUGHT_BADGE_MS = 2_500;
const CAUGHT_GREEN = '#34C759';

const Feedback = (() => {
  const timers = new Map(); // tabId (or 'all') → timer

  function setBadge(tabId, text, color) {
    const scope = tabId >= 0 ? { tabId } : {};
    api.action.setBadgeBackgroundColor({ ...scope, color }).catch?.(() => {});
    api.action.setBadgeText({ ...scope, text }).catch?.(() => {});
  }

  /** Shows "✓" on `tabId` (or globally when the tab is unknown), then restores the badge. */
  function caught(tabId) {
    const key = Number.isInteger(tabId) && tabId >= 0 ? tabId : 'all';
    const id = key === 'all' ? -1 : key;
    clearTimeout(timers.get(key));
    setBadge(id, '✓', CAUGHT_GREEN);
    timers.set(key, setTimeout(() => {
      timers.delete(key);
      if (id >= 0) {
        setBadge(id, '', SNIFF_BADGE_COLOR);
        Sniffer.refreshBadge(id);
      } else {
        setBadge(-1, '', SNIFF_BADGE_COLOR);
      }
    }, CAUGHT_BADGE_MS));
  }

  return { caught };
})();
