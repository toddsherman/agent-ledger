// Element descriptions and field-value policy for the content script.
// Uses only a small DOM surface so it can be unit-tested with plain objects.
(function (root) {
  'use strict';

  const lib = () => root.AgentLedgerLib || (typeof require === 'function' ? require('./redact.js') : {});

  const TEXT_LIMIT = 80;

  const SENSITIVE_AUTOCOMPLETE = new Set([
    'current-password', 'new-password', 'one-time-code', 'cc-number', 'cc-csc', 'cc-exp', 'cc-exp-month',
    'cc-exp-year', 'cc-type', 'transaction-amount',
  ]);
  const SENSITIVE_NAME = /pass(word|wd|code|phrase)?(?![a-z])|pwd|secret|token|(^|[^a-z])(otp|cvv|cvc|pin|ssn)([^a-z]|$)|one.?time|social.?security|card.?(number|num|no)([^a-z]|$)|security.?code|routing.?number|account.?number|iban/i;

  function attr(el, name) {
    if (!el || typeof el.getAttribute !== 'function') return null;
    const v = el.getAttribute(name);
    return v === undefined ? null : v;
  }

  function tagOf(el) {
    return el && el.tagName ? String(el.tagName).toLowerCase() : '';
  }

  function clean(s, limit = TEXT_LIMIT) {
    if (s === null || s === undefined) return null;
    const t = String(s).replace(/\s+/g, ' ').trim();
    if (!t) return null;
    return lib().truncate(lib().scrub(t), limit);
  }

  function inputType(el) {
    return String(attr(el, 'type') || el.type || 'text').toLowerCase();
  }

  function implicitRole(el) {
    const tag = tagOf(el);
    switch (tag) {
      case 'a': return attr(el, 'href') !== null ? 'link' : null;
      case 'button': return 'button';
      case 'select': return 'combobox';
      case 'textarea': return 'textbox';
      case 'img': return 'img';
      case 'form': return 'form';
      case 'nav': return 'navigation';
      case 'dialog': return 'dialog';
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
      case 'input': {
        const t = inputType(el);
        if (['button', 'submit', 'reset', 'image'].includes(t)) return 'button';
        if (t === 'checkbox') return 'checkbox';
        if (t === 'radio') return 'radio';
        if (t === 'range') return 'slider';
        if (t === 'search') return 'searchbox';
        return 'textbox';
      }
      default:
        return el && el.isContentEditable ? 'textbox' : null;
    }
  }

  function roleOf(el) {
    return attr(el, 'role') || implicitRole(el);
  }

  function textById(doc, ids) {
    if (!doc || typeof doc.getElementById !== 'function') return null;
    return ids.split(/\s+/).map((id) => {
      const n = doc.getElementById(id);
      return n ? n.textContent : '';
    }).join(' ');
  }

  function accessibleName(el) {
    const aria = attr(el, 'aria-label');
    if (aria) return clean(aria);
    const by = attr(el, 'aria-labelledby');
    if (by) {
      const t = clean(textById(el.ownerDocument, by));
      if (t) return t;
    }
    if (el.labels && el.labels.length) {
      const t = clean(Array.from(el.labels).map((l) => l.textContent).join(' '));
      if (t) return t;
    }
    const tag = tagOf(el);
    if (tag === 'input') {
      const t = inputType(el);
      if (['button', 'submit', 'reset'].includes(t)) return clean(el.value || attr(el, 'value') || t);
      if (t === 'image') return clean(attr(el, 'alt'));
    }
    if (tag === 'img') return clean(attr(el, 'alt'));
    const ph = attr(el, 'placeholder');
    if (ph) return clean(ph);
    if (['button', 'a', 'summary', 'option', 'label', 'li', 'td', 'th', 'span', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p']
      .includes(tag) || attr(el, 'role')) {
      const t = clean(el.textContent);
      if (t) return t;
    }
    return clean(attr(el, 'title'));
  }

  function stableId(id) {
    return id && id.length <= 40 && !/\d{5,}/.test(id) && !/^[a-f0-9-]{16,}$/i.test(id) && !/^:r/.test(id);
  }

  function selectorPath(el, maxDepth = 5) {
    const parts = [];
    let node = el;
    while (node && node.tagName && parts.length < maxDepth) {
      const tag = tagOf(node);
      if (tag === 'html' || tag === 'body') break;
      if (stableId(node.id)) { parts.unshift(tag + '#' + node.id); break; }
      let part = tag;
      const name = attr(node, 'name');
      if (name && name.length <= 40) part += '[name="' + name + '"]';
      else {
        const cls = (attr(node, 'class') || '').split(/\s+/).find((c) => c && c.length <= 30 && !/\d{3,}/.test(c));
        if (cls) part += '.' + cls;
      }
      const parent = node.parentElement;
      if (parent && parent.children) {
        const same = Array.from(parent.children).filter((c) => tagOf(c) === tag);
        if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')';
      }
      parts.unshift(part);
      node = parent;
    }
    return parts.join(' > ');
  }

  function isField(el) {
    const tag = tagOf(el);
    return tag === 'input' || tag === 'textarea' || tag === 'select' || !!(el && el.isContentEditable);
  }

  /** Returns null when the field may be captured, otherwise the reason it must not be. */
  function sensitivity(el) {
    const tag = tagOf(el);
    if (tag === 'input') {
      const t = inputType(el);
      if (t === 'password') return 'password-field';
      if (t === 'hidden') return 'hidden-field';
    }
    const ac = String(attr(el, 'autocomplete') || '').toLowerCase().split(/\s+/);
    if (ac.some((token) => SENSITIVE_AUTOCOMPLETE.has(token))) return 'autocomplete:' + ac.find((t) => SENSITIVE_AUTOCOMPLETE.has(t));
    const hay = [attr(el, 'name'), el && el.id, attr(el, 'aria-label'), attr(el, 'placeholder'), attr(el, 'data-testid')]
      .filter(Boolean).join(' ');
    if (SENSITIVE_NAME.test(hay)) return 'sensitive-name';
    return null;
  }

  function fieldKind(el) {
    const tag = tagOf(el);
    if (tag === 'input') {
      const t = inputType(el);
      return t === 'checkbox' || t === 'radio' ? t : 'input';
    }
    if (tag === 'textarea' || tag === 'select') return tag;
    return el && el.isContentEditable ? 'contenteditable' : tag;
  }

  /** Reads a field's value under policy. Never returns the value of a sensitive field. */
  function readValue(el, policy) {
    const reason = sensitivity(el);
    if (reason) return { redacted: true, reason };
    if (!policy || !policy.values) return { omitted: true };
    const kind = fieldKind(el);
    if (kind === 'checkbox' || kind === 'radio') return { checked: !!el.checked };
    if (kind === 'select') {
      const opts = el.options ? Array.from(el.options).filter((o) => o.selected) : [];
      return { value: opts.map((o) => lib().redactValue(String(o.value), 200)).join(', '),
        text: opts.map((o) => clean(o.textContent, 200)).join(', ') };
    }
    if (kind === 'contenteditable') {
      const t = el.innerText !== undefined ? el.innerText : el.textContent;
      return { value: lib().redactValue(String(t || ''), policy.maxValue || 4096) };
    }
    return { value: lib().redactValue(String(el.value === undefined ? '' : el.value), policy.maxValue || 2048) };
  }

  function formOf(el) {
    const f = el && (el.form || (typeof el.closest === 'function' ? el.closest('form') : null));
    if (!f) return null;
    return {
      id: stableId(f.id) ? f.id : null,
      name: attr(f, 'name'),
      method: String(attr(f, 'method') || 'get').toLowerCase(),
      action: lib().redactUrl(f.action || attr(f, 'action') || ''),
      selector: selectorPath(f, 3),
    };
  }

  function describe(el) {
    if (!el || !el.tagName) return null;
    const d = {
      tag: tagOf(el),
      role: roleOf(el),
      name: accessibleName(el),
      selector: selectorPath(el),
    };
    if (stableId(el.id)) d.id = el.id;
    const nameAttr = attr(el, 'name');
    if (nameAttr) d.nameAttr = nameAttr;
    if (d.tag === 'input') d.type = inputType(el);
    if (d.tag === 'a' && attr(el, 'href')) d.href = lib().redactUrl(el.href || attr(el, 'href'));
    if (isField(el)) {
      d.field = fieldKind(el);
      const s = sensitivity(el);
      if (s) d.sensitive = s;
      const ac = attr(el, 'autocomplete');
      if (ac) d.autocomplete = ac;
    }
    return d;
  }

  /** The nearest meaningful element for a click target (button, link, field, or role). */
  function actionable(el) {
    let node = el;
    for (let i = 0; node && i < 6; i++) {
      if (node.nodeType === 1) {
        const tag = tagOf(node);
        if (['a', 'button', 'input', 'select', 'textarea', 'summary', 'label', 'option'].includes(tag)) return node;
        if (attr(node, 'role') || attr(node, 'onclick') !== null || node.isContentEditable) return node;
      }
      node = node.parentElement;
    }
    return el && el.nodeType === 1 ? el : (el && el.parentElement) || el;
  }

  const api = { describe, accessibleName, roleOf, selectorPath, sensitivity, readValue, isField, fieldKind, formOf, actionable, clean };
  root.AgentLedgerLib = Object.assign(root.AgentLedgerLib || {}, api);
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
