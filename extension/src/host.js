// Native-messaging client for com.hamad.parabolic.host. One lazily opened port; replies are
// matched by requestId. The port closes after a short idle period so the host process (and,
// in Chromium, the service worker) isn't kept alive forever.
'use strict';

/* exported Host, HostError */
const HOST_IDLE_MS = 20_000;
const HOST_TIMEOUT_MS = 15_000;

class HostError extends Error {
  constructor(message, missing = false) {
    super(message);
    this.name = 'HostError';
    this.missing = missing;
  }
}

const Host = (() => {
  let port = null;
  let nextId = 1;
  let idleTimer = null;
  const pending = new Map();

  function looksMissing(message) {
    return /not found|no such native application|not installed|forbidden|access to the specified native/i
      .test(message || '');
  }

  function rejectAll(error) {
    for (const { reject, timer } of pending.values()) {
      clearTimeout(timer);
      reject(error);
    }
    pending.clear();
  }

  function scheduleIdleClose() {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      if (pending.size === 0 && port) {
        port.disconnect();
        port = null;
      }
    }, HOST_IDLE_MS);
  }

  function open() {
    if (port) return port;
    const p = api.runtime.connectNative(HOST_NAME);
    p.onMessage.addListener((reply) => {
      const entry = pending.get(reply?.requestId);
      if (!entry) return;
      pending.delete(reply.requestId);
      clearTimeout(entry.timer);
      entry.resolve(reply);
      scheduleIdleClose();
    });
    p.onDisconnect.addListener((disconnected) => {
      const message = disconnected?.error?.message || api.runtime.lastError?.message
        || 'Root’s helper closed unexpectedly.';
      if (port === p) port = null;
      rejectAll(new HostError(message, looksMissing(message)));
    });
    port = p;
    return p;
  }

  /** Sends one request ({type, ...}) and resolves with the host's reply. */
  function request(message) {
    return new Promise((resolve, reject) => {
      const requestId = `r${Date.now().toString(36)}-${nextId++}`;
      const timer = setTimeout(() => {
        pending.delete(requestId);
        reject(new HostError('Root didn’t answer in time.'));
      }, HOST_TIMEOUT_MS);
      pending.set(requestId, { resolve, reject, timer });
      try {
        open().postMessage({ ...message, requestId });
      } catch (error) {
        pending.delete(requestId);
        clearTimeout(timer);
        const text = error?.message || String(error);
        reject(new HostError(text, looksMissing(text)));
      }
    });
  }

  /** Like request(), but turns `{ok:false}` into a rejection. */
  async function call(message) {
    const reply = await request(message);
    if (!reply || reply.ok !== true) throw new HostError(reply?.error || 'Root refused the request.');
    return reply;
  }

  /** Hands links to the app. action: quick | add | batch. */
  function download(action, items, preset) {
    const message = { type: 'download', action, items };
    if (preset) message.preset = preset;
    return call(message);
  }

  return {
    handshake: () => call({ type: 'handshake' }),
    status: () => call({ type: 'status' }),
    settings: () => call({ type: 'settings' }),
    download,
  };
})();
