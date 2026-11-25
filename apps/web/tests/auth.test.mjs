import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
const source = readFileSync(new URL('../src/lib/auth.ts', import.meta.url), 'utf8');
const { outputText } = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } });
const { safeNext, validEmail, passwordChecks, authEmailError } = await import(`data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`);

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
test('auth emails distinguish provider outages and limits without leaking account or provider details', () => {
  for (const intent of ['signup', 'confirmation', 'recovery']) {
    assert.match(authEmailError({status:429},intent), /Too many email requests/);
    assert.match(authEmailError({code:'over_email_send_rate_limit'},intent), /Too many email requests/);
    assert.match(authEmailError({code:'email_address_not_authorized'},intent), /contact support/);
    assert.match(authEmailError({status:500},intent), /couldn’t send your email/);
    assert.match(authEmailError({code:'email_address_invalid'},intent), /Check your email address/);
    const privateError={status:500,code:'unexpected_failure',message:'535 private SMTP credential failure for person@example.test'};
    assert.doesNotMatch(authEmailError(privateError,intent),/535|SMTP|person@/);
  }
  assert.match(authEmailError({code:'user_already_exists'},'signup'),/sign in if you already have an account/);
});
