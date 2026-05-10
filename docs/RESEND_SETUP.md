# Resend SMTP Setup for Supabase Auth

Owner: Carl Mostert · Last updated: 2026-05-10

Wires `noreply@homefit.studio` as the From address on every Supabase
auth email (magic links, password resets, signup confirmations) by
routing Supabase's SMTP through Resend.

## Why

Supabase's built-in email service is rate-limited to 4 magic-links/hour
and explicitly **not for production** — it's a dev convenience only.
Resend gives 3,000 emails/month on the free tier, painless DNS
verification, and is supported as a first-class custom-SMTP provider in
the Supabase Auth settings.

Without this, every practitioner who tries to sign in during a busy
hour will silently never receive their magic link.

## Before you start

- Hostinger hPanel access (DNS records on `homefit.studio`)
- Supabase project owner access at `yrwcofhovrcydootivjx.supabase.co`
- ~10 minutes; DNS propagation can stretch the tail to ~1 hour worst
  case at Hostinger

## Steps

### 1. Sign up for Resend

Go to <https://resend.com> and sign up. Use whatever admin email Carl
wants to own the account with — `support@homefit.studio` once that
mailbox is set up at Hostinger, otherwise Carl's personal email is fine
(can be moved later).

### 2. Add `homefit.studio` as a sending domain

#### 2a. Open the Domains page

After signing in, you land on the Resend dashboard. In the left
sidebar, click **Domains**. If this is a fresh account, the page shows
an empty state with a big **Add Domain** button in the middle.

(If you don't see Domains in the sidebar, click the small Resend logo
top-left to get back to the main dashboard.)

#### 2b. Click "Add Domain" and fill the form

A modal pops up with two fields:

- **Name**: type `homefit.studio` exactly. No `https://`, no `www.`,
  no trailing slash — just the bare domain.
- **Region**: dropdown of US East / Ireland / São Paulo / Tokyo /
  others. **Leave it on the default (US East)** unless you have a
  specific reason. The latency difference is milliseconds; the default
  is the most battle-tested region.

Click **Add**.

#### 2c. The DNS records page appears

Resend now shows a verification screen with a table of 3–4 DNS
records, each row with a **Status** column saying *Pending*. The
columns are typically: **Type**, **Host/Name**, **Value**, **Priority**
(MX only), **Status**.

The records will look something like this — **copy values from your
Resend page, not from here**, because the DKIM key is per-domain and
the AWS region in the MX value depends on what you picked:

| Type | Host | Value (example) | Priority |
|------|------|-----------------|----------|
| MX   | `send` | `feedback-smtp.us-east-1.amazonses.com` | 10 |
| TXT  | `send` | `v=spf1 include:amazonses.com ~all` | — |
| TXT  | `resend._domainkey` | `p=MIGfMA0GCSqGSIb3...` (very long key) | — |
| TXT  | `_dmarc` | `v=DMARC1; p=none;` | — |

Some Resend UIs show the Host as the full FQDN (`send.homefit.studio`);
others show just the subdomain part (`send`). Hostinger's DNS panel
expects just the subdomain, so we'll strip the `.homefit.studio` part
in step 3.

**Don't click the Verify button yet** — the records aren't at Hostinger
yet, so verification will fail. Just leave this tab open and switch to
Hostinger for step 3.

#### 2d. Why these records exist (one paragraph, skip if you don't care)

The MX + SPF tell mail providers "Resend is allowed to send mail
on behalf of homefit.studio" so receivers don't dump it as forgery.
The DKIM record holds the public half of a key Resend uses to
cryptographically sign every email it sends from your domain. DMARC
is a policy hint that tightens the above two. Resend puts the MX/SPF
on a `send.` subdomain instead of the apex so this setup doesn't fight
with any apex email setup you might add at Hostinger later (e.g., for
`support@homefit.studio`).

### 3. Add the DNS records at Hostinger

Hostinger hPanel → **Domains** → `homefit.studio` → **DNS / Nameservers**
→ **DNS Records**.

For each record Resend gave you:

1. Click **Add record**
2. Match Type (TXT / MX)
3. Name: Hostinger uses the subdomain only, not the FQDN —
   - For `homefit.studio` (apex), enter `@`
   - For `resend._domainkey.homefit.studio`, enter `resend._domainkey`
   - For `send.homefit.studio`, enter `send`
   - For `_dmarc.homefit.studio`, enter `_dmarc`
4. Paste the value exactly as Resend showed it
5. TTL: leave default (3600)
6. Save

**Watch for SPF collision.** If `homefit.studio` already has a TXT
record starting with `v=spf1`, do **not** add a second one — merge the
two. The merged value looks like:

```
v=spf1 include:_spf.mail.hostinger.com include:amazonses.com ~all
```

Two separate `v=spf1` records on the same name break email auth
silently — every receiver picks one and ignores the other.

### 4. Verify the domain in Resend

