import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
const source = readFileSync(new URL('../src/lib/auth.ts', import.meta.url), 'utf8');
const { outputText } = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } });
const { safeNext, validEmail, passwordChecks } = await import(`data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`);

test('return destination rejects external URLs, backslash tricks and auth loops', () => {
  for (const value of [undefined, null, '', 'https://evil.example', '//evil.example', '/\\evil.example', '/\nevil.example', '/login', '/signup?next=/login', '/auth/confirm', '/reset-password']) {
    assert.equal(safeNext(value), '/dashboard', String(value));
  }
});
test('return destination preserves hotel routes and filters', () => {
  assert.equal(safeNext('/p/123/reservations?start=2027-01-01'), '/p/123/reservations?start=2027-01-01');
});
test('email validation accepts ordinary staff emails and rejects malformed inputs', () => {
  assert.equal(validEmail('frontdesk+shift@hotel.example'), true);
  for (const email of ['', 'staff', 'staff@', 'staff @hotel.com', 'a'.repeat(255) + '@hotel.com']) assert.equal(validEmail(email), false);
});
test('new passwords meet length and character requirements without changing existing login rules', () => {
  assert.equal(passwordChecks('A-long-password-123').every(c => c.valid), true);
  for (const password of ['Short1!', 'alllowercase12345', 'ALLUPPERCASE12345', 'OnlyLettersHere']) assert.equal(passwordChecks(password).every(c => c.valid), false);
});
