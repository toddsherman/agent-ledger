// Agent Ledger service worker.
//
// Collects browser metadata (tabs, groups, navigation, debugger attachment, downloads, agent
// extensions), relays content-script events, and forwards everything to the Mac app through
// the native messaging host. The app decides what is recorded; this worker arms and disarms
// tabs on its instruction and reports what it could not observe.
importScripts('/lib/redact.js');

const L = globalThis.AgentLedgerLib;
const HOST = 'com.agentledger.host';
const VERSION = chrome.runtime.getManifest().version;
const INST = 'sw-' + Date.now() + '-' + Math.random().toString(36).slice(2, 6);
const KNOWN_AGENT_EXTENSIONS = {
  fcoeoabgfenejglbffodgkkbkcdhcgfn: 'claude',
  hehggadaopoacecdllhhajmbjkdcmajg: 'codex',
  odlomjlbamekndcpllcnffbgeohgkmjh: 'codex',
};
const DEBUGGER_POLL_MS = 1000;
const MAX_QUEUE = 5000;

let seq = 0;
let port = null;
let appConnected = false;
let lastHostError = null;
let reconnectDelay = 1000;
let reconnectTimer = null;
const queue = [];
let droppedWhileDisconnected = 0;
let flushTimer = null;
/** tabId -> { session, policy, armedAt, agent } */
const armed = new Map();
const debuggerAttached = new Map(); // tabId -> boolean
const requestStarts = new Map(); // requestId -> timeStamp

// --- Envelope and transport --------------------------------------------------------

function emit(kind, cat, fields = {}) {
  const ev = Object.assign({ v: 1, src: 'ext.sw', inst: INST, seq: ++seq, t: Date.now(), kind, cat }, fields);
  if (ev.tab !== undefined && ev.tab !== null) ev.rec = armed.has(ev.tab);
  if (ev.url) ev.url = L.redactUrl(ev.url);
  enqueue(ev);
  return ev;
}

function enqueue(ev) {
  queue.push(ev);
  if (queue.length > MAX_QUEUE) {
    // Drop the oldest unarmed metadata first.
    const idx = queue.findIndex((e) => !e.rec && e.kind !== 'gap');
    queue.splice(idx >= 0 ? idx : 0, 1);
    droppedWhileDisconnected += 1;
  }
  if (!flushTimer) flushTimer = setTimeout(flush, 200);
}

function flush() {
  flushTimer = null;
  if (!port || !queue.length) return;
  if (droppedWhileDisconnected > 0) {
    queue.unshift({ v: 1, src: 'ext.sw', inst: INST, seq: ++seq, t: Date.now(), kind: 'gap', cat: 'gap.extension_queue_overflow', p: { dropped: droppedWhileDisconnected } });
    droppedWhileDisconnected = 0;
  }
  // Keep frames comfortably small.
  while (queue.length) {
    const batch = queue.splice(0, 200);
    try {
      port.postMessage({ type: 'events', events: batch });
    } catch (err) {
      queue.unshift(...batch);
      break;
    }
  }
}

function connect() {
  if (port) return;
  reconnectTimer = null;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (err) {
    port = null;
    scheduleReconnect();
    return;
  }
  port.onMessage.addListener(onHostMessage);
  port.onDisconnect.addListener(() => {
    const reason = chrome.runtime.lastError ? chrome.runtime.lastError.message : 'disconnected';
    port = null;
    lastHostError = reason;
    setAppConnected(false);
    refreshGlobalBadge();
    emit('gap', 'gap.host_disconnected', { p: { reason } });
    scheduleReconnect();
  });
  sendHello();
  sendSnapshot();
  flush();
}

// One ID per install, which means one per Chrome profile: the app tells profiles apart by it.
async function installId() {
  try {
    const got = await chrome.storage.local.get('installId');
    if (got.installId) return got.installId;
    const id = 'inst-' + crypto.randomUUID();
    await chrome.storage.local.set({ installId: id });
    return id;
  } catch (err) {
    return null;
  }
}

async function sendHello() {
  const [id, incognitoAllowed] = await Promise.all([
    installId(),
    chrome.extension.isAllowedIncognitoAccess().catch(() => null),
  ]);
  if (!port) return;
  try {
    port.postMessage({
      type: 'hello', ext: chrome.runtime.id, ver: VERSION, inst: INST, browser: navigator.userAgent,
      installId: id, incognitoAllowed,
    });
  } catch (err) { /* reconnect handles it */ }
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(connect, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, 30000);
}

