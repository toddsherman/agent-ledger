const test = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const fs = require('node:fs');
const R = require('../lib/redact.js');

const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, '../../mac/Tests/LedgerCoreTests/Fixtures/redaction.json'), 'utf8'));

test('value fixtures match the Swift redactor', () => {
  for (const c of fixture.values) assert.strictEqual(R.scrub(c.in), c.out, c.in);
});

test('url fixtures match the Swift redactor', () => {
  for (const c of fixture.urls) assert.strictEqual(R.redactUrl(c.in), c.out, c.in);
});

test('truncation marker', () => {
  const t = R.redactValue('a'.repeat(3000));
  assert.ok(t.startsWith('a'.repeat(2048)));
  assert.ok(t.endsWith('…[+952 chars]'));
});
