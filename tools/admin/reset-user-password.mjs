#!/usr/bin/env node
// Sets a Supabase auth user's password directly via the admin API.
// No email is sent — bypasses the outbound-mail rate limit on the default sender.
//
// Usage (run from web-portal/ to pick up @supabase/supabase-js from its node_modules):
//   cd web-portal
//   SUPABASE_SERVICE_ROLE_KEY=... node ../tools/admin/reset-user-password.mjs <email> [password]
//
// If [password] is omitted, a strong random one is generated and printed to stdout.
// SUPABASE_URL defaults to the homefit.studio project; override via env if needed.

import { createClient } from '@supabase/supabase-js';
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

const admin = createClient(SUPABASE_URL, SERVICE_ROLE, {
  auth: { autoRefreshToken: false, persistSession: false },
});

let user = null;
let page = 1;
const perPage = 1000;
while (true) {
  const { data, error } = await admin.auth.admin.listUsers({ page, perPage });
  if (error) {
    console.error('listUsers failed:', error.message);
    process.exit(3);
  }
  user = data.users.find((u) => u.email?.toLowerCase() === email);
  if (user) break;
  if (data.users.length < perPage) break;
  page += 1;
}

if (!user) {
  console.error(`No auth user found for ${email}.`);
  process.exit(2);
}

const { error: updateError } = await admin.auth.admin.updateUserById(user.id, {
  password,
});
if (updateError) {
  console.error('updateUserById failed:', updateError.message);
  process.exit(4);
}

console.log(`Password reset for ${email}`);
console.log(`  uid:           ${user.id}`);
console.log(`  temp password: ${password}`);
console.log('');
console.log('Share via WhatsApp/SMS. Tell them to change it in Settings on first sign-in.');