function setAppConnected(v) {
  if (appConnected === v) return;
  appConnected = v;
  refreshGlobalBadge();
  refreshAllBadges();
}

// --- Commands from the app -----------------------------------------------------------

async function onHostMessage(msg) {
  if (!msg || !msg.type) return;
  if (reconnectDelay !== 1000 || lastHostError) { reconnectDelay = 1000; lastHostError = null; refreshGlobalBadge(); }
  switch (msg.type) {
    case 'status': setAppConnected(!!msg.app); break;
    case 'pong': setAppConnected(!!msg.app); break;
    case 'arm': await armTab(msg.tab, msg.session, msg.policy || {}, msg.agent); break;
    case 'disarm': await disarmTab(msg.tab, msg.session); break;
    case 'snapshot': await sendSnapshot(); break;
    case 'ping': port && port.postMessage({ type: 'pong' }); break;
    // The app installed a newer copy of this (unpacked) extension: pick it up.
    case 'reload': if (msg.version !== chrome.runtime.getManifest().version || msg.force) chrome.runtime.reload(); break;
    default: break;
  }
}

async function persistArmed() {
  const obj = {};
  for (const [tab, v] of armed) obj[tab] = v;
  try { await chrome.storage.session.set({ armed: obj }); } catch (_) { /* ignore */ }
}

async function restoreArmed() {
  try {
    const { armed: obj } = await chrome.storage.session.get('armed');
    if (obj) for (const [tab, v] of Object.entries(obj)) armed.set(Number(tab), v);
  } catch (_) { /* ignore */ }
}

const RESTRICTED = /^(chrome|chrome-extension|chrome-untrusted|devtools|view-source|edge|about):|^https:\/\/chromewebstore\.google\.com|^https:\/\/chrome\.google\.com\/webstore/;

async function injectCapture(tabId) {
  await chrome.scripting.executeScript({
    target: { tabId, allFrames: true },
    files: ['lib/redact.js', 'lib/describe-element.js', 'content/capture.js'],
  });
}

async function sendToContent(tabId, message) {
  try {
    await chrome.tabs.sendMessage(tabId, message);
    return true;
  } catch (_) {
    return false;
  }
}

async function armTab(tabId, session, policy, agent) {
  if (typeof tabId !== 'number') return;
  armed.set(tabId, { session, policy, agent: agent || null, armedAt: Date.now() });
  await persistArmed();
  let tab = null;
  try { tab = await chrome.tabs.get(tabId); } catch (_) { /* closed */ }
  if (!tab) {
    emit('gap', 'gap.tab_missing', { tab: tabId, p: { session } });
    return;
  }
  emit('context', 'capture.armed', { tab: tabId, win: tab.windowId, url: tab.url, p: { session, title: tab.title, policy } });
  if (tab.url && RESTRICTED.test(tab.url)) {
    emit('gap', 'gap.page_inaccessible', { tab: tabId, url: tab.url, p: { session, reason: 'restricted-url' } });
  } else {
    let ok = await sendToContent(tabId, { type: 'arm', policy, session });
    if (!ok) {
      try { await injectCapture(tabId); ok = await sendToContent(tabId, { type: 'arm', policy, session }); } catch (_) { ok = false; }
    }
    if (!ok) emit('gap', 'gap.content_unavailable', { tab: tabId, url: tab.url, p: { session } });
  }
  refreshBadge(tabId);
}

async function disarmTab(tabId, session) {
  if (!armed.has(tabId)) return;
  const entry = armed.get(tabId);
  if (session && entry.session && entry.session !== session) return;
  armed.delete(tabId);
  await persistArmed();
  await sendToContent(tabId, { type: 'disarm' });
  emit('context', 'capture.disarmed', { tab: tabId, p: { session: entry.session } });
  refreshBadge(tabId);
}

/** Global badge: '!' when the app can't be reached, with the reason in the tooltip. */
function refreshGlobalBadge() {
  const problem = !appConnected;
  chrome.action.setBadgeText({ text: problem ? '!' : '' }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ color: '#B26A00' }).catch(() => {});
  const why = lastHostError ? lastHostError : 'the Agent Ledger app is not running';
  chrome.action.setTitle({ title: problem ? 'Agent Ledger: not connected (' + why + ')' : 'Agent Ledger: connected' }).catch(() => {});
}

