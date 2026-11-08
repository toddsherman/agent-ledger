// Agent Ledger content script (isolated world, every frame).
//
// Dormant by default: it keeps a 60-second in-page ring of interaction metadata (element
// descriptions, never values) and sends nothing. When the service worker arms the tab for a
// recorded session, it flushes that ring as prebuffered events and streams interactions,
// field before/after values (subject to policy and redaction), submits and outcome text.
(function () {
  'use strict';
  if (window.__agentLedgerCapture) return;
  window.__agentLedgerCapture = true;

  const L = globalThis.AgentLedgerLib;
  if (!L || !chrome.runtime || !chrome.runtime.id) return;

  const RING_MS = 60000;
  const RING_MAX = 300;
  const INPUT_SETTLE_MS = 800;

  let armed = false;
  let dead = false;
  let policy = { values: true, prebufferMs: 60000, maxValue: 2048 };
  const ring = [];
  const queue = [];
  let flushTimer = null;
  // field -> the last value the ledger knows: noted when recording starts (or the field appears),
  // on first focus, and after each reported change. It is the "before" of the next change.
  const focusValues = new WeakMap();
  const formBaselines = new WeakMap(); // form -> {selector: value}
  const inputTimers = new WeakMap();
  const inputTrust = new WeakMap(); // field -> whether its last input event was trusted
  const FIELD_SELECTOR = 'input, textarea, select, [contenteditable]';
  // Live regions that password managers and similar extensions inject into pages.
  const FOREIGN_REGION = /^(1p-|com-1password|onepassword|lastpass|__lp|bitwarden|bw-|dashlane|grammarly)/i;
  let mutationObserver = null;
  let domCounts = { added: 0, removed: 0, attributes: 0, text: 0 };
  let domTimer = null;
  const recentAlerts = new Map();

  const isTop = (() => { try { return window === window.top; } catch (_) { return false; } })();

  function now() {
    return performance.timeOrigin + performance.now();
  }

  function pageContext() {
    let focus = false;
    try { focus = document.hasFocus(); } catch (_) { /* ignore */ }
    return { focus, vis: document.visibilityState, top: isTop };
  }

  function alive() {
    if (dead) return false;
    try {
      if (!chrome.runtime || !chrome.runtime.id) { dead = true; return false; }
    } catch (_) { dead = true; return false; }
    return true;
  }

  function send(msg) {
    if (!alive()) return;
    try {
      const p = chrome.runtime.sendMessage(msg);
      if (p && typeof p.catch === 'function') p.catch(() => {});
    } catch (_) {
      dead = true;
    }
  }

  function flush() {
    flushTimer = null;
    if (!queue.length) return;
    send({ type: 'events', events: queue.splice(0, queue.length) });
  }

  function schedule() {
    if (!flushTimer) flushTimer = setTimeout(flush, 250);
  }

  function trimRing() {
    const cutoff = now() - RING_MS;
    while (ring.length && (ring.length > RING_MAX || ring[0].t < cutoff)) ring.shift();
  }

  function emit(kind, cat, payload) {
    const ev = {
      v: 1, src: 'ext.content', t: now(), kind, cat,
      url: L.redactUrl(location.href),
      p: Object.assign(pageContext(), payload || {}),
    };
    if (!armed) {
      ring.push(ev);
      trimRing();
      return;
    }
    ev.rec = true;
    queue.push(ev);
    schedule();
  }

  function valuesAllowed() {
    return armed && policy && policy.values;
  }

  function readValue(el) {
    return L.readValue(el, valuesAllowed() ? policy : { values: false });
  }

  function snapshotForm(form) {
    if (!form || formBaselines.has(form) || !valuesAllowed()) return;
    const fields = {};
    const els = form.elements ? Array.from(form.elements).slice(0, 150) : [];
    for (const f of els) {
      if (!L.isField(f)) continue;
      const t = (f.type || '').toLowerCase();
      if (['submit', 'button', 'reset', 'image', 'file'].includes(t)) continue;
      fields[L.selectorPath(f)] = focusValues.get(f) || readValue(f);
    }
    formBaselines.set(form, fields);
  }

  /** Notes the current value of every field under `root` the ledger hasn't seen yet. */
  function noteFields(root) {
    if (!armed || !root || typeof root.querySelectorAll !== 'function') return;
    const els = root.nodeType === 1 && root.matches(FIELD_SELECTOR) ? [root] : [];
    for (const el of root.querySelectorAll(FIELD_SELECTOR)) { if (els.length >= 400) break; els.push(el); }
    for (const el of els) {
      if (L.isField(el) && !focusValues.has(el)) focusValues.set(el, readValue(el));
    }
    const forms = root.nodeType === 1 && root.tagName === 'FORM' ? [root] : Array.from(root.querySelectorAll('form')).slice(0, 50);
    forms.forEach(snapshotForm);
  }

  /**
   * Reports a field whose value changed without a `change` event: values set by script
   * (Playwright-style fill, frameworks) and contenteditable edits. Called on blur and submit.
   */
  function reportSilentChange(el) {
    const before = focusValues.get(el);
    if (!before) return;
    const after = readValue(el);
    if (JSON.stringify(before) === JSON.stringify(after)) return;
    focusValues.set(el, after);
    const editable = !!el.isContentEditable;
    const payload = { trusted: inputTrust.has(el) ? inputTrust.get(el) : false, target: L.describe(el), before, after };
    if (!editable) payload.noChangeEvent = true;
    emit('observed_effect', editable ? 'edit.change' : 'field.change', payload);
  }

  function eventTarget(e) {
    const path = typeof e.composedPath === 'function' ? e.composedPath() : [];
    const first = path.find((n) => n && n.nodeType === 1) || e.target;
    return first && first.nodeType === 1 ? first : (e.target && e.target.parentElement) || null;
  }

  function inputMeta(e) {
    return { trusted: e.isTrusted };
  }

  // --- Listeners -----------------------------------------------------------

  function onClick(e) {
    const target = L.actionable(eventTarget(e));
    if (!target) return;
    emit('observed_effect', 'ui.click', Object.assign(inputMeta(e), {
      target: L.describe(target),
      button: e.button,
      x: Math.round(e.clientX), y: Math.round(e.clientY),
      mods: [e.altKey && 'alt', e.ctrlKey && 'ctrl', e.metaKey && 'meta', e.shiftKey && 'shift'].filter(Boolean),
    }));
  }

  function onFocusIn(e) {
    const el = eventTarget(e);
    if (!el || !L.isField(el)) return;
    if (armed) {
      if (!focusValues.has(el)) focusValues.set(el, readValue(el));
      snapshotForm(el.form || (el.closest && el.closest('form')));
    }
    emit('observed_effect', 'ui.focus', Object.assign(inputMeta(e), { target: L.describe(el) }));
  }

  function onInput(e) {
    const el = eventTarget(e);
    if (!el || !L.isField(el)) return;
    const prev = inputTimers.get(el);
    if (prev) clearTimeout(prev.timer);
    const state = prev || { count: 0, trusted: e.isTrusted, inputType: e.inputType };
    inputTrust.set(el, e.isTrusted);
    state.count += 1;
    state.trusted = state.trusted && e.isTrusted;
    state.timer = setTimeout(() => {
      inputTimers.delete(el);
      const payload = { target: L.describe(el), inputs: state.count, inputType: state.inputType, trusted: state.trusted };
      if (armed) payload.value = readValue(el);
      emit('observed_effect', 'field.input', payload);
    }, INPUT_SETTLE_MS);
    inputTimers.set(el, state);
  }

  function onChange(e) {
    const el = eventTarget(e);
    if (!el || !L.isField(el)) return;
    const payload = Object.assign(inputMeta(e), { target: L.describe(el) });
    if (armed) {
      const before = focusValues.get(el);
      const after = readValue(el);
      if (before) payload.before = before;
      payload.after = after;
      focusValues.set(el, after);
    }
    emit('observed_effect', 'field.change', payload);
  }

  function onFocusOut(e) {
    const el = eventTarget(e);
    if (!el || !armed || !L.isField(el)) return;
    // A native `change` (fired before blur) has already moved the baseline, so this only
    // reports values that changed without one.
    reportSilentChange(el);
  }

  function onSubmit(e) {
    const form = e.target;
    if (!form || String(form.tagName).toLowerCase() !== 'form') return;
    const payload = Object.assign(inputMeta(e), {
      form: {
        selector: L.selectorPath(form, 3),
        id: form.id || null,
        name: form.getAttribute('name'),
        method: String(form.getAttribute('method') || 'get').toLowerCase(),
        action: L.redactUrl(form.action || ''),
      },
    });
    const submitter = e.submitter ? L.describe(e.submitter) : null;
    if (submitter) payload.submitter = submitter;
    if (armed) {
      const baseline = formBaselines.get(form) || {};
      const fields = [];
      const els = form.elements ? Array.from(form.elements).slice(0, 150) : [];
      // Submitting with Enter, or by script, may never blur the edited field.
      for (const f of els) { if (L.isField(f)) reportSilentChange(f); }
      for (const f of els) {
        if (!L.isField(f)) continue;
        const t = (f.type || '').toLowerCase();
        if (['submit', 'button', 'reset', 'image'].includes(t)) continue;
        const key = L.selectorPath(f);
        const value = t === 'file' ? { files: f.files ? f.files.length : 0 } : readValue(f);
        const entry = { field: L.describe(f), value };
        if (baseline[key] && JSON.stringify(baseline[key]) !== JSON.stringify(value)) entry.before = baseline[key];
        fields.push(entry);
      }
      payload.fields = fields;
      formBaselines.delete(form);
    }
    emit('observed_effect', 'form.submit', payload);
  }

  function onKeyDown(e) {
    const special = ['Enter', 'Escape', 'Tab'].includes(e.key);
    const shortcut = (e.metaKey || e.ctrlKey) && e.key && e.key.length === 1;
    if (!special && !shortcut) return;
    const el = eventTarget(e);
    emit('observed_effect', 'ui.key', Object.assign(inputMeta(e), {
      key: special ? e.key : e.key.toLowerCase(),
      mods: [e.altKey && 'alt', e.ctrlKey && 'ctrl', e.metaKey && 'meta', e.shiftKey && 'shift'].filter(Boolean),
      target: el ? L.describe(el) : null,
    }));
  }

  function onPaste(e) {
    const el = eventTarget(e);
    let length = null;
    try { length = e.clipboardData ? e.clipboardData.getData('text/plain').length : null; } catch (_) { /* ignore */ }
    emit('observed_effect', 'ui.paste', Object.assign(inputMeta(e), { target: el ? L.describe(el) : null, length }));
  }

  function onInvalid(e) {
    const el = e.target;
    if (!el || !L.isField(el)) return;
    emit('observed_effect', 'page.validation', { target: L.describe(el), message: L.clean(el.validationMessage, 200) });
  }

  let lastScroll = 0;
  function onScroll() {
    const t = now();
    if (t - lastScroll < 1500) return;
    lastScroll = t;
    const doc = document.scrollingElement || document.documentElement;
    emit('observed_effect', 'ui.scroll', { y: Math.round(window.scrollY), maxY: doc ? Math.round(doc.scrollHeight - window.innerHeight) : null });
  }

  function onVisibility() {
    emit('context', 'page.visibility', {});
  }

  const opts = { capture: true, passive: true };
  window.addEventListener('click', onClick, opts);
  window.addEventListener('auxclick', onClick, opts);
  window.addEventListener('focusin', onFocusIn, opts);
  window.addEventListener('focusout', onFocusOut, opts);
  window.addEventListener('input', onInput, opts);
  window.addEventListener('change', onChange, opts);
  window.addEventListener('submit', onSubmit, opts);
  window.addEventListener('keydown', onKeyDown, opts);
  window.addEventListener('paste', onPaste, opts);
  window.addEventListener('invalid', onInvalid, opts);
  window.addEventListener('scroll', onScroll, opts);
  document.addEventListener('visibilitychange', onVisibility, opts);
  window.addEventListener('pagehide', flush, opts);

  // --- Outcome evidence (armed only) --------------------------------------------

  const LIVE_SELECTOR = '[role="alert"],[role="status"],[role="alertdialog"],[role="dialog"],[aria-live]:not([aria-live="off"]),dialog[open]';

  function liveRegionFor(node) {
    const el = node.nodeType === 1 ? node : node.parentElement;
    if (!el || typeof el.closest !== 'function') return null;
    return el.closest(LIVE_SELECTOR);
  }

  function reportAlert(region) {
    if (FOREIGN_REGION.test(region.id || '') || FOREIGN_REGION.test(typeof region.className === 'string' ? region.className : '')) return;
    const text = L.clean(region.innerText || region.textContent, 300);
    if (!text) return;
    const key = text;
    const t = now();
    if (recentAlerts.has(key) && t - recentAlerts.get(key) < 2000) return;
    recentAlerts.set(key, t);
    if (recentAlerts.size > 50) recentAlerts.delete(recentAlerts.keys().next().value);
    emit('observed_effect', 'page.alert', {
      role: region.getAttribute('role') || (region.tagName.toLowerCase() === 'dialog' ? 'dialog' : 'live'),
      live: region.getAttribute('aria-live'),
      text,
      region: L.describe(region),
    });
  }

  function onMutations(records) {
    const regions = new Set();
    for (const r of records) {
      if (r.type === 'childList') {
        domCounts.added += r.addedNodes.length;
        domCounts.removed += r.removedNodes.length;
        for (const n of r.addedNodes) {
          if (n.nodeType === 1) noteFields(n);
          const region = liveRegionFor(n);
          if (region) regions.add(region);
          else if (n.nodeType === 1 && typeof n.querySelectorAll === 'function') {
            for (const inner of n.querySelectorAll(LIVE_SELECTOR)) regions.add(inner);
          }
        }
      } else if (r.type === 'characterData') {
        domCounts.text += 1;
        const region = liveRegionFor(r.target);
        if (region) regions.add(region);
      } else if (r.type === 'attributes') {
        domCounts.attributes += 1;
        if (r.attributeName === 'open' && r.target.tagName && r.target.tagName.toLowerCase() === 'dialog') regions.add(r.target);
      }
    }
    regions.forEach(reportAlert);
    if (!domTimer) {
      domTimer = setTimeout(() => {
        domTimer = null;
        const c = domCounts;
        domCounts = { added: 0, removed: 0, attributes: 0, text: 0 };
        if (c.added + c.removed + c.attributes + c.text > 0) emit('observed_effect', 'dom.summary', c);
      }, 5000);
    }
  }

  function startObserver() {
    if (mutationObserver || !document.documentElement) return;
    mutationObserver = new MutationObserver(onMutations);
    mutationObserver.observe(document.documentElement, {
      childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['open', 'aria-hidden', 'hidden'],
    });
  }

  function stopObserver() {
    if (mutationObserver) { mutationObserver.disconnect(); mutationObserver = null; }
  }

  // --- Arming ------------------------------------------------------------------

  function arm(newPolicy, session) {
    policy = Object.assign({}, policy, newPolicy || {});
    const wasArmed = armed;
    armed = true;
    if (!wasArmed) {
      const cutoff = now() - (policy.prebufferMs || RING_MS);
      const pre = ring.splice(0, ring.length).filter((e) => e.t >= cutoff);
      for (const e of pre) { e.pre = true; e.rec = true; queue.push(e); }
      emit('context', 'capture.content_armed', { session: session || null, prebuffered: pre.length, title: L.clean(document.title, 200) });
      const start = () => { noteFields(document); startObserver(); };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
      else start();
    }
    schedule();
  }

  function disarm() {
    if (!armed) return;
    emit('context', 'capture.content_disarmed', {});
    flush();
    armed = false;
    stopObserver();
  }

  try {
    chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
      if (!msg || !msg.type) return;
      if (msg.type === 'arm') arm(msg.policy, msg.session);
      else if (msg.type === 'disarm') disarm();
      else if (msg.type === 'ping') sendResponse({ armed, top: isTop });
    });
  } catch (_) { dead = true; }

  // Testbed diagnostics: expose recorder status on the local testbed only, so tests can read
  // it from the page. Never exposed to other sites.
  if (isTop && /^http:\/\/(localhost|127\.0\.0\.1):4399$/.test(location.origin)) {
    const publish = () => {
      if (!alive()) return;
      try {
        const p = chrome.runtime.sendMessage({ type: 'status' });
        if (p && typeof p.then === 'function') {
          p.then((s) => { document.documentElement.dataset.agentLedger = JSON.stringify(Object.assign({ contentArmed: armed }, s)); }).catch(() => {});
        }
      } catch (_) { dead = true; }
    };
    publish();
    setInterval(publish, 2000);
  }

  // Ask whether this document's tab is already armed (new document in a recorded tab).
  try {
    const p = chrome.runtime.sendMessage({ type: 'hello', top: isTop });
    if (p && typeof p.then === 'function') {
      p.then((res) => { if (res && res.armed) arm(res.policy, res.session); }).catch(() => {});
    }
  } catch (_) { dead = true; }
})();
