// Redaction rules shared with mac/Sources/LedgerCore/Redactor.swift. Both are tested
// against mac/Tests/LedgerCoreTests/Fixtures/redaction.json.
(function (root) {
  'use strict';

  const MAX_VALUE = 2048;

  const PRIVATE_KEY = /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g;
  const JWT = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g;
  const TOKEN_PREFIXES = /\b(?:sk-[A-Za-z0-9_-]{16,}|sk_live_[A-Za-z0-9]{16,}|rk_live_[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|glpat-[A-Za-z0-9_-]{20,})/g;
  const BEARER = /\b([Bb]earer)\s+[A-Za-z0-9._~+/=-]{16,}/g;
  const CARD = /\b(?:\d[ -]?){12,18}\d\b/g;
  const SSN = /\b\d{3}-\d{2}-\d{4}\b/g;
  const LONG_SECRET = /[A-Za-z0-9+/_-]{40,}={0,2}/g;

  const SENSITIVE_KEY_EXACT = new Set([
    'code', 'state', 'nonce', 'sig', 'signature', 'key', 'apikey', 'api_key', 'auth', 'authorization',
    'otp', 'jwt', 'ticket', 'sid', 'pwd', 'passwd', 'password', 'pass', 'secret', 'client_secret',
    'credential', 'credentials', 'samlresponse', 'samlrequest', 'relaystate',
  ]);
  const SENSITIVE_KEY_CONTAINS = ['token', 'secret', 'password', 'session', 'apikey', 'api_key',
    'signature', 'credential', 'x-amz-'];

  function safeDecode(s) {
    try { return decodeURIComponent(s); } catch (_) { return s; }
  }

  function isSensitiveKey(key) {
    const k = safeDecode(key).toLowerCase();
    if (SENSITIVE_KEY_EXACT.has(k)) return true;
    return SENSITIVE_KEY_CONTAINS.some((p) => k.includes(p));
  }

  function luhn(digits) {
    if (digits.length < 13 || digits.length > 19) return false;
    let sum = 0;
    for (let i = 0; i < digits.length; i++) {
      let d = digits[digits.length - 1 - i];
      if (i % 2 === 1) { d *= 2; if (d > 9) d -= 9; }
      sum += d;
    }
    return sum % 10 === 0;
  }

  function scrub(input) {
    if (typeof input !== 'string' || input === '') return input;
    let s = input;
    s = s.replace(PRIVATE_KEY, '[redacted:private-key]');
    s = s.replace(JWT, '[redacted:jwt]');
    s = s.replace(TOKEN_PREFIXES, '[redacted:token]');
    s = s.replace(BEARER, 'Bearer [redacted:token]');
    s = s.replace(CARD, (m) => (luhn(m.replace(/\D/g, '').split('').map(Number)) ? '[redacted:card]' : m));
    s = s.replace(SSN, '[redacted:ssn]');
    s = s.replace(LONG_SECRET, (m) => (/[0-9]/.test(m) && /[A-Za-z]/.test(m) ? '[redacted:secret]' : m));
    return s;
  }

  function truncate(s, max = MAX_VALUE) {
    if (typeof s !== 'string' || s.length <= max) return s;
    return s.slice(0, max) + '…[+' + (s.length - max) + ' chars]';
  }

  function redactValue(s, max = MAX_VALUE) {
    return truncate(scrub(s), max);
  }

  function redactParams(part) {
    return part.split('&').map((pair) => {
      const eq = pair.indexOf('=');
      if (eq < 0) return pair;
      const k = pair.slice(0, eq);
      const v = pair.slice(eq + 1);
      if (isSensitiveKey(k)) return k + '=[redacted]';
      const decoded = safeDecode(v);
      if (scrub(decoded) !== decoded) return k + '=[redacted]';
      return k + '=' + v;
    }).join('&');
  }

  const USER_INFO = /^([A-Za-z][A-Za-z0-9+.-]*:\/\/)[^/@?#]*@/;

  function redactUrl(raw) {
    if (typeof raw !== 'string' || raw === '') return raw;
    let base = raw;
    let fragment = null;
    const hash = base.indexOf('#');
    if (hash >= 0) { fragment = base.slice(hash + 1); base = base.slice(0, hash); }
    let query = null;
    const q = base.indexOf('?');
    if (q >= 0) { query = base.slice(q + 1); base = base.slice(0, q); }
    base = base.replace(USER_INFO, '$1[redacted]@');
    let out = base;
    if (query !== null) out += '?' + redactParams(query);
    if (fragment !== null) out += '#' + (fragment.includes('=') ? redactParams(fragment) : fragment);
    return truncate(out);
  }

  function originOf(raw) {
    try { return new URL(raw).origin; } catch (_) { return null; }
  }

  const api = { scrub, truncate, redactValue, redactUrl, isSensitiveKey, luhn, originOf, MAX_VALUE };
  root.AgentLedgerLib = Object.assign(root.AgentLedgerLib || {}, api);
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