function refreshBadge(tabId) {
  const isArmed = armed.has(tabId);
  // null falls back to the global badge for tabs that aren't recording.
  const text = isArmed ? (appConnected ? 'REC' : 'REC!') : null;
  chrome.action.setBadgeText({ tabId, text }).catch(() => {});
  if (isArmed) {
    chrome.action.setBadgeBackgroundColor({ tabId, color: appConnected ? '#C62828' : '#8D6E63' }).catch(() => {});
    const who = armed.get(tabId).agent || 'an agent';
    chrome.action.setTitle({ tabId, title: 'Agent Ledger: recording this tab (' + who + ')' + (appConnected ? '' : ' — app not reachable') }).catch(() => {});
  } else {
    chrome.action.setTitle({ tabId, title: appConnected ? 'Agent Ledger: connected, not recording this tab' : 'Agent Ledger: not connected (' + (lastHostError || 'app not running') + ')' }).catch(() => {});
  }
}

function refreshAllBadges() {
  chrome.tabs.query({}).then((tabs) => tabs.forEach((t) => refreshBadge(t.id))).catch(() => {});
}

// --- Snapshot ------------------------------------------------------------------------

function tabFields(t) {
  return {
    tab: t.id, win: t.windowId, url: t.url || t.pendingUrl,
    p: { title: L.clean ? L.clean(t.title, 200) : t.title, groupId: t.groupId, active: t.active, index: t.index,
      pinned: t.pinned, status: t.status, openerTabId: t.openerTabId, discarded: t.discarded },
  };
}

async function sendSnapshot() {
  try {
    const tabs = await chrome.tabs.query({});
    for (const t of tabs) emit('context', 'tab.snapshot', tabFields(t));
    const groups = await chrome.tabGroups.query({});
    for (const g of groups) emit('context', 'group.snapshot', { win: g.windowId, p: groupPayload(g) });
    await pollDebugger(true);
    await reportAgentExtensions('snapshot');
    for (const tabId of armed.keys()) refreshBadge(tabId);
  } catch (err) {
    emit('sensor_health', 'health.snapshot_failed', { p: { error: String(err && err.message || err) } });
  }
}

function groupPayload(g) {
  return { groupId: g.id, title: g.title || '', color: g.color, collapsed: g.collapsed };
}

async function reportAgentExtensions(reason) {
  try {
    const all = await chrome.management.getAll();
    const agents = all.filter((e) => KNOWN_AGENT_EXTENSIONS[e.id]).map((e) => ({
      id: e.id, agent: KNOWN_AGENT_EXTENSIONS[e.id], name: e.name, version: e.version, enabled: e.enabled,
    }));
    emit('context', 'ext.agents', { p: { reason, agents } });
  } catch (err) {
    emit('sensor_health', 'health.management_unavailable', { p: { error: String(err && err.message || err) } });
  }
}

// --- Debugger attachment polling ---------------------------------------------------

let debuggerPollFailed = false;
async function pollDebugger(force) {
  let targets;
  try {
    targets = await chrome.debugger.getTargets();
    if (debuggerPollFailed) { debuggerPollFailed = false; emit('sensor_health', 'health.debugger_poll_ok', {}); }
  } catch (err) {
    if (!debuggerPollFailed) {
      debuggerPollFailed = true;
      emit('gap', 'gap.debugger_poll_failed', { p: { error: String(err && err.message || err) } });
    }
    return;
  }
  const seen = new Set();
  for (const t of targets) {
    if (t.type !== 'page' || typeof t.tabId !== 'number') continue;
    seen.add(t.tabId);
    const prev = debuggerAttached.get(t.tabId);
    if (force || prev !== t.attached) {
      debuggerAttached.set(t.tabId, t.attached);
      if (force && !t.attached && prev === undefined) continue;
      emit('context', t.attached ? 'debugger.attached' : 'debugger.detached', {
        tab: t.tabId, url: t.url, p: { title: t.title, snapshot: !!force },
      });
    }
  }
  for (const tabId of Array.from(debuggerAttached.keys())) {
    if (!seen.has(tabId)) debuggerAttached.delete(tabId);
  }
}
setInterval(() => { pollDebugger(false); }, DEBUGGER_POLL_MS);

// --- Tabs, windows and groups -------------------------------------------------------

chrome.tabs.onCreated.addListener((t) => emit('context', 'tab.created', tabFields(t)));

