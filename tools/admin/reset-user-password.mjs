#!/usr/bin/env node
// Sets a Supabase auth user's password directly via the GoTrue admin REST API.
// No email is sent — bypasses the outbound-mail rate limit on the default sender.
//
// Zero dependencies — uses Node 18+ built-in fetch, so it runs from anywhere
// without an npm install. Run from any directory:
//
//   SUPABASE_SERVICE_ROLE_KEY=... node tools/admin/reset-user-password.mjs <email> [password]
//
// If [password] is omitted, a strong random one is generated and printed.
// SUPABASE_URL defaults to the homefit.studio project; override via env if needed.

import { randomBytes } from 'node:crypto';

const SUPABASE_URL =
  process.env.SUPABASE_URL ?? 'https://yrwcofhovrcydootivjx.supabase.co';
const SERVICE_ROLE = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SERVICE_ROLE) {
  console.error('Missing SUPABASE_SERVICE_ROLE_KEY env var.');
  process.exit(1);
}

const [, , emailArg, passwordArg] = process.argv;
if (!emailArg) {
  console.error(
    'Usage: SUPABASE_SERVICE_ROLE_KEY=... node reset-user-password.mjs <email> [password]',
  );
  process.exit(1);
}

const email = emailArg.trim().toLowerCase();
const password = passwordArg ?? randomBytes(12).toString('base64url');

const headers = {
  apikey: SERVICE_ROLE,
  Authorization: `Bearer ${SERVICE_ROLE}`,
  'Content-Type': 'application/json',
};

let user = null;
let page = 1;
const perPage = 1000;
while (true) {
  const res = await fetch(
    `${SUPABASE_URL}/auth/v1/admin/users?page=${page}&per_page=${perPage}`,
    { headers },
  );
  if (!res.ok) {
    console.error('listUsers failed:', res.status, await res.text());
    process.exit(3);
  }
  const data = await res.json();
  const users = data.users ?? data;
  user = users.find((u) => u.email?.toLowerCase() === email);
  if (user || users.length < perPage) break;
  page += 1;
}

if (!user) {
  console.error(`No auth user found for ${email}.`);
  process.exit(2);
}

const updateRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${user.id}`, {
  method: 'PUT',
  headers,
  body: JSON.stringify({ password }),
});

if (!updateRes.ok) {
  console.error('updateUser failed:', updateRes.status, await updateRes.text());
  process.exit(4);
}

console.log(`Password reset for ${email}`);
console.log(`  uid:           ${user.id}`);
console.log(`  password:      ${password}`);
console.log('');
console.log('Share via WhatsApp/SMS. Tell them to change it in Settings on first sign-in.');
