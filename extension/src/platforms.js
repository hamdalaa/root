// Hostname → platform name + accent dot for the popup header. No brand artwork, just a colour.
'use strict';

/* exported detectPlatform */
const PLATFORMS = [
  { name: 'YouTube Music', hosts: ['music.youtube.com'], color: '#FF0033' },
  { name: 'YouTube', hosts: ['youtube.com', 'youtu.be', 'youtube-nocookie.com'], color: '#FF0033' },
  { name: 'SoundCloud', hosts: ['soundcloud.com'], color: '#8E8E93' },
  { name: 'Spotify', hosts: ['spotify.com'], color: '#1ED760' },
  { name: 'Deezer', hosts: ['deezer.com'], color: '#A238FF' },
  { name: 'Apple Music', hosts: ['music.apple.com'], color: '#FA2D48' },
  { name: 'TikTok', hosts: ['tiktok.com'], color: '#25F4EE' },
  { name: 'Instagram', hosts: ['instagram.com'], color: '#E1306C' },
  { name: 'X', hosts: ['x.com', 'twitter.com'], color: '#8E8E93' },
  { name: 'Facebook', hosts: ['facebook.com', 'fb.watch'], color: '#0866FF' },
  { name: 'Vimeo', hosts: ['vimeo.com'], color: '#17D5FF' },
  { name: 'Twitch', hosts: ['twitch.tv'], color: '#9146FF' },
  { name: 'Reddit', hosts: ['reddit.com', 'redd.it'], color: '#8E8E93' },
  { name: 'Bandcamp', hosts: ['bandcamp.com'], color: '#1DA0C3' },
  { name: 'Dailymotion', hosts: ['dailymotion.com', 'dai.ly'], color: '#3C8CFF' },
  { name: 'Bilibili', hosts: ['bilibili.com', 'b23.tv'], color: '#00A1D6' },
  { name: 'Mixcloud', hosts: ['mixcloud.com'], color: '#5000FF' },
  { name: 'Tidal', hosts: ['tidal.com'], color: '#8E8E93' },
  { name: 'Pinterest', hosts: ['pinterest.com'], color: '#E60023' },
  { name: 'Threads', hosts: ['threads.net', 'threads.com'], color: '#8E8E93' },
  { name: 'Bluesky', hosts: ['bsky.app'], color: '#0A84FF' },
  { name: 'Rumble', hosts: ['rumble.com'], color: '#85C742' },
  { name: 'Kick', hosts: ['kick.com'], color: '#53FC18' },
  { name: 'Archive.org', hosts: ['archive.org'], color: '#8E8E93' },
];

/** {name, color, known} for a page URL; unknown sites fall back to the bare hostname. */
function detectPlatform(url) {
  let host = '';
  try { host = new URL(url).hostname.toLowerCase().replace(/^www\./, ''); } catch { /* not a URL */ }
  if (!host) return { name: 'No web page', color: '#8E8E93', known: false };
  const match = PLATFORMS.find((p) => p.hosts.some((h) => host === h || host.endsWith(`.${h}`)));
  return match ? { name: match.name, color: match.color, known: true } : { name: host, color: '#0A84FF', known: false };
}