chrome.tabs.onUpdated.addListener((tabId, info, t) => {
  const interesting = ['url', 'title', 'status', 'groupId', 'pinned', 'discarded'].filter((k) => k in info);
  if (!interesting.length) return;
  const f = tabFields(t);
  f.p.changed = interesting;
  if ('groupId' in info) f.p.groupId = info.groupId;
  emit('context', 'tab.updated', f);
  if (armed.has(tabId) && info.url && RESTRICTED.test(info.url)) {
    emit('gap', 'gap.page_inaccessible', { tab: tabId, url: info.url, p: { reason: 'restricted-url', session: armed.get(tabId).session } });
  }
});

chrome.tabs.onRemoved.addListener((tabId, info) => {
  emit('context', 'tab.removed', { tab: tabId, win: info.windowId, p: { windowClosing: info.isWindowClosing } });
  if (armed.has(tabId)) { armed.delete(tabId); persistArmed(); }
  debuggerAttached.delete(tabId);
});

chrome.tabs.onActivated.addListener((info) => emit('context', 'tab.activated', { tab: info.tabId, win: info.windowId }));
chrome.tabs.onReplaced.addListener((added, removed) => {
  emit('context', 'tab.replaced', { tab: added, p: { replaced: removed } });
  if (armed.has(removed)) { armed.set(added, armed.get(removed)); armed.delete(removed); persistArmed(); }
});
chrome.tabs.onAttached.addListener((tabId, info) => emit('context', 'tab.attached', { tab: tabId, win: info.newWindowId }));
chrome.tabs.onDetached.addListener((tabId, info) => emit('context', 'tab.detached', { tab: tabId, win: info.oldWindowId }));

chrome.windows.onFocusChanged.addListener((windowId) => emit('context', 'window.focus', { win: windowId, p: { chromeFocused: windowId !== chrome.windows.WINDOW_ID_NONE } }));
chrome.windows.onCreated.addListener((w) => emit('context', 'window.created', { win: w.id, p: { type: w.type, incognito: w.incognito } }));
chrome.windows.onRemoved.addListener((windowId) => emit('context', 'window.removed', { win: windowId }));

chrome.tabGroups.onCreated.addListener((g) => emit('context', 'group.created', { win: g.windowId, p: groupPayload(g) }));
chrome.tabGroups.onUpdated.addListener((g) => emit('context', 'group.updated', { win: g.windowId, p: groupPayload(g) }));
chrome.tabGroups.onRemoved.addListener((g) => emit('context', 'group.removed', { win: g.windowId, p: groupPayload(g) }));

// --- Navigation ------------------------------------------------------------------------

function navFields(d) {
  return {
    tab: d.tabId, frame: d.frameId, doc: d.documentId, url: d.url,
    p: { transition: d.transitionType, qualifiers: d.transitionQualifiers, parentFrame: d.parentFrameId,
      lifecycle: d.documentLifecycle },
  };
}

chrome.webNavigation.onCommitted.addListener((d) => {
  if (d.frameId !== 0 && !armed.has(d.tabId)) return;
  emit('observed_effect', 'nav.committed', navFields(d));
});
chrome.webNavigation.onHistoryStateUpdated.addListener((d) => {
  if (d.frameId !== 0 && !armed.has(d.tabId)) return;
  emit('observed_effect', 'nav.history', navFields(d));
});
chrome.webNavigation.onReferenceFragmentUpdated.addListener((d) => {
  if (d.frameId !== 0) return;
  emit('observed_effect', 'nav.fragment', navFields(d));
});
chrome.webNavigation.onErrorOccurred.addListener((d) => {
  if (!armed.has(d.tabId)) return;
  emit('observed_effect', 'nav.error', { tab: d.tabId, frame: d.frameId, url: d.url, p: { error: d.error } });
});
chrome.webNavigation.onCreatedNavigationTarget.addListener((d) => {
  emit('context', 'nav.new_target', { tab: d.tabId, url: d.url, p: { sourceTab: d.sourceTabId, sourceFrame: d.sourceFrameId } });
});

// --- Network metadata (armed tabs only, no bodies) ----------------------------------

const RECORD_GET_TYPES = new Set(['main_frame', 'sub_frame', 'xmlhttprequest', 'websocket', 'ping', 'other']);
const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

function shouldRecordRequest(d) {
  if (d.tabId < 0 || !armed.has(d.tabId)) return false;
  if (!SAFE_METHODS.has(d.method)) return true;
  return RECORD_GET_TYPES.has(d.type);
}

chrome.webRequest.onBeforeRequest.addListener((d) => {
  if (shouldRecordRequest(d)) requestStarts.set(d.requestId, d.timeStamp);
}, { urls: ['<all_urls>'] });

