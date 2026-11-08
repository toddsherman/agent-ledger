const test = require('node:test');
const assert = require('node:assert');
global.AgentLedgerLib = Object.assign({}, require('../lib/redact.js'));
const D = require('../lib/describe-element.js');

function el(tag, attrs = {}, extra = {}) {
  return Object.assign({
    tagName: tag.toUpperCase(), nodeType: 1, id: attrs.id || '',
    getAttribute: (n) => (n in attrs ? attrs[n] : null), parentElement: null, children: [], textContent: '',
  }, extra);
}

test('password, hidden and card fields are never read', () => {
  assert.deepStrictEqual(D.readValue(el('input', { type: 'password' }, { value: 'hunter2' }), { values: true }), { redacted: true, reason: 'password-field' });
  assert.strictEqual(D.readValue(el('input', { type: 'hidden' }, { value: 'csrf' }), { values: true }).redacted, true);
  assert.strictEqual(D.readValue(el('input', { autocomplete: 'cc-number' }, { value: '4111111111111111' }), { values: true }).reason, 'autocomplete:cc-number');
  assert.strictEqual(D.readValue(el('input', { name: 'otp_code' }, { value: '123456' }), { values: true }).reason, 'sensitive-name');
});

test('ordinary fields are read and scrubbed; values can be disabled', () => {
  const title = el('input', { name: 'title' }, { value: 'Spring launch sk-proj-abcdefghijklmnopqrstuv' });
  assert.deepStrictEqual(D.readValue(title, { values: true }), { value: 'Spring launch [redacted:token]' });
  assert.deepStrictEqual(D.readValue(title, { values: false }), { omitted: true });
  assert.deepStrictEqual(D.readValue(el('input', { type: 'checkbox' }, { checked: true }), { values: true }), { checked: true });
});

test('describe gives role, accessible name and selector', () => {
  const parent = el('form', { id: 'edit-form' });
  const btn = el('button', { type: 'submit' }, { textContent: '  Save  changes ', parentElement: parent });
  parent.children = [btn];
  const d = D.describe(btn);
  assert.strictEqual(d.role, 'button');
  assert.strictEqual(d.name, 'Save changes');
  assert.strictEqual(d.selector, 'form#edit-form > button');
  const field = el('input', { name: 'email', 'aria-label': 'Work email' });
  assert.strictEqual(D.describe(field).name, 'Work email');
  assert.strictEqual(D.describe(field).field, 'input');
});

test('passenger is not treated as a password field', () => {
  assert.strictEqual(D.sensitivity(el('input', { name: 'passenger_name' })), null);
  assert.strictEqual(D.sensitivity(el('input', { name: 'password_confirm' })), 'sensitive-name');
});