Back in Resend → **Domains** → `homefit.studio` → click
**Verify DNS records**. Each row turns green within 5–15 minutes
(occasionally longer at Hostinger). If still pending after 30 minutes,
click **Re-verify**.

You can sanity-check from the terminal:

```bash
dig TXT homefit.studio @8.8.8.8 +short
dig TXT resend._domainkey.homefit.studio @8.8.8.8 +short
dig MX  send.homefit.studio @8.8.8.8 +short
```

### 5. Create an API key in Resend

Resend → **API Keys** → **Create API Key**:

- **Name**: `supabase-prod`
- **Permission**: **Sending access** (least privilege — not Full access)
- **Domain**: restrict to `homefit.studio`
- Click **Add**

Copy the `re_xxxxx` key immediately — you'll only see it once.

### 6. Configure Supabase SMTP

Supabase dashboard → project `yrwcofhovrcydootivjx` →
**Project Settings** → **Authentication** → **SMTP Settings**.

Toggle **Enable Custom SMTP** ON, then:

| Field | Value |
|-------|-------|
| Sender email | `noreply@homefit.studio` |
| Sender name | `homefit.studio` |
| Host | `smtp.resend.com` |
| Port | `465` |
| Username | `resend` |
| Password | (the `re_xxxxx` API key from step 5) |
| Minimum interval | `60` (default) |

Click **Save**.

### 7. Bump the auth rate limits

While you're in Auth settings:

**Authentication** → **Rate Limits** → **Rate limit for sending emails**.

Default is `4` per hour (capped because the built-in mailer was the
bottleneck). With Resend behind it you control the cap — bump to `30`
for now, raise further if launch traffic warrants it.

### 8. Test

Pick one:

- Sign in fresh on `manage.homefit.studio` with an email you control —
  the magic link should arrive from `noreply@homefit.studio`, not
  `noreply@mail.app.supabase.io`.
- Or in Supabase → **Authentication** → **Users** → invite a test user
  with an email you control → check the inbox.

Open the email and inspect headers (Gmail: ⋮ → "Show original"). You
want:

- `From:` = `noreply@homefit.studio`
- `Authentication-Results:` shows `spf=pass`, `dkim=pass`, `dmarc=pass`

If any of those say `fail` or `none`, jump to Troubleshooting.

## Do you need a real `noreply@` mailbox at Hostinger?

**No.** Outbound mail flows through Resend's servers; nothing reads
`noreply@homefit.studio` at Hostinger. Replies will bounce, which is
the contract a "noreply" address advertises.

If you'd rather not have replies disappear silently, set up a Hostinger
forwarder: `noreply@` → `support@homefit.studio`. Tradeoff: occasional
out-of-office messages and bounced bounces in the support inbox.

## Troubleshooting

**DNS records still pending in Resend after 1 hour.**
Run the `dig` commands from step 4. If the records aren't there,
Hostinger didn't save them — re-add. If they are there but Resend still
shows pending, click **Re-verify** a few more times; sometimes Resend's
poller is sluggish.

**Email arrives in spam.**
Check the message headers for the Authentication-Results line. If
SPF/DKIM/DMARC all pass, this is just sender-reputation warmup — your
domain is brand-new to inbox providers. After a few hundred clean
sends to engaged recipients the reputation builds. Once you're a week
in with no complaints, tighten DMARC from `p=none` to `p=quarantine`
or `p=reject`.

**`Authentication-Results: spf=fail`.**
Either the SPF record is missing, or there are two `v=spf1` records on
the apex. Verify with `dig TXT homefit.studio @8.8.8.8 +short` — you
should see exactly **one** line starting with `v=spf1`.

**`Authentication-Results: dkim=none` or `dkim=fail`.**
DKIM TXT record missing or truncated. Hostinger has a character limit
on TXT values in some panels — long DKIM keys sometimes get cut. Verify
the full key with `dig TXT resend._domainkey.homefit.studio @8.8.8.8`
and re-paste if it's short.

**Supabase rejects the SMTP credentials when saving.**
Double-check Username is exactly `resend` (not your account email,
not your domain) and Password is the full `re_xxxxx` key with no
surrounding whitespace.

**Magic links work but reset-password emails don't.**
Both go through the same SMTP path — if one works the other should.
If they diverge, look in Supabase → **Logs** → **Auth Logs** for
the failing send and check the error string.

## When this is done

- Update `CLAUDE.md` Tech Stack section: add a one-liner under the
  Supabase block — "**Email:** Resend SMTP relay,
  `noreply@homefit.studio` sender."
- Apply the branded auth-email templates from
  `supabase/email-templates/` (6 HTML files + README with subjects and
  paste instructions). Dark theme + coral CTA + warmer copy + `homefit
  team` sender name. The README in that folder is the click-through;
  one paste per template type into Supabase → Authentication → Email
  Templates.
- Add `support@homefit.studio` mailbox at Hostinger as a separate task
  (referenced in `docs/TESTFLIGHT_PREP.md`).