function onRequestDone(d, error) {
  if (!requestStarts.has(d.requestId)) return;
  const start = requestStarts.get(d.requestId);
  requestStarts.delete(d.requestId);
  emit('observed_effect', 'net.request', {
    tab: d.tabId, frame: d.frameId, doc: d.documentId, url: d.url,
    p: {
      method: d.method, status: d.statusCode || null, type: d.type, initiator: d.initiator || null,
      mutating: !SAFE_METHODS.has(d.method), fromCache: !!d.fromCache, durationMs: Math.round(d.timeStamp - start),
      error: error || null, ip: d.ip || null,
    },
  });
}
chrome.webRequest.onCompleted.addListener((d) => onRequestDone(d, null), { urls: ['<all_urls>'] });
chrome.webRequest.onErrorOccurred.addListener((d) => onRequestDone(d, d.error), { urls: ['<all_urls>'] });

// --- Downloads ----------------------------------------------------------------------

function downloadPayload(item) {
  const name = item.filename ? item.filename.split('/').pop() : null;
  return { id: item.id, byExtensionId: item.byExtensionId || null, byExtensionName: item.byExtensionName || null,
    agent: item.byExtensionId ? KNOWN_AGENT_EXTENSIONS[item.byExtensionId] || null : null,
    mime: item.mime, filename: name, state: item.state, referrer: L.redactUrl(item.referrer || ''), bytes: item.totalBytes };
}
chrome.downloads.onCreated.addListener((item) => emit('observed_effect', 'download.created', { url: item.finalUrl || item.url, p: downloadPayload(item) }));
chrome.downloads.onChanged.addListener((delta) => {
  if (!delta.state && !delta.error) return;
  emit('observed_effect', 'download.changed', { p: { id: delta.id, state: delta.state ? delta.state.current : null, error: delta.error ? delta.error.current : null } });
});

// --- Agent extensions -------------------------------------------------------------

for (const evName of ['onEnabled', 'onDisabled', 'onInstalled', 'onUninstalled']) {
  chrome.management[evName].addListener((info) => {
    const id = typeof info === 'string' ? info : info.id;
    if (KNOWN_AGENT_EXTENSIONS[id]) reportAgentExtensions(evName);
  });
}

// --- Content scripts ----------------------------------------------------------------

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || !sender.tab) return;
  const tabId = sender.tab.id;
  if (msg.type === 'status') {
    // Diagnostics for the local testbed page only (the content script enforces the origin).
    sendResponse({ appConnected, lastHostError, armedTabs: Array.from(armed.keys()), inst: INST, version: VERSION,
      queued: queue.length, thisTabArmed: armed.has(tabId) });
    return;
  }
  if (msg.type === 'hello') {
    const entry = armed.get(tabId);
    sendResponse(entry ? { armed: true, policy: entry.policy, session: entry.session } : { armed: false });
    return;
  }
  if (msg.type === 'events' && Array.isArray(msg.events)) {
    for (const ev of msg.events.slice(0, 500)) {
      ev.tab = tabId;
      ev.win = sender.tab.windowId;
      ev.frame = sender.frameId;
      if (sender.documentId) ev.doc = sender.documentId;
      ev.rec = armed.has(tabId) && ev.rec === true;
      enqueue(ev);
    }
  }
});

// --- Lifecycle ----------------------------------------------------------------------

chrome.runtime.onInstalled.addListener(async (details) => {
  emit('sensor_health', 'health.installed', { p: { reason: details.reason, previousVersion: details.previousVersion || null } });
  // Tabs opened before install/update have no content script; add dormant capture to them.
  const tabs = await chrome.tabs.query({});
  for (const t of tabs) {
    if (!t.url || RESTRICTED.test(t.url) || t.discarded) continue;
    injectCapture(t.id).catch(() => {});
  }
});

chrome.runtime.onStartup.addListener(() => emit('sensor_health', 'health.browser_startup', {}));

chrome.alarms.create('keepalive', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name !== 'keepalive') return;
  if (!port) connect();
  emit('sensor_health', 'health.heartbeat', { p: { armedTabs: armed.size, queued: queue.length, appConnected } });
});

(async () => {
  await restoreArmed();
  emit('sensor_health', 'health.sw_started', { p: { version: VERSION, restoredArmedTabs: armed.size } });
  refreshGlobalBadge();
  connect();
})();
